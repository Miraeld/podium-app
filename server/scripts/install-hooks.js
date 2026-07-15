#!/usr/bin/env node

/**
 * Installs Claude Code hooks that forward events to the Agent Dashboard.
 * Modifies ~/.claude/settings.json to add hook entries.
 *
 * @author Son Nguyen <hoangson091104@gmail.com>
 */

const fs = require("fs");
const path = require("path");

const { getSettingsPath } = require("../lib/claude-home");
const SETTINGS_PATH = getSettingsPath();

/**
 * Resolve the podium-hook binary to register in settings.json.
 *
 * Port of the resolution philosophy in `Sources/PodiumCore/Hooks/HookInstaller.swift`
 * (native binary path registered directly, no interpreter prefix) adapted for
 * the Node/Bun era's hook client (`hook/src/index.ts`, compiled via
 * `cd hook && bun run build` -> `hook/dist/podium-hook`, see hook/package.json).
 *
 * Order (first match wins):
 *   1. `PODIUM_HOOK_BIN` env override — explicit, for tests/power users/CI.
 *   2. `hook/dist/podium-hook` relative to this repo's layout (dev / `npm start`
 *      / a checked-out clone running the server directly).
 *   3. Packaged-app layout: a `podium-hook` binary sitting next to the
 *      currently-running server binary (mirrors how the Tauri sidecar and the
 *      Swift-era installer located co-located native binaries — see
 *      `tauri/prepare-sidecar.sh`, which stages `hook/dist/podium-hook` next
 *      to the `podium-server` sidecar for exactly this case).
 *
 * Returns `{ path, source }` for the first candidate that exists on disk, or
 * `null` if none do. Never throws.
 *
 * @param {{env?: object, repoRoot?: string, execPath?: string}} [opts]
 *   Injectable for tests; defaults to real process.env / repo root / process.execPath.
 */
function resolveHookBinary(opts = {}) {
  const env = opts.env || process.env;
  const repoRoot = opts.repoRoot || path.resolve(__dirname, "..", "..");
  const execPath = opts.execPath !== undefined ? opts.execPath : process.execPath;

  const override = env.PODIUM_HOOK_BIN;
  if (override) {
    const resolved = path.resolve(override);
    if (fs.existsSync(resolved)) return { path: resolved, source: "env (PODIUM_HOOK_BIN)" };
  }

  const repoRelative = path.join(repoRoot, "hook", "dist", "podium-hook");
  if (fs.existsSync(repoRelative)) return { path: repoRelative, source: "repo (hook/dist/podium-hook)" };

  if (execPath) {
    const sibling = path.join(path.dirname(execPath), "podium-hook");
    if (fs.existsSync(sibling)) return { path: sibling, source: "packaged (next to server binary)" };
  }

  return null;
}

function envFlag(name) {
  return ["1", "true", "yes", "on"].includes(String(process.env[name] || "").toLowerCase());
}

/**
 * True when this process is running inside a container (Docker, Podman, or a
 * Kubernetes pod). Detected via the Docker/Podman marker files, the OCI/systemd
 * `container` env var, and a Linux cgroup heuristic. `CCAM_FORCE_CONTAINER=1`
 * forces a positive result and `CCAM_FORCE_HOST=1` forces a negative result
 * (used by tests / to override misfiring detection).
 *
 * Why this matters (GitHub #193): the hook command written into
 * `~/.claude/settings.json` embeds the absolute handler path resolved here.
 * Inside a container that path (e.g. `/app/scripts/hook-handler.js`) does not
 * exist on the host. When `~/.claude` is bind-mounted, installing from the
 * container poisons the host settings and every host hook fails with
 * `MODULE_NOT_FOUND`. Claude Code runs on the host, so hooks must be installed
 * on the host.
 *
 * @returns {boolean}
 */
