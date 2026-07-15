/**
 * @file Tests scripts/install-hooks.js:
 *  - the host-only guard (issue #193): the installer must refuse to write a
 *    container-internal handler path into a (possibly bind-mounted) host
 *    ~/.claude/settings.json. Container detection is driven deterministically
 *    via CCAM_FORCE_CONTAINER / CCAM_FORCE_HOST so these tests pass whether or
 *    not the CI runner itself is containerized.
 *  - the podium-hook binary resolution order (env override > repo-relative
 *    hook/dist/podium-hook > packaged-layout sibling of the running server
 *    binary > skip with a warning if none exist) and the write-through of the
 *    resolved binary path into settings.json, replacing legacy markers
 *    (including the never-vendored hook-handler.js) in place.
 * @author Son Nguyen <hoangson091104@gmail.com>
 */

const { describe, it, beforeEach, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");

// Point the installer at a throwaway CLAUDE_HOME BEFORE requiring it — the
// settings path is resolved at module load. (`node --test` isolates each test
// file in its own process, so this does not leak into other suites.)
const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), "ccam-hooks-"));
process.env.CLAUDE_HOME = TMP_HOME;
const SETTINGS = path.join(TMP_HOME, "settings.json");

const { installHooks, isInsideContainer, resolveHookBinary } = require("../scripts/install-hooks");

// The real hook/dist/podium-hook binary, built by `cd hook && bun run build`
// (hook/package.json). Present in this repo checkout after that build step —
// see server/__tests__ setup notes / ROADMAP HOOK-WIRING FIX task.
const REPO_ROOT = path.resolve(__dirname, "..", "..");
const REAL_HOOK_BIN = path.join(REPO_ROOT, "hook", "dist", "podium-hook");

