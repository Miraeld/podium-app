/**
 * @file Tests for dashboard self-update HTTP endpoints.
 * @author Son Nguyen <hoangson091104@gmail.com>
 */

const { describe, it, before, after } = require("node:test");
const assert = require("node:assert/strict");
const path = require("path");
const fs = require("fs");
const os = require("os");
const http = require("http");

const TEST_DB = path.join(os.tmpdir(), `dashboard-updates-${Date.now()}-${process.pid}.db`);
process.env.DASHBOARD_DB_PATH = TEST_DB;

const { createApp, startServer } = require("../index");
const { db } = require("../db");

// Stub the GitHub releases call (lib/update-check.js) so these HTTP-level
// tests stay offline/deterministic — no real network dependency, no
// flakiness from GitHub rate limits or connectivity. The semver/repo-slug
// logic itself is covered exhaustively in update-check.test.js.
const realFetch = global.fetch;
global.fetch = async () => ({
  ok: true,
  json: async () => ({
    tag_name: "v0.0.1",
    html_url: "https://github.com/Miraeld/podium-app/releases/tag/v0.0.1",
    published_at: "2026-01-01T00:00:00Z",
    body: null,
  }),
});

let server;
let BASE;

function httpFetch(urlPath, options = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlPath, BASE);
    const opts = {
      hostname: url.hostname,
      port: url.port,
      path: url.pathname + url.search,
      method: options.method || "GET",
      headers: { "Content-Type": "application/json", ...options.headers },
    };
    const req = http.request(opts, (res) => {
      let body = "";
      res.on("data", (chunk) => {
        body += chunk;
      });
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
    if (options.body) req.write(options.body);
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
  if (db) db.close();
  global.fetch = realFetch;
  try {
    fs.unlinkSync(TEST_DB);
    fs.unlinkSync(`${TEST_DB}-wal`);
    fs.unlinkSync(`${TEST_DB}-shm`);
  } catch {
    // ignore
  }
});

describe("GET /api/updates/status", () => {
  it("returns the RepoUpdatesStatusResponse shape (client/src/lib/types.ts)", async () => {
    const res = await httpFetch("/api/updates/status");
    assert.equal(res.status, 200);
    assert.equal(typeof res.body.git_repo, "boolean");
    assert.equal(typeof res.body.update_available, "boolean");
    assert.equal(typeof res.body.current_sha, "string");
    assert.equal(typeof res.body.latest_sha, "string");
    assert.equal(typeof res.body.checked_at, "string");
    assert.equal(typeof res.body.app, "object");
    assert.equal(res.body.app.repo, "Miraeld/podium-app");
  });
});

describe("POST /api/updates/check", () => {
  it("returns a fresh update status payload", async () => {
    const res = await httpFetch("/api/updates/check", { method: "POST", body: "{}" });
    assert.equal(res.status, 200);
    assert.equal(typeof res.body.git_repo, "boolean");
    assert.equal(typeof res.body.update_available, "boolean");
  });
});

describe("removed POST /api/updates/apply", () => {
  it("returns 404 because self-update has been removed", async () => {
    const res = await httpFetch("/api/updates/apply", {
      method: "POST",
      body: "{}",
    });
    assert.equal(res.status, 404);
  });
});
