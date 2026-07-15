/**
 * @file P4 (ROADMAP §2, ported from audit B3): the VAPID private key file
 * must be created `0600` (owner read/write only), and any pre-existing file
 * found looser than that gets tightened on load. Uses a throwaway
 * DASHBOARD_DATA_DIR so this never touches a real user's key file.
 * @author Gael Robin <robin.gael@gmail.com>
 */

const { describe, it, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");

// Isolate: point at a throwaway data dir BEFORE requiring lib/push.js, since
// it computes/creates the key file at module-load time (top-level call).
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "vapid-perm-test-"));
process.env.DASHBOARD_DATA_DIR = tmpDir;

after(() => {
  delete process.env.DASHBOARD_DATA_DIR;
  fs.rmSync(tmpDir, { recursive: true, force: true });
});

describe("VAPID key file permissions (P4)", () => {
  it("creates the key file 0600", () => {
    // Fresh require after setting DASHBOARD_DATA_DIR — loadOrCreateVapidKeys()
    // runs at module load and creates the file under tmpDir.
    require("../lib/push");
    const keysPath = path.join(tmpDir, "vapid-keys.json");
    assert.ok(fs.existsSync(keysPath), "expected vapid-keys.json to be created");
    const mode = fs.statSync(keysPath).mode & 0o777;
    assert.equal(mode, 0o600, `expected mode 0600, got ${mode.toString(8)}`);
  });

  it("tightens a pre-existing looser-permission file on load", () => {
    // Simulate a key file written before this fix landed (e.g. default
    // umask 0644) — reloading lib/push.js (fresh module instance) must
    // tighten it to 0600 without regenerating the keys.
    const keysPath = path.join(tmpDir, "vapid-keys.json");
    const before = JSON.parse(fs.readFileSync(keysPath, "utf8"));
    fs.chmodSync(keysPath, 0o644);
    assert.equal(fs.statSync(keysPath).mode & 0o777, 0o644);

    delete require.cache[require.resolve("../lib/push")];
    require("../lib/push");

    const mode = fs.statSync(keysPath).mode & 0o777;
    assert.equal(mode, 0o600, `expected tightened mode 0600, got ${mode.toString(8)}`);
    const after = JSON.parse(fs.readFileSync(keysPath, "utf8"));
    assert.deepEqual(after, before, "tightening permissions must not regenerate the keys");
  });
});