/** A fake, executable-enough stand-in binary for tests that don't need the real build. */
function makeFakeBinary(dir, name = "podium-hook") {
  fs.mkdirSync(dir, { recursive: true });
  const p = path.join(dir, name);
  fs.writeFileSync(p, "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  return p;
}

const HOOK_TYPES = [
  "PreToolUse",
  "PostToolUse",
  "PostToolUseFailure",
  "Stop",
  "SubagentStart",
  "SubagentStop",
  "Notification",
  "SessionStart",
  "SessionEnd",
  "UserPromptSubmit",
];

function clearEnv() {
  delete process.env.CCAM_FORCE_CONTAINER;
  delete process.env.CCAM_FORCE_HOST;
  delete process.env.CCAM_ALLOW_CONTAINER_HOOKS;
  delete process.env.PODIUM_HOOK_BIN;
}

function rmSettings() {
  try {
    fs.unlinkSync(SETTINGS);
  } catch {
    /* not present */
  }
}

describe("install-hooks host-only guard (#193)", () => {
  beforeEach(() => {
    clearEnv();
    rmSettings();
  });

  after(() => {
    clearEnv();
    try {
      fs.rmSync(TMP_HOME, { recursive: true, force: true });
    } catch {
      /* best effort */
    }
  });

  it("refuses inside a container and writes no settings file", () => {
    process.env.CCAM_FORCE_CONTAINER = "1";
    const ok = installHooks(true);
    assert.equal(ok, false);
    assert.equal(
      fs.existsSync(SETTINGS),
      false,
      "settings.json must not be created in a container"
    );
  });

  it("writes when the explicit container override is set", () => {
    process.env.CCAM_FORCE_CONTAINER = "1";
    process.env.CCAM_ALLOW_CONTAINER_HOOKS = "1";
    const ok = installHooks(true);
    assert.equal(ok, true);
    assert.ok(fs.existsSync(SETTINGS));
    const settings = JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
    for (const type of HOOK_TYPES) {
      assert.ok(Array.isArray(settings.hooks[type]), `missing hook list for ${type}`);
      assert.match(JSON.stringify(settings.hooks[type]), /podium-hook/, `${type} not wired`);
    }
  });

  it("writes on a host (not a container)", () => {
    process.env.CCAM_FORCE_HOST = "1";
    const ok = installHooks(true);
    assert.equal(ok, true);
    assert.ok(fs.existsSync(SETTINGS));
  });

  it("is idempotent — re-running updates in place with no duplicate entries", () => {
    process.env.CCAM_FORCE_HOST = "1";
    installHooks(true);
    installHooks(true);
    const settings = JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
    const ours = settings.hooks.PreToolUse.filter((e) =>
      JSON.stringify(e).includes("podium-hook")
    );
    assert.equal(ours.length, 1, "must not duplicate our hook entry on re-run");
  });

  it("isInsideContainer honors the force flags", () => {
    process.env.CCAM_FORCE_CONTAINER = "1";
    assert.equal(isInsideContainer(), true);
    delete process.env.CCAM_FORCE_CONTAINER;
    process.env.CCAM_FORCE_HOST = "1";
    assert.equal(isInsideContainer(), false);
  });

  it("upgrades a legacy hook-handler.js entry in place instead of duplicating it", () => {
    process.env.CCAM_FORCE_HOST = "1";
    // Simulate the pre-fix broken install: a hook-handler.js command that can
    // never resolve, written by every boot before this fix.
    const legacySettings = {
      hooks: {
        PreToolUse: [
          {
            matcher: "*",
            hooks: [{ type: "command", command: 'node "/some/repo/server/scripts/hook-handler.js" PreToolUse' }],
          },
        ],
      },
    };
    fs.writeFileSync(SETTINGS, JSON.stringify(legacySettings, null, 2) + "\n", "utf8");

    const ok = installHooks(true);
    assert.equal(ok, true);
    const settings = JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
    assert.equal(settings.hooks.PreToolUse.length, 1, "legacy entry must be replaced, not duplicated");
    assert.match(
      JSON.stringify(settings.hooks.PreToolUse[0]),
      /podium-hook/,
      "legacy hook-handler.js entry must be upgraded to the real podium-hook binary"
    );
    assert.doesNotMatch(JSON.stringify(settings.hooks.PreToolUse[0]), /hook-handler\.js/);
  });

  it("dedupes TWO stale marker entries on one event down to exactly one, pointing at the resolved binary", () => {
    process.env.CCAM_FORCE_HOST = "1";
    // Real-world bug: a plugin-era legacy entry AND a boot-written
    // hook-handler.js entry both accumulated on the same event because the
    // old `findIndex` logic only ever replaced the first match.
    const legacySettings = {
      hooks: {
        PreToolUse: [
          {
            matcher: "*",
            hooks: [{ type: "command", command: "node \"/old/plugins/cache/wp-media/podium/hook.mjs\" PreToolUse" }],
          },
          {
            matcher: "*",
            hooks: [{ type: "command", command: 'node "/some/repo/server/scripts/hook-handler.js" PreToolUse' }],
          },
        ],
      },
    };
    fs.writeFileSync(SETTINGS, JSON.stringify(legacySettings, null, 2) + "\n", "utf8");

    const ok = installHooks(true);
    assert.equal(ok, true);
    const settings = JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
    assert.equal(settings.hooks.PreToolUse.length, 1, "both stale entries must collapse into exactly one");
    assert.match(JSON.stringify(settings.hooks.PreToolUse[0]), /podium-hook/);
  });

  it("wires the newly-managed PostToolUseFailure/SubagentStart events and upgrades their Swift-era legacy entries", () => {
    process.env.CCAM_FORCE_HOST = "1";
    // The owner's real settings had these two events still pointing at the
    // old Swift binary (~/.claude/podium/podium-hook), which matches
    // OUR_MARKER ("podium-hook") — so it must be upgraded in place, not left
    // stale and not duplicated.
    const legacySettings = {
      hooks: {
        PostToolUseFailure: [
          { matcher: "*", hooks: [{ type: "command", command: '"/Users/x/.claude/podium/podium-hook"' }] },
        ],
        SubagentStart: [
          { matcher: "*", hooks: [{ type: "command", command: '"/Users/x/.claude/podium/podium-hook"' }] },
        ],
      },
    };
    fs.writeFileSync(SETTINGS, JSON.stringify(legacySettings, null, 2) + "\n", "utf8");

    const ok = installHooks(true);
    assert.equal(ok, true);
    const settings = JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
    for (const type of ["PostToolUseFailure", "SubagentStart"]) {
      assert.equal(settings.hooks[type].length, 1, `${type} must have exactly one entry after upgrade`);
      assert.match(JSON.stringify(settings.hooks[type][0]), /podium-hook/, `${type} must be wired`);
    }
  });

  it("leaves non-Podium hook entries on an event with duplicates completely untouched, in order", () => {
    process.env.CCAM_FORCE_HOST = "1";
    const legacySettings = {
      hooks: {
        PreToolUse: [
          { matcher: "Bash", hooks: [{ type: "command", command: "echo user-entry-1" }] },
          { matcher: "*", hooks: [{ type: "command", command: 'node "/some/repo/server/scripts/hook-handler.js" PreToolUse' }] },
          { matcher: "*", hooks: [{ type: "command", command: "node \"/old/plugins/cache/wp-media/podium/hook.mjs\" PreToolUse" }] },
          { matcher: "Write", hooks: [{ type: "command", command: "echo user-entry-2" }] },
        ],
      },
    };
    fs.writeFileSync(SETTINGS, JSON.stringify(legacySettings, null, 2) + "\n", "utf8");

    const ok = installHooks(true);
    assert.equal(ok, true);
    const settings = JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
    const commands = settings.hooks.PreToolUse.map((e) => e.hooks[0].command);
    assert.ok(commands.includes("echo user-entry-1"), "unrelated entry 1 must survive");
    assert.ok(commands.includes("echo user-entry-2"), "unrelated entry 2 must survive");
    const ours = settings.hooks.PreToolUse.filter((e) => JSON.stringify(e).includes("podium-hook"));
    assert.equal(ours.length, 1, "the two stale Podium entries must collapse to exactly one");
    assert.equal(settings.hooks.PreToolUse.length, 3, "2 unrelated + 1 collapsed Podium entry");
  });

  it("end-to-end: PODIUM_HOOK_BIN override is what actually lands in settings.json", () => {
    process.env.CCAM_FORCE_HOST = "1";
    const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "podium-hook-e2e-"));
    const explicit = makeFakeBinary(scratch, "my-custom-podium-hook");
    process.env.PODIUM_HOOK_BIN = explicit;
    try {
      const ok = installHooks(true);
      assert.equal(ok, true);
      const settings = JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
      assert.match(JSON.stringify(settings.hooks.SessionStart), /my-custom-podium-hook/);
    } finally {
      delete process.env.PODIUM_HOOK_BIN;
      fs.rmSync(scratch, { recursive: true, force: true });
    }
  });
});

