/**
 * @file Integration tests for the three routes ROADMAP N3 added
 * (docs/N2-GAP.md MISSING rows, ported from the plugin-era reference server
 * and Sources/PodiumServer/Routes/*.swift):
 *   GET  /api/search
 *   GET  /api/export/session/:id
 *   POST /api/import/session
 * @author Gael Robin <robin.gael@gmail.com>
 */

const { describe, it, before, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");

const TEST_DB = path.join(os.tmpdir(), `dashboard-exim-test-${Date.now()}-${process.pid}.db`);
process.env.DASHBOARD_DB_PATH = TEST_DB;

const { createApp, startServer } = require("../index");
const { db } = require("../db");

let server;
let BASE;
const SESSION_ID = "exim-sess-1";

function fetchJson(urlPath, options = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlPath, BASE);
    const req = http.request(
      {
        hostname: url.hostname,
        port: url.port,
        path: url.pathname + url.search,
        method: options.method || "GET",
        headers: { "Content-Type": "application/json", ...options.headers },
      },
      (res) => {
        let body = "";
        res.on("data", (c) => (body += c));
        res.on("end", () => {
          try {
            resolve({ status: res.statusCode, body: body ? JSON.parse(body) : null });
          } catch {
            resolve({ status: res.statusCode, body });
          }
        });
      }
    );
    req.on("error", reject);
    if (options.body) req.write(JSON.stringify(options.body));
    req.end();
  });
}

before(async () => {
  const app = createApp();
  server = await startServer(app, 0);
  BASE = `http://127.0.0.1:${server.address().port}`;

  await fetchJson("/api/hooks/event", {
    method: "POST",
    body: {
      hook_type: "SessionStart",
      data: { session_id: SESSION_ID, cwd: "/tmp/exim-fixture-project", model: "claude-sonnet-4-5" },
    },
  });
  await fetchJson("/api/hooks/event", {
    method: "POST",
    body: {
      hook_type: "PreToolUse",
      data: { session_id: SESSION_ID, tool_name: "Bash", tool_input: { command: "echo hi" } },
    },
  });
  await fetchJson("/api/hooks/event", {
    method: "POST",
    body: { hook_type: "Stop", data: { session_id: SESSION_ID } },
  });
  await fetchJson("/api/hooks/event", {
    method: "POST",
    body: { hook_type: "SessionEnd", data: { session_id: SESSION_ID } },
  });
});

after(() => {
  server?.close();
  try {
    db.close();
  } catch {
    /* ignore */
  }
  try {
    fs.rmSync(TEST_DB, { force: true });
    fs.rmSync(`${TEST_DB}-wal`, { force: true });
    fs.rmSync(`${TEST_DB}-shm`, { force: true });
  } catch {
    /* ignore */
  }
});

describe("GET /api/search", () => {
  it("returns an empty result set for a blank query", async () => {
    const res = await fetchJson("/api/search?q=");
    assert.equal(res.status, 200);
    assert.deepEqual(res.body, { results: [], total: 0 });
  });

  it("finds the seeded session by cwd, with a <mark>-wrapped highlight", async () => {
    const res = await fetchJson("/api/search?q=exim-fixture-project");
    assert.equal(res.status, 200);
    const hit = res.body.results.find((r) => r.type === "session" && r.session_id === SESSION_ID);
    assert.ok(hit, "expected the seeded session in results");
    assert.equal(hit.cwd, "/tmp/exim-fixture-project");
    assert.match(hit.highlight, /<mark>.*<\/mark>/);
  });

  it("finds events by tool_name", async () => {
    const res = await fetchJson("/api/search?q=Bash");
    assert.equal(res.status, 200);
    const hit = res.body.results.find(
      (r) => r.type === "event" && r.session_id === SESSION_ID && r.tool_name === "Bash"
    );
    assert.ok(hit, "expected a Bash tool-use event in results");
  });
});

describe("GET /api/export/session/:id", () => {
  it("404s with the error envelope for an unknown session", async () => {
    const res = await fetchJson("/api/export/session/does-not-exist");
    assert.equal(res.status, 404);
    assert.equal(res.body.error.code, "NOT_FOUND");
  });

  it("exports a bundle matching podium_export_version 1.0", async () => {
    const res = await fetchJson(`/api/export/session/${SESSION_ID}`);
    assert.equal(res.status, 200);
    assert.equal(res.body.podium_export_version, "1.0");
    assert.equal(res.body.session.id, SESSION_ID);
    assert.ok(Array.isArray(res.body.agents));
    assert.ok(Array.isArray(res.body.events));
    assert.ok(res.body.events.length > 0);
  });
});

describe("POST /api/import/session", () => {
  it("rejects a bundle with an unsupported export version", async () => {
    const res = await fetchJson("/api/import/session", {
      method: "POST",
      body: { podium_export_version: "9.9" },
    });
    assert.equal(res.status, 400);
    assert.equal(res.body.error.code, "UNSUPPORTED_VERSION");
  });

  it("rejects a bundle missing session.id", async () => {
    const res = await fetchJson("/api/import/session", {
      method: "POST",
      body: { podium_export_version: "1.0", session: {} },
    });
    assert.equal(res.status, 400);
    assert.equal(res.body.error.code, "INVALID_INPUT");
  });

  it("round-trips an exported bundle back in under a new session id", async () => {
    const exported = await fetchJson(`/api/export/session/${SESSION_ID}`);
    const bundle = exported.body;
    const newId = "exim-sess-imported";
    bundle.session = { ...bundle.session, id: newId };
    bundle.agents = bundle.agents.map((a) => ({ ...a, session_id: newId }));
    bundle.events = bundle.events.map((e) => {
      const { id: _drop, ...rest } = e; // let events auto-increment on re-insert
      return { ...rest, session_id: newId };
    });

    const res = await fetchJson("/api/import/session", { method: "POST", body: bundle });
    assert.equal(res.status, 200);
    assert.equal(res.body.ok, true);
    assert.equal(res.body.session_id, newId);

    const check = await fetchJson(`/api/sessions/${newId}`);
    assert.equal(check.status, 200);
    assert.equal(check.body.session.id, newId);
    assert.equal(check.body.session.cwd, "/tmp/exim-fixture-project");
    assert.ok(check.body.events.length > 0);
  });

  it("is idempotent — re-importing the same bundle doesn't error", async () => {
    const exported = await fetchJson(`/api/export/session/${SESSION_ID}`);
    const res = await fetchJson("/api/import/session", { method: "POST", body: exported.body });
    assert.equal(res.status, 200);
    assert.equal(res.body.session_id, SESSION_ID);
  });
});
