/**
 * @file claude-bin.test.js
 * @description Unit tests for lib/claude-bin.js's `resolveClaudeBin()` — the
 * PATH-independent resolver for the `claude` CLI binary (see the module
 * header for why bare PATH lookups fail under the Tauri sidecar). Uses a
 * throwaway HOME so we never touch the real ~/.local/bin or ~/.claude.
 * Does NOT boot server/index.js — this is a pure function test against
 * lib/claude-bin.js only, so no HOME/DASHBOARD_DATA_DIR server-boot
 * override is needed beyond restoring process.env.HOME afterward.
 * @author Claude
 */

const { describe, it, beforeEach, afterEach } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const fs = require("node:fs");
const os = require("node:os");

const { resolveClaudeBin } = require("../lib/claude-bin");

const ORIGINAL_HOME = process.env.HOME;
const ORIGINAL_PODIUM_CLAUDE_BIN = process.env.PODIUM_CLAUDE_BIN;
const ORIGINAL_PATH = process.env.PATH;

let tmpHome;

function writeFakeExecutable(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, "#!/bin/sh\necho fake-claude\n");
  fs.chmodSync(filePath, 0o755);
}

describe("resolveClaudeBin", () => {
  beforeEach(() => {
    tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), "podium-claude-bin-test-"));
    process.env.HOME = tmpHome;
    // Scrub PATH so `which claude` can't accidentally hit a real install on
    // the machine running the test suite — we want deterministic probing.
    process.env.PATH = "/usr/bin:/bin";
    delete process.env.PODIUM_CLAUDE_BIN;
  });

  afterEach(() => {
    fs.rmSync(tmpHome, { recursive: true, force: true });
    if (ORIGINAL_HOME === undefined) delete process.env.HOME;
    else process.env.HOME = ORIGINAL_HOME;
    if (ORIGINAL_PODIUM_CLAUDE_BIN === undefined) delete process.env.PODIUM_CLAUDE_BIN;
    else process.env.PODIUM_CLAUDE_BIN = ORIGINAL_PODIUM_CLAUDE_BIN;
    if (ORIGINAL_PATH === undefined) delete process.env.PATH;
    else process.env.PATH = ORIGINAL_PATH;
  });

  it("returns null when nothing is found anywhere", () => {
    assert.equal(resolveClaudeBin(), null);
  });

  it("honors PODIUM_CLAUDE_BIN override first, even if it also happens to be on PATH", () => {
    const overridePath = path.join(tmpHome, "custom-location", "claude");
    writeFakeExecutable(overridePath);

    // Also plant a well-known-path candidate to prove override wins over it.
    const wellKnown = path.join(tmpHome, ".local", "bin", "claude");
    writeFakeExecutable(wellKnown);

    process.env.PODIUM_CLAUDE_BIN = overridePath;
    assert.equal(resolveClaudeBin(), overridePath);
  });

  it("ignores PODIUM_CLAUDE_BIN if it points at a nonexistent/non-executable file, and falls through", () => {
    process.env.PODIUM_CLAUDE_BIN = path.join(tmpHome, "does-not-exist", "claude");
    const wellKnown = path.join(tmpHome, ".local", "bin", "claude");
    writeFakeExecutable(wellKnown);

    assert.equal(resolveClaudeBin(), wellKnown);
  });

  it("finds claude via `which` when it's on PATH", () => {
    const binDir = path.join(tmpHome, "which-bin");
    const fakeClaude = path.join(binDir, "claude");
    writeFakeExecutable(fakeClaude);
    process.env.PATH = `${binDir}${path.delimiter}${process.env.PATH}`;

    const resolved = resolveClaudeBin();
    // `which` resolves symlinks/relative bits on some platforms; assert on
    // the real path so a macOS /tmp -> /private/tmp symlink doesn't fail this.
    assert.equal(fs.realpathSync(resolved), fs.realpathSync(fakeClaude));
  });

  it("falls back to well-known install locations when not on PATH", () => {
    const wellKnown = path.join(tmpHome, ".local", "bin", "claude");
    writeFakeExecutable(wellKnown);

    assert.equal(resolveClaudeBin(), wellKnown);
  });

  it("checks ~/.claude/local/claude as another well-known fallback", () => {
    const wellKnown = path.join(tmpHome, ".claude", "local", "claude");
    writeFakeExecutable(wellKnown);

    assert.equal(resolveClaudeBin(), wellKnown);
  });

  it("respects N_PREFIX/bin/claude when N_PREFIX is set", () => {
    const nPrefix = path.join(tmpHome, "n-root");
    const wellKnown = path.join(nPrefix, "bin", "claude");
    writeFakeExecutable(wellKnown);
    process.env.N_PREFIX = nPrefix;

    try {
      assert.equal(resolveClaudeBin(), wellKnown);
    } finally {
      delete process.env.N_PREFIX;
    }
  });
});