describe("resolveHookBinary resolution order", () => {
  let scratch;

  beforeEach(() => {
    scratch = fs.mkdtempSync(path.join(os.tmpdir(), "podium-hook-resolve-"));
  });

  after(() => {
    clearEnv();
  });

  it("prefers the real repo-relative hook/dist/podium-hook build when present", () => {
    // Built by `cd hook && bun install && bun run build` per hook/package.json —
    // required by this task's verification step. Skip gracefully if absent so
    // this suite doesn't hard-fail an environment that hasn't built it yet.
    if (!fs.existsSync(REAL_HOOK_BIN)) {
      console.warn(`SKIP: ${REAL_HOOK_BIN} not built — run: cd hook && bun install && bun run build`);
      return;
    }
    const resolved = resolveHookBinary({ repoRoot: REPO_ROOT, env: {}, execPath: null });
    assert.ok(resolved, "expected the repo-relative build to resolve");
    assert.equal(resolved.path, REAL_HOOK_BIN);
    assert.match(resolved.source, /repo/);
  });

  it("PODIUM_HOOK_BIN env override wins over everything else", () => {
    const explicit = makeFakeBinary(path.join(scratch, "explicit-dir"), "custom-hook-bin");
    const repoDir = path.join(scratch, "fake-repo");
    makeFakeBinary(path.join(repoDir, "hook", "dist"), "podium-hook");

    const resolved = resolveHookBinary({
      env: { PODIUM_HOOK_BIN: explicit },
      repoRoot: repoDir,
      execPath: null,
    });
    assert.ok(resolved);
    assert.equal(resolved.path, explicit);
    assert.match(resolved.source, /env/);
  });

  it("falls back to hook/dist/podium-hook relative to a given repo root", () => {
    const repoDir = path.join(scratch, "fake-repo");
    const built = makeFakeBinary(path.join(repoDir, "hook", "dist"), "podium-hook");

    const resolved = resolveHookBinary({ env: {}, repoRoot: repoDir, execPath: null });
    assert.ok(resolved);
    assert.equal(resolved.path, built);
    assert.match(resolved.source, /repo/);
  });

  it("falls back to a podium-hook binary sitting next to the running server binary (packaged layout)", () => {
    const repoDir = path.join(scratch, "fake-repo-no-hook"); // no hook/dist here
    const packagedDir = path.join(scratch, "packaged");
    const sibling = makeFakeBinary(packagedDir, "podium-hook");
    const fakeExecPath = path.join(packagedDir, "podium-server");

    const resolved = resolveHookBinary({ env: {}, repoRoot: repoDir, execPath: fakeExecPath });
    assert.ok(resolved);
    assert.equal(resolved.path, sibling);
    assert.match(resolved.source, /packaged/);
  });

  it("returns null (and installHooks skips) when no binary exists anywhere", () => {
    const repoDir = path.join(scratch, "empty-repo");
    fs.mkdirSync(repoDir, { recursive: true });
    const resolved = resolveHookBinary({ env: {}, repoRoot: repoDir, execPath: path.join(scratch, "nowhere", "node") });
    assert.equal(resolved, null);
  });
});

