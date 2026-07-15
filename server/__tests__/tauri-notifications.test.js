/**
 * @file GET/PUT /api/settings/tauri-notifications — the web-client-facing
 * settings panel for tauri/src-tauri/src/notify_settings.rs's per-event
 * native notification toggles, persisted as flat JSON at
 * <data_dir>/tauri-notifications.json (same file the Rust ws_watcher
 * hot-reloads). Uses a throwaway DASHBOARD_DATA_DIR/DASHBOARD_DB_PATH so
 * this never touches a real user's data dir or ~/.claude/settings.json.
 * @author Gael Robin <robin.gael@gmail.com>
 */

const { describe, it, before, after } = require("node:test");
const assert = require("node:assert/strict");
const path = require("path");
const fs = require("fs");
const os = require("os");
const http = require("http");

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "tauri-notify-test-"));
process.env.DASHBOARD_DATA_DIR = path.join(TMP, "data");
process.env.DASHBOARD_DB_PATH = path.join(TMP, "data", "dashboard.db");
process.env.DASHBOARD_LIVENESS_PROBE = "0";

const { createApp, startServer } = require("../index");

let server;
let BASE;
const NOTIFY_PATH = path.join(process.env.DASHBOARD_DATA_DIR, "tauri-notifications.json");

function fetch(urlPath, options = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlPath, BASE);
    const opts = {
      hostname: url.hostname,
      port: url.port,
      path: url.pathname + url.search,
      method: options.method || "GET",
      headers: { "Content-Type": "application/json" },
    };
    const req = http.request(opts, (res) => {
      let body = "";
      res.on("data", (chunk) => (body += chunk));
      res.on("end", () => {
        let parsed;
        try {
          parsed = JSON.parse(body);
        } catch {
          parsed = body;
        }
        resolve({ status: res.statusCode, body: parsed });
      });
    });
    req.on("error", reject);
    if (options.body) req.write(JSON.stringify(options.body));
    req.end();
  });
}

before(async () => {
  const app = createApp();
  server = await startServer(app, 0);
  const addr = server.address();
  BASE = `http://127.0.0.1:${addr.port}`;
});

after(() => {
  if (server) server.close();
  fs.rmSync(TMP, { recursive: true, force: true });
  delete process.env.DASHBOARD_DATA_DIR;
  delete process.env.DASHBOARD_DB_PATH;
  delete process.env.DASHBOARD_LIVENESS_PROBE;
});

describe("GET /api/settings/tauri-notifications", () => {
  it("returns all-true defaults without creating the file", async () => {
    const res = await fetch("/api/settings/tauri-notifications");
    assert.equal(res.status, 200);
    assert.deepEqual(res.body, {
      on_completed: true,
      on_error: true,
      on_awaiting_input: true,
    });
    assert.equal(fs.existsSync(NOTIFY_PATH), false, "GET must not create the file");
  });
});

describe("PUT /api/settings/tauri-notifications", () => {
  it("merges a partial update and persists it as pretty JSON", async () => {
    const res = await fetch("/api/settings/tauri-notifications", {
      method: "PUT",
      body: { on_completed: false },
    });
    assert.equal(res.status, 200);
    assert.deepEqual(res.body, {
      on_completed: false,
      on_error: true,
      on_awaiting_input: true,
    });

    assert.ok(fs.existsSync(NOTIFY_PATH), "PUT must create the file");
    const onDisk = JSON.parse(fs.readFileSync(NOTIFY_PATH, "utf8"));
    assert.deepEqual(onDisk, res.body);
  });

  it("a subsequent GET reflects the persisted value", async () => {
    const res = await fetch("/api/settings/tauri-notifications");
    assert.equal(res.status, 200);
    assert.equal(res.body.on_completed, false);
    assert.equal(res.body.on_error, true);
  });

  it("further partial updates only touch the given keys", async () => {
    const res = await fetch("/api/settings/tauri-notifications", {
      method: "PUT",
      body: { on_error: false, on_awaiting_input: false },
    });
    assert.equal(res.status, 200);
    assert.deepEqual(res.body, {
      on_completed: false,
      on_error: false,
      on_awaiting_input: false,
    });
  });

  it("rejects a non-boolean value with a 400 error envelope", async () => {
    const res = await fetch("/api/settings/tauri-notifications", {
      method: "PUT",
      body: { on_completed: "yes" },
    });
    assert.equal(res.status, 400);
    assert.ok(res.body.error);
    assert.equal(res.body.error.code, "INVALID_VALUE");

    // Rejected write must not have touched the persisted state.
    const after = await fetch("/api/settings/tauri-notifications");
    assert.equal(after.body.on_completed, false);
  });

  it("rejects an unknown key's non-boolean value the same way, ignoring the key itself", async () => {
    const res = await fetch("/api/settings/tauri-notifications", {
      method: "PUT",
      body: { on_completed: true, unknown_key: "whatever" },
    });
    assert.equal(res.status, 200);
    assert.equal(res.body.on_completed, true);
    assert.ok(!("unknown_key" in res.body));
  });
});
