/**
 * @file security.test.js
 * @description Tests the network-exposure hardening (GHSA-gr74-4xfh-6jw9):
 * loopback-by-default bind, Host-header allowlist (anti DNS-rebinding),
 * loopback-only CORS, and the optional bearer-token gate on /api/* + WebSocket.
 * @author Son Nguyen <hoangson091104@gmail.com>
 */
const { describe, it, afterEach } = require("node:test");
const assert = require("node:assert/strict");
const sec = require("../lib/security");

const ENV_KEYS = ["DASHBOARD_HOST", "DASHBOARD_ALLOWED_HOSTS", "DASHBOARD_TOKEN"];
afterEach(() => {
  for (const k of ENV_KEYS) delete process.env[k];
});

function mockRes() {
  return {
    statusCode: 0,
    body: null,
    status(c) {
      this.statusCode = c;
      return this;
    },
    json(b) {
      this.body = b;
      return this;
    },
  };
}

describe("resolveHost", () => {
  it("defaults to loopback (127.0.0.1)", () => {
    assert.equal(sec.resolveHost(), "127.0.0.1");
  });
  it("honors an explicit DASHBOARD_HOST opt-in", () => {
    process.env.DASHBOARD_HOST = "0.0.0.0";
    assert.equal(sec.resolveHost(), "0.0.0.0");
    assert.equal(sec.isLoopbackHostname("0.0.0.0"), true); // treated as loopback-equiv for Host checks
  });
});

describe("Host allowlist (DNS-rebinding defense)", () => {
  it("allows loopback Host headers", () => {
    assert.equal(sec.isHostAllowed("localhost:4820"), true);
    assert.equal(sec.isHostAllowed("127.0.0.1:4820"), true);
    assert.equal(sec.isHostAllowed("[::1]:4820"), true);
    assert.equal(sec.isHostAllowed(""), true); // missing Host (HTTP/1.0 / local tooling)
  });
  it("rejects a rebound attacker Host", () => {
    assert.equal(sec.isHostAllowed("evil.example"), false);
    assert.equal(sec.isHostAllowed("attacker.example:4820"), false);
  });
  it("permits operator-allowlisted hostnames", () => {
    process.env.DASHBOARD_ALLOWED_HOSTS = "dash.internal, 192.168.1.50";
    assert.equal(sec.isHostAllowed("dash.internal:4820"), true);
    assert.equal(sec.isHostAllowed("192.168.1.50:4820"), true);
    assert.equal(sec.isHostAllowed("evil.example"), false);
  });
  it("hostGuard middleware 403s a disallowed Host", () => {
    const res = mockRes();
    let nexted = false;
    sec.hostGuard({ headers: { host: "evil.example" } }, res, () => (nexted = true));
    assert.equal(nexted, false);
    assert.equal(res.statusCode, 403);
    assert.equal(res.body.error.code, "EBADHOST");
  });
  it("hostGuard middleware allows loopback", () => {
    let nexted = false;
    sec.hostGuard({ headers: { host: "localhost:4820" } }, mockRes(), () => (nexted = true));
    assert.equal(nexted, true);
  });
});

describe("CORS", () => {
  const allowed = (origin) =>
    new Promise((resolve) => sec.corsOptions().origin(origin, (_e, ok) => resolve(ok)));

  it("allows same-origin / no-Origin (curl, the server's own client)", async () => {
    assert.equal(await allowed(undefined), true);
  });
  it("allows loopback origins", async () => {
    assert.equal(await allowed("http://localhost:5173"), true);
    assert.equal(await allowed("http://127.0.0.1:4820"), true);
  });
  it("refuses cross-origin pages", async () => {
    assert.equal(await allowed("https://evil.example"), false);
  });
});

describe("token gate (optional, opt-in)", () => {
  it("is a no-op when DASHBOARD_TOKEN is unset (default)", () => {
    let nexted = false;
    sec.tokenGuard({ path: "/stats", headers: {}, query: {} }, mockRes(), () => (nexted = true));
    assert.equal(nexted, true);
  });

  it("rejects a missing/invalid token when configured", () => {
    process.env.DASHBOARD_TOKEN = "s3cret";
    const res = mockRes();
    let nexted = false;
    sec.tokenGuard({ path: "/stats", headers: {}, query: {} }, res, () => (nexted = true));
    assert.equal(nexted, false);
    assert.equal(res.statusCode, 401);
    assert.equal(res.body.error.code, "EUNAUTHORIZED");

    const res2 = mockRes();
    sec.tokenGuard(
      { path: "/stats", headers: { "x-dashboard-token": "wrong" }, query: {} },
      res2,
      () => {}
    );
    assert.equal(res2.statusCode, 401);
  });

  it("accepts a correct token via header, bearer, or query", () => {
    process.env.DASHBOARD_TOKEN = "s3cret";
    const ok = (req) => {
      let nexted = false;
      sec.tokenGuard(req, mockRes(), () => (nexted = true));
      return nexted;
    };
    assert.equal(
      ok({ path: "/stats", headers: { "x-dashboard-token": "s3cret" }, query: {} }),
      true
    );
    assert.equal(
      ok({ path: "/stats", headers: { authorization: "Bearer s3cret" }, query: {} }),
      true
    );
    assert.equal(ok({ path: "/stats", headers: {}, query: { token: "s3cret" } }), true);
  });

  it("exempts health, docs, and local hook ingestion even when a token is set", () => {
    process.env.DASHBOARD_TOKEN = "s3cret";
    const ok = (path) => {
      let nexted = false;
      sec.tokenGuard({ path, headers: {}, query: {} }, mockRes(), () => (nexted = true));
      return nexted;
    };
    assert.equal(ok("/health"), true);
    assert.equal(ok("/openapi.json"), true);
    assert.equal(ok("/hooks/event"), true);
    assert.equal(ok("/sessions/abc"), false); // still gated
  });
});

describe("WebSocket auth", () => {
  it("allows any upgrade when no token is configured", () => {
    assert.equal(sec.isWebSocketAuthorized({ url: "/ws", headers: {} }), true);
  });
  it("requires a matching ?token= when configured", () => {
    process.env.DASHBOARD_TOKEN = "s3cret";
    assert.equal(sec.isWebSocketAuthorized({ url: "/ws?token=s3cret", headers: {} }), true);
    assert.equal(sec.isWebSocketAuthorized({ url: "/ws?token=nope", headers: {} }), false);
    assert.equal(sec.isWebSocketAuthorized({ url: "/ws", headers: {} }), false);
    assert.equal(
      sec.isWebSocketAuthorized({ url: "/ws", headers: { "x-dashboard-token": "s3cret" } }),
      true
    );
  });
});
