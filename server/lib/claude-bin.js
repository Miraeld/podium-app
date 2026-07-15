/**
 * @file claude-bin.js
 * @description Resolves an absolute path to the user's `claude` CLI binary,
 * working around the PATH the dashboard server actually inherits.
 *
 * When the desktop app launches the server as a Tauri sidecar, the process
 * tree starts from launchd (macOS) or the display manager (Linux), NOT the
 * user's login shell — so it inherits a bare PATH like
 * `/usr/bin:/bin:/usr/sbin:/sbin` with none of the user's shell-profile
 * PATH extensions (nvm, bun, homebrew, ~/.local/bin, etc). A plain
 * `which claude` / bare `spawn("claude", ...)` then fails even though the
 * binary is very much installed — this module is the fix.
 *
 * Resolution order (first hit wins):
 *   1. `PODIUM_CLAUDE_BIN` env override — documented escape hatch for users
 *      with a nonstandard install; checked first, no existence validation
 *      beyond the executable check below (an explicit override is trusted).
 *   2. `which claude` (`where claude` on win32) against the CURRENT env —
 *      covers the common case where PATH already has it (dev mode, `npm
 *      start` from a terminal, Linux systemd unit with an inherited PATH).
 *   3. A fixed list of well-known install locations, each checked for
 *      existence + the executable bit.
 *
 * Consistent with server/lib/claude-home.js: `os.homedir()` is used as the
 * home directory root (no separate HOME-override convention is invented
 * here — tests set the real HOME env var via child-process spawn, which
 * os.homedir() reflects).
 *
 * @author Claude
 */
const path = require("node:path");
const os = require("node:os");
const fs = require("node:fs");
const { spawnSync } = require("node:child_process");

/** Returns the well-known candidate paths for the `claude` binary, in order. */
function candidatePaths() {
  const home = os.homedir();
  const candidates = [
    path.join(home, ".local", "bin", "claude"),
    path.join(home, ".claude", "local", "claude"),
    "/usr/local/bin/claude",
    "/opt/homebrew/bin/claude",
    path.join(home, ".bun", "bin", "claude"),
    path.join(home, ".npm-global", "bin", "claude"),
  ];
  if (process.env.N_PREFIX) {
    candidates.push(path.join(process.env.N_PREFIX, "bin", "claude"));
  }
  return candidates;
}

/** True if `p` exists and has at least one executable bit set (best-effort on all platforms). */
function isExecutable(p) {
  try {
    const st = fs.statSync(p);
    if (!st.isFile()) return false;
    if (process.platform === "win32") return true;
    // eslint-disable-next-line no-bitwise
    return (st.mode & 0o111) !== 0;
  } catch {
    return false;
  }
}

/** `which claude` (or `where claude` on win32) against the current process env. Returns an absolute path or null. */
function whichClaude() {
  const which = spawnSync(process.platform === "win32" ? "where" : "which", ["claude"], {
    encoding: "utf8",
  });
  const stdout = (which.stdout || "").trim();
  if (which.status === 0 && stdout.length > 0) {
    // `where` can print multiple matches, one per line — take the first.
    return stdout.split(/\r?\n/)[0].trim();
  }
  return null;
}

/**
 * Resolves an absolute path to the `claude` CLI, or null if it can't be
 * found anywhere. Re-checks every call (cheap: one spawnSync + a handful of
 * stat calls) so a user who installs claude mid-session sees the Run page
 * pick it up on the next check — no caching, no stale positives/negatives.
 */
function resolveClaudeBin() {
  const override = process.env.PODIUM_CLAUDE_BIN;
  if (override && isExecutable(override)) {
    return override;
  }

  const fromPath = whichClaude();
  if (fromPath) {
    return fromPath;
  }

  for (const candidate of candidatePaths()) {
    if (isExecutable(candidate)) {
      return candidate;
    }
  }

  return null;
}

module.exports = { resolveClaudeBin, candidatePaths, isExecutable };