describe("install-hooks atomic write + .bak backup (ROADMAP §2 P3)", () => {
  beforeEach(() => {
    clearEnv();
    rmSettings();
    try {
      fs.unlinkSync(SETTINGS + ".bak");
    } catch {
      /* not present */
    }
  });

  after(() => {
    clearEnv();
  });

  it("writes no .bak on first install (nothing to back up yet)", () => {
    process.env.CCAM_FORCE_HOST = "1";
    installHooks(true);
    assert.equal(fs.existsSync(SETTINGS), true);
    assert.equal(fs.existsSync(SETTINGS + ".bak"), false);
  });

  it("backs up the prior settings.json to .bak on a subsequent write", () => {
    process.env.CCAM_FORCE_HOST = "1";
    installHooks(true);
    const firstWrite = fs.readFileSync(SETTINGS, "utf8");

    // Simulate an unrelated pre-existing user setting that must survive a
    // re-install untouched, and confirm .bak captures the PRIOR state.
    const settings = JSON.parse(firstWrite);
    settings.someUnrelatedUserSetting = "keep-me";
    fs.writeFileSync(SETTINGS, JSON.stringify(settings, null, 2) + "\n", "utf8");
    const beforeSecondWrite = fs.readFileSync(SETTINGS, "utf8");

    installHooks(true);

    assert.equal(fs.existsSync(SETTINGS + ".bak"), true);
    const backup = fs.readFileSync(SETTINGS + ".bak", "utf8");
    assert.equal(backup, beforeSecondWrite, ".bak must capture the settings.json state just before the write");

    const final = JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
    assert.equal(final.someUnrelatedUserSetting, "keep-me", "unrelated settings must survive re-install");
  });

  it("never leaves a stray .tmp-* file behind after a successful write", () => {
    process.env.CCAM_FORCE_HOST = "1";
    installHooks(true);
    installHooks(true);
    const dirEntries = fs.readdirSync(TMP_HOME);
    const strayTemp = dirEntries.filter((f) => f.includes(".tmp-"));
    assert.deepEqual(strayTemp, [], `expected no stray temp files, found: ${strayTemp}`);
  });
});