function isInsideContainer() {
  if (envFlag("CCAM_FORCE_CONTAINER")) return true;
  if (envFlag("CCAM_FORCE_HOST")) return false;
  try {
    if (fs.existsSync("/.dockerenv")) return true; // Docker
    if (fs.existsSync("/run/.containerenv")) return true; // Podman
  } catch {
    /* fs probe failed — fall through to other signals */
  }
  // systemd-nspawn / Podman (and often Docker) export `container`.
  if (typeof process.env.container === "string" && process.env.container.length > 0) return true;
  // Linux cgroup heuristic — covers Docker, containerd, Kubernetes, Podman.
  try {
    const cgroup = fs.readFileSync("/proc/self/cgroup", "utf8");
    if (/\b(docker|containerd|kubepods|libpod|podman)\b/.test(cgroup)) return true;
  } catch {
    /* not Linux / no cgroup file — not a container by this signal */
  }
  return false;
}

/** Multi-line message explaining why a container install is refused. */
function containerRefusalMessage() {
  const hookBin = (resolveHookBinary() || {}).path || "<podium-hook binary path>";
  return [
    "✖ Refusing to install Claude Code hooks from inside a container.",
    "",
    `  The hook command would embed this binary path:`,
    `      ${hookBin}`,
    `  written into:`,
    `      ${SETTINGS_PATH}`,
    "",
    "  Claude Code runs on the HOST. When ~/.claude is bind-mounted, a",
    "  container-internal handler path does not exist on the host, so every host",
    "  hook fails with MODULE_NOT_FOUND (e.g. the SessionEnd hook). See issue #193.",
    "",
    "  → Install hooks ON THE HOST instead:",
    "        npm run install-hooks",
    "        # or: node /path/to/Claude-Code-Agent-Monitor/scripts/install-hooks.js",
    "",
    "  The host handler POSTs to http://localhost:4820, which the container already",
    "  publishes — so a host-installed hook reaches the containerized dashboard.",
    "",
    "  If you genuinely run Claude Code inside this same container, override with:",
    "        CCAM_ALLOW_CONTAINER_HOOKS=1 npm run install-hooks",
  ].join("\n");
}

// Hook types to install. Some support matchers, some don't.
const HOOKS_WITH_MATCHER = ["PreToolUse", "PostToolUse", "Stop", "SubagentStop", "Notification"];
// UserPromptSubmit fires the instant the user hits enter — the only reliable
// signal that the user has resumed for *text-only* turns (no PreToolUse will
// fire until Claude calls a tool, which never happens for plain-text replies).
// Without it the Waiting badge persists through the entire generation of a
// text response. SessionStart / SessionEnd / UserPromptSubmit don't take
// tool-name matchers, hence the separate list.
const HOOKS_WITHOUT_MATCHER = ["SessionStart", "SessionEnd", "UserPromptSubmit"];
const HOOK_TYPES = [...HOOKS_WITH_MATCHER, ...HOOKS_WITHOUT_MATCHER];

/**
 * Legacy markers recognized (and upgraded in place, not duplicated) so
 * pre-existing installs — including the never-vendored `hook-handler.js`
 * entries every boot wrote before this fix — get replaced by the real
 * `podium-hook` binary path. Ported from `HookInstaller.swift`'s
 * `legacyMarkers`.
 */
const LEGACY_MARKERS = [
  "hook-handler.js",
  ".claude/podium/hook.mjs",
  "plugins/cache/wp-media/podium",
  "podium/dashboard/scripts",
];
/** Marker substring identifying our own current native-binary entry. */
const OUR_MARKER = "podium-hook";

function makeHookEntry(hookType, hookBinPath) {
  const entry = {
    hooks: [
      {
        type: "command",
        command: `"${hookBinPath}"`,
      },
    ],
  };
  if (HOOKS_WITH_MATCHER.includes(hookType)) {
    entry.matcher = "*";
  }
  return entry;
}

/**
 * P3 (ROADMAP §2, ported from `Sources/PodiumCore/Hooks/HookInstaller.swift`
 * `writeSettings`, audit A7): a crash mid-write must never corrupt the
 * user's GLOBAL Claude `settings.json`. Back up any existing file to
 * `<path>.bak`, then write via a temp file in the SAME directory (so the
 * rename stays on one volume) + atomic rename so the replace either fully
 * lands or doesn't.
 * @param {string} settingsPath
 * @param {object} settings
 */
function writeSettingsAtomic(settingsPath, settings) {
  const dir = path.dirname(settingsPath);
  fs.mkdirSync(dir, { recursive: true });

  if (fs.existsSync(settingsPath)) {
    const backupPath = settingsPath + ".bak";
    fs.copyFileSync(settingsPath, backupPath);
  }

  const tempPath = path.join(dir, `.${path.basename(settingsPath)}.tmp-${process.pid}-${Date.now()}`);
  const body = JSON.stringify(settings, null, 2) + "\n";
  fs.writeFileSync(tempPath, body, "utf8");
  try {
    fs.renameSync(tempPath, settingsPath);
  } catch (err) {
    try {
      fs.unlinkSync(tempPath);
    } catch {
      /* best-effort cleanup */
    }
    throw err;
  }
}

function isOurEntry(entry) {
  const markers = [OUR_MARKER, ...LEGACY_MARKERS];
  // Matches old format (entry.command) and new format (entry.hooks[].command)
  if (entry.command && markers.some((m) => entry.command.includes(m))) return true;
  if (Array.isArray(entry.hooks)) {
    return entry.hooks.some((h) => h.command && markers.some((m) => h.command.includes(m)));
  }
  return false;
}

function installHooks(silent = false) {
  // Host-only guard (issue #193): never write a container-internal handler path
  // into a (potentially bind-mounted) host settings file. Honors an explicit
  // opt-out for the rare case of running Claude Code inside this same container.
  if (isInsideContainer() && !envFlag("CCAM_ALLOW_CONTAINER_HOOKS")) {
    if (!silent) console.error(containerRefusalMessage());
    return false;
  }

  const resolved = resolveHookBinary();
  if (!resolved) {
    // Better no hooks than dead hooks: never write an entry pointing at a
    // binary that doesn't exist (this was the pre-fix bug — every boot wrote
    // a hook-handler.js command that could never resolve).
    console.error(
      "podium-hook binary not found (checked PODIUM_HOOK_BIN, hook/dist/podium-hook, " +
        "and next to the running server binary) — skipping hook installation. " +
        "Build it with: cd hook && bun install && bun run build"
    );
    return false;
  }

  let settings = {};
  if (fs.existsSync(SETTINGS_PATH)) {
    try {
      const raw = fs.readFileSync(SETTINGS_PATH, "utf8");
      settings = JSON.parse(raw);
    } catch (err) {
      if (!silent) console.error(`Failed to parse ${SETTINGS_PATH}:`, err.message);
      return false;
    }
  }

  if (!settings.hooks) settings.hooks = {};

  let installed = 0;
  let updated = 0;

  for (const hookType of HOOK_TYPES) {
    if (!settings.hooks[hookType]) settings.hooks[hookType] = [];

    const existing = settings.hooks[hookType].findIndex(isOurEntry);
    const entry = makeHookEntry(hookType, resolved.path);

    if (existing >= 0) {
      settings.hooks[hookType][existing] = entry;
      updated++;
    } else {
      settings.hooks[hookType].push(entry);
      installed++;
    }
  }

  writeSettingsAtomic(SETTINGS_PATH, settings);

  if (!silent) {
    console.log(`Hook binary: ${resolved.path} (via ${resolved.source})`);
    console.log(`Settings file: ${SETTINGS_PATH}`);
    console.log(`Installed: ${installed} new, updated: ${updated} existing`);
    console.log("Claude Code hooks configured. Start a new Claude Code session to begin tracking.");
  }

  return true;
}

if (require.main === module) {
  // Non-zero exit on refusal/failure so CI and shell users notice it.
  if (!installHooks(false)) process.exitCode = 1;
}

module.exports = { installHooks, isInsideContainer, writeSettingsAtomic, resolveHookBinary };
