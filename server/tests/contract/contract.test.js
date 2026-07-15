/**
 * @file contract.test.js
 * @description ROADMAP N4 — the permanent wire-contract gate. Ports
 * `Tests/PodiumServerTests/ContractTests.swift` (30 XCTest cases, Swift) to
 * this repo's Node test convention (`node:test`, matching every other file
 * under server/__tests__/ — see the runner-choice note below).
 *
 * Methodology (unchanged from the Swift suite, see its header comment and
 * STANDALONE_PLAN.md §4):
 *   - The REAL server (server/index.js) is booted as a child process on a
 *     scratch port against a temp data dir — never required in-process, so
 *     this suite exercises exactly what a deployed dashboard serves.
 *   - Data is seeded ONLY through POST /api/hooks/event, with the same
 *     recorded-style hook sequence the Swift suite sent (SessionStart →
 *     UserPromptSubmit → PreToolUse/PostToolUse → Agent spawn → SubagentStop
 *     → Stop → SessionEnd, plus a second session left active).
 *   - Every assertion runs against the raw parsed JSON (no schema/DTO layer
 *     to round-trip through and mask a key-casing bug) and checks BOTH that
 *     the documented key is present with the right JSON type AND that its
 *     wrong-casing twin is absent (snake_case endpoints must never also
 *     carry a camelCase duplicate, and the deliberate camelCase exception
 *     families — Workflows, cc-config, the Run "live" family — must never
 *     carry a snake_case duplicial).
 *
 * Runner choice: `node:test`, not Vitest. Every existing suite under
 * server/__tests__/ already standardizes on node:test + node:assert/strict
 * (see package.json's "test" script) — adding Vitest as a second, parallel
 * test runner for one new directory would fragment the toolchain for no
 * benefit; node:test's `describe`/`it`/`before`/`after` cover everything
 * this suite needs (including per-suite `{ skip }`, used elsewhere in this
 * repo's environment-debt suites).
 *
 * /usr/bin/true, NOT /bin/true, would be used here too if this suite spawned
 * a stub — modern macOS (Darwin 25+) has no /bin/true and Linux is
 * usr-merged — but the Run-family test below spawns a scratch shell script
 * instead (there is no Node "claudeBinary" constructor param to inject a
 * fixed executable path; server/lib/run-spawner.js always execs literal
 * "claude" via PATH lookup), so a fake `claude` script is placed on PATH.
 */

const { describe, it, before, after } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const fs = require("node:fs");
const os = require("node:os");
const http = require("node:http");
const { spawn } = require("node:child_process");

const SERVER_ENTRY = path.resolve(__dirname, "..", "..", "index.js");

// ── Fixture identifiers (mirrors ContractTests.swift) ──────────────────────
const sessionA = "sess-contract-a";
const sessionB = "sess-contract-b";
const cwdA = "/tmp/contract-proj-a";
const cwdB = "/tmp/contract-proj-b";

let tempDir;
let claudeHome;
let child;
let port;
let transcriptPathA;

// ── Claude Code path encoding (server/lib/claude-home.js encodeCwd) ────────
function encodeCwd(cwd) {
  return cwd.replace(/[^a-zA-Z0-9]/g, "-");
}

// ── HTTP helpers ────────────────────────────────────────────────────────────
function request(method, urlPath, body) {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? null : JSON.stringify(body);
    const req = http.request(
      {
        hostname: "127.0.0.1",
        port,
        path: urlPath,
        method,
        headers: payload
          ? { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload) }
          : {},
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const raw = Buffer.concat(chunks).toString("utf8");
          let json;
          try {
            json = raw ? JSON.parse(raw) : null;
          } catch {
            json = null;
          }
          resolve({ status: res.statusCode, json, raw });
        });
      }
    );
    req.on("error", reject);
    if (payload) req.write(payload);
    req.end();
  });
}

async function get(urlPath, expectedStatus = 200) {
  const { status, json } = await request("GET", urlPath);
  assert.equal(status, expectedStatus, `GET ${urlPath} — expected ${expectedStatus}, got ${status}`);
  assert.ok(json && typeof json === "object", `GET ${urlPath}: body is not a JSON object`);
  return json;
}

async function postHook(hookType, data) {
  const { status } = await request("POST", "/api/hooks/event", { hook_type: hookType, data });
  assert.equal(status, 200, `hook ${hookType} should be accepted`);
}

function firstObject(json, key, endpoint) {
  const arr = json[key];
  assert.ok(Array.isArray(arr), `${endpoint}: '${key}' is not an array`);
  assert.ok(arr.length > 0, `${endpoint}: '${key}' is empty — seeding should have produced rows`);
  return arr[0];
}

// ── Raw-JSON shape assertion helpers (mirrors ContractTests.swift) ─────────
function kindOf(value) {
  if (value === null || value === undefined) return "null";
  if (Array.isArray(value)) return "array";
  if (typeof value === "boolean") return "bool";
  if (typeof value === "number") return "number";
  if (typeof value === "string") return "string";
  if (typeof value === "object") return "object";
  return undefined;
}

/** "session_id" → "sessionId" */
function camelTwin(snakeKey) {
  const parts = snakeKey.split("_");
  if (parts.length < 2) return snakeKey;
  return parts[0] + parts.slice(1).map((p) => p.charAt(0).toUpperCase() + p.slice(1)).join("");
}

/** "swimLanes" → "swim_lanes" */
function snakeTwin(camelKey) {
  return camelKey.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`);
}

function assertField(obj, key, kinds, endpoint) {
  assert.ok(key in obj, `${endpoint}: missing key '${key}' (present keys: ${Object.keys(obj).sort()})`);
  const actual = kindOf(obj[key]);
  assert.ok(
    kinds.includes(actual),
    `${endpoint}: key '${key}' is ${actual}, expected one of ${kinds.join(",")}`
  );
}

function assertAbsent(obj, key, endpoint) {
  assert.equal(obj[key], undefined, `${endpoint}: key '${key}' must NOT exist (wrong casing family)`);
}

/** snake_case contract field: present + correctly typed + camelCase twin absent. */
function snake(obj, key, kinds, endpoint) {
  assertField(obj, key, kinds, endpoint);
  const twin = camelTwin(key);
  if (twin !== key) assertAbsent(obj, twin, endpoint);
}

/** Optional snake_case field: type checked only if present; twin always absent. */
function optionalSnake(obj, key, kinds, endpoint) {
  if (key in obj && obj[key] !== undefined) {
    const actual = kindOf(obj[key]);
    assert.ok(
      kinds.includes(actual),
      `${endpoint}: optional key '${key}' is ${actual}, expected one of ${kinds.join(",")}`
    );
  }
  const twin = camelTwin(key);
  if (twin !== key) assertAbsent(obj, twin, endpoint);
}

/** camelCase contract field (deliberate exception families): present + snake twin absent. */
function camel(obj, key, kinds, endpoint) {
  assertField(obj, key, kinds, endpoint);
  const twin = snakeTwin(key);
  if (twin !== key) assertAbsent(obj, twin, endpoint);
}

// ── Shared object-shape assertions (client/src/lib/types.ts) ───────────────
function assertSessionShape(session, endpoint) {
  assertField(session, "id", ["string"], endpoint);
  assertField(session, "name", ["string", "null"], endpoint);
  assertField(session, "status", ["string"], endpoint);
  assertField(session, "cwd", ["string", "null"], endpoint);
  assertField(session, "model", ["string", "null"], endpoint);
  snake(session, "started_at", ["string"], endpoint);
  snake(session, "ended_at", ["string", "null"], endpoint);
  assertField(session, "metadata", ["string", "null"], endpoint);
  optionalSnake(session, "agent_count", ["number"], endpoint);
  optionalSnake(session, "last_activity", ["string", "null"], endpoint);
  optionalSnake(session, "awaiting_input_since", ["string", "null"], endpoint);
}

function assertAgentShape(agent, endpoint) {
  assertField(agent, "id", ["string"], endpoint);
  snake(agent, "session_id", ["string"], endpoint);
  assertField(agent, "name", ["string"], endpoint);
  assertField(agent, "type", ["string"], endpoint);
  snake(agent, "subagent_type", ["string", "null"], endpoint);
  assertField(agent, "status", ["string"], endpoint);
  assertField(agent, "task", ["string", "null"], endpoint);
  snake(agent, "current_tool", ["string", "null"], endpoint);
  snake(agent, "started_at", ["string"], endpoint);
  snake(agent, "ended_at", ["string", "null"], endpoint);
  snake(agent, "updated_at", ["string"], endpoint);
  snake(agent, "parent_agent_id", ["string", "null"], endpoint);
  assertField(agent, "metadata", ["string", "null"], endpoint);
  optionalSnake(agent, "awaiting_input_since", ["string", "null"], endpoint);
}

function assertEventShape(event, endpoint) {
  assertField(event, "id", ["number"], endpoint);
  snake(event, "session_id", ["string"], endpoint);
  snake(event, "agent_id", ["string", "null"], endpoint);
  snake(event, "event_type", ["string"], endpoint);
  snake(event, "tool_name", ["string", "null"], endpoint);
  assertField(event, "summary", ["string", "null"], endpoint);
  assertField(event, "data", ["string", "null"], endpoint);
  snake(event, "created_at", ["string"], endpoint);
}

function assertCostResultShape(json, endpoint) {
  snake(json, "total_cost", ["number"], endpoint);
  assertField(json, "breakdown", ["array"], endpoint);
  snake(json, "daily_costs", ["array"], endpoint);
  if (json.breakdown[0]) {
    const row = json.breakdown[0];
    assertField(row, "model", ["string"], endpoint);
    snake(row, "input_tokens", ["number"], endpoint);
    snake(row, "output_tokens", ["number"], endpoint);
    snake(row, "cache_read_tokens", ["number"], endpoint);
    snake(row, "cache_write_tokens", ["number"], endpoint);
    assertField(row, "cost", ["number"], endpoint);
    snake(row, "matched_rule", ["string", "null"], endpoint);
  }
  if (json.daily_costs[0]) {
    const day = json.daily_costs[0];
    assertField(day, "date", ["string"], endpoint);
    assertField(day, "cost", ["number"], endpoint);
  }
}

function assertRunHandleShape(handle, endpoint) {
  assertField(handle, "id", ["string"], endpoint);
  assertField(handle, "pid", ["number", "null"], endpoint);
  assertField(handle, "mode", ["string"], endpoint);
  assertField(handle, "cwd", ["string"], endpoint);
  assertField(handle, "model", ["string", "null"], endpoint);
  camel(handle, "permissionMode", ["string"], endpoint);
  assertField(handle, "effort", ["string", "null"], endpoint);
  assertField(handle, "prompt", ["string"], endpoint);
  assertField(handle, "argv", ["array"], endpoint);
  camel(handle, "resumeSessionId", ["string", "null"], endpoint);
  assertField(handle, "status", ["string"], endpoint);
  camel(handle, "startedAt", ["number"], endpoint);
  camel(handle, "endedAt", ["number", "null"], endpoint);
  camel(handle, "exitCode", ["number", "null"], endpoint);
  assertField(handle, "signal", ["string", "null"], endpoint);
  assertField(handle, "error", ["string", "null"], endpoint);
  camel(handle, "sessionId", ["string", "null"], endpoint);
  camel(handle, "envelopeCount", ["number"], endpoint);
  camel(handle, "stdoutTail", ["string"], endpoint);
  camel(handle, "stderrTail", ["string"], endpoint);
}

// ── Boot + seed ──────────────────────────────────────────────────────────

function waitForHealth(timeout = 10000) {
  const deadline = Date.now() + timeout;
  return new Promise((resolve, reject) => {
    const tick = () => {
      const req = http.get({ hostname: "127.0.0.1", port, path: "/api/health", timeout: 500 }, (res) => {
        let body = "";
        res.on("data", (c) => (body += c));
        res.on("end", () => {
          try {
            if (res.statusCode === 200 && JSON.parse(body)?.status === "ok") return resolve();
          } catch {
            /* not ready yet */
          }
          retry();
        });
      });
      req.on("error", retry);
      req.on("timeout", () => {
        req.destroy();
        retry();
      });
    };
    const retry = () => {
      if (Date.now() > deadline) return reject(new Error(`server did not become healthy within ${timeout}ms`));
      setTimeout(tick, 100);
    };
    tick();
  });
}

function seedClaudeHomeFixture() {
  const skillDir = path.join(claudeHome, "skills", "demo-skill");
  fs.mkdirSync(skillDir, { recursive: true });
  fs.writeFileSync(
    path.join(skillDir, "SKILL.md"),
    "---\ndescription: Demo skill\n---\nDemo body.\n"
  );

  const agentsDir = path.join(claudeHome, "agents");
  fs.mkdirSync(agentsDir, { recursive: true });
  fs.writeFileSync(
    path.join(agentsDir, "reviewer.md"),
    "---\ndescription: Reviews code\n---\nReviewer body.\n"
  );

  const settings = {
    hooks: {
      PreToolUse: [{ matcher: "*", hooks: [{ type: "command", command: "echo hi", timeout: 5 }] }],
    },
    mcpServers: { "demo-mcp": { command: "npx", args: ["demo-server"] } },
  };
  fs.writeFileSync(path.join(claudeHome, "settings.json"), JSON.stringify(settings, null, 2));
}

/**
 * Writes the session A transcript + subagent sidechain fixture — deferred
 * until AFTER the server's initial session-sync sweep has had its one shot
 * (see the comment in `before()`), so that sweep's scan of an empty/missing
 * projects/ dir never races these files into the DB via a second, uncontrolled
 * ingestion path. Every session/agent row this suite asserts on must come
 * ONLY from POST /api/hooks/event.
 */
function seedTranscriptFixture() {
  const projectDir = path.join(claudeHome, "projects", encodeCwd(cwdA));
  fs.mkdirSync(projectDir, { recursive: true });
  transcriptPathA = path.join(projectDir, `${sessionA}.jsonl`);
  const lines = [
    JSON.stringify({
      type: "user",
      timestamp: "2026-07-03T10:00:00.000Z",
      message: { content: "Fix the flaky test" },
    }),
    JSON.stringify({
      type: "assistant",
      timestamp: "2026-07-03T10:00:05.000Z",
      message: {
        model: "claude-sonnet-4-5",
        content: [
          { type: "text", text: "Looking at it." },
          { type: "tool_use", id: "tu_1", name: "Read", input: { file_path: "/tmp/test.swift" } },
        ],
        usage: {
          input_tokens: 500,
          output_tokens: 80,
          cache_read_input_tokens: 10,
          cache_creation_input_tokens: 5,
        },
      },
    }),
    JSON.stringify({
      type: "user",
      timestamp: "2026-07-03T10:00:06.000Z",
      message: {
        content: [
          { type: "tool_result", tool_use_id: "tu_1", content: "file contents", is_error: false },
        ],
      },
    }),
  ];
  fs.writeFileSync(transcriptPathA, lines.join("\n") + "\n");

  // Subagent sidechain transcript so /:id/transcripts lists a subagent.
  const subDir = path.join(projectDir, sessionA, "subagents");
  fs.mkdirSync(subDir, { recursive: true });
  fs.writeFileSync(
    path.join(subDir, "agent-contractsub1.jsonl"),
    JSON.stringify({
      type: "user",
      timestamp: "2026-07-03T10:01:00.000Z",
      message: { content: "Investigate flaky test" },
    }) + "\n"
  );
  fs.writeFileSync(
    path.join(subDir, "agent-contractsub1.meta.json"),
    JSON.stringify({ agentType: "general-purpose", description: "Investigate flaky test" })
  );
}

/**
 * The canonical recorded-style hook sequence — mirrors what podium-hook
 * actually POSTs: `{hook_type, data}` with data carrying session_id/cwd/
 * tool_name/tool_input/tool_response/transcript_path. Session A runs a full
 * lifecycle and completes; session B stays active. 1:1 port of
 * ContractTests.swift's seedViaHooks().
 */
async function seedViaHooks() {
  const tp = transcriptPathA;
  await postHook("SessionStart", {
    session_id: sessionA, cwd: cwdA, model: "claude-sonnet-4-5", transcript_path: tp,
  });
  await postHook("UserPromptSubmit", {
    session_id: sessionA, prompt: "Fix the flaky test", transcript_path: tp,
  });
  await postHook("PreToolUse", {
    session_id: sessionA, tool_name: "Bash",
    tool_input: { command: "swift test" }, tool_use_id: "tu-bash-1", transcript_path: tp,
  });
  await postHook("PostToolUse", {
    session_id: sessionA, tool_name: "Bash",
    tool_input: { command: "swift test" }, tool_response: "All tests passed",
    tool_use_id: "tu-bash-1", transcript_path: tp,
  });
  // Subagent spawn via the Agent tool (routes/hooks.js).
  await postHook("PreToolUse", {
    session_id: sessionA, tool_name: "Agent",
    tool_input: {
      description: "Investigate flaky test",
      subagent_type: "general-purpose",
      prompt: "Investigate the flaky test root cause",
    },
    tool_use_id: "tu-agent-1", transcript_path: tp,
  });
  await postHook("SubagentStop", {
    session_id: sessionA, agent_type: "general-purpose",
    description: "Investigate flaky test", transcript_path: tp,
  });
  await postHook("Stop", { session_id: sessionA, transcript_path: tp });
  await postHook("SessionEnd", { session_id: sessionA, transcript_path: tp });

  // Second session, left active mid-tool-use.
  await postHook("SessionStart", { session_id: sessionB, cwd: cwdB });
  await postHook("PreToolUse", {
    session_id: sessionB, tool_name: "Read", tool_input: { file_path: "/tmp/x" },
  });
}

before(async () => {
  tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "podium-contract-"));
  claudeHome = path.join(tempDir, "claude-home");
  fs.mkdirSync(claudeHome, { recursive: true });
  seedClaudeHomeFixture();

  const dbPath = path.join(tempDir, "dashboard.db");
  // Disable the marker-gated one-time legacy-session import outright (P6/N3
  // note: seeding must flow ONLY through POST /api/hooks/event, not a second,
  // uncontrolled disk-scan ingestion path racing it at boot).
  fs.writeFileSync(path.join(tempDir, ".legacy-import.done"), new Date().toISOString());

  // Fake `claude` binary on PATH for the Run family test — server/lib/
  // run-spawner.js always execs literal "claude" (no injectable binary path
  // the way Swift's RunSpawner took `claudeBinary: "/usr/bin/true"`), so we
  // put a scratch script ahead of the real PATH that exits immediately.
  const binDir = path.join(tempDir, "bin");
  fs.mkdirSync(binDir, { recursive: true });
  const fakeClaude = path.join(binDir, "claude");
  fs.writeFileSync(fakeClaude, "#!/bin/sh\nexit 0\n");
  fs.chmodSync(fakeClaude, 0o755);

  port = 21000 + Math.floor(Math.random() * 18000);

  child = spawn(process.execPath, [SERVER_ENTRY], {
    env: {
      ...process.env,
      NODE_ENV: "test",
      DASHBOARD_DB_PATH: dbPath,
      CLAUDE_HOME: claudeHome,
      HOME: tempDir, // ~/.claude.json resolution (cc-discovery.js getClaudeJsonPath)
      DASHBOARD_PORT: String(port),
      DASHBOARD_LIVENESS_PROBE: "0", // no real `claude` process backs these synthetic sessions
      DASHBOARD_SESSION_SYNC_MS: "3600000", // kill the periodic sweep for the test's lifetime
      DASHBOARD_WORKFLOW_POLL_MS: "0", // disabled outright
      // appRepoSlug() falls back to the real DEFAULT_APP_REPO for anything
      // without a "/" (a no-slash override is silently ignored, not treated
      // as "unconfigured") — point at a guaranteed-nonexistent repo instead,
      // so the GitHub releases lookup 404s deterministically and fast rather
      // than either hitting the real Miraeld/podium-app repo's live release
      // state (non-deterministic across runs) or blocking on network absence
      // up to GITHUB_API_TIMEOUT_MS.
      PODIUM_APP_GITHUB_REPO: "podium-contract-test/definitely-does-not-exist-xyz123",
      PATH: `${binDir}${path.delimiter}${process.env.PATH}`,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stderrTail = "";
  child.stderr.on("data", (c) => {
    stderrTail = (stderrTail + c.toString()).slice(-4000);
  });
  child.on("exit", (code, signal) => {
    if (code !== null && code !== 0) {
      // Surface for debugging if the server dies mid-suite.
      // eslint-disable-next-line no-console
      console.error(`podium-server exited early (code=${code}, signal=${signal}):\n${stderrTail}`);
    }
  });

  await waitForHealth();

  // The unconditional initial session-sync sweep fires ~250ms after listen
  // (server/index.js startSessionSync) — wait it out against an empty/
  // missing projects/ dir before writing the transcript fixture files, so
  // that one-shot sweep can never race our hook-seeded data.
  await new Promise((resolve) => setTimeout(resolve, 600));

  seedTranscriptFixture();
  await seedViaHooks();
});

after(async () => {
  if (child && !child.killed) {
    child.kill("SIGTERM");
    await new Promise((resolve) => {
      child.once("exit", resolve);
      setTimeout(resolve, 2000);
    });
  }
  try {
    fs.rmSync(tempDir, { recursive: true, force: true });
  } catch {
    /* best-effort cleanup */
  }
});

// ── /api/health ──────────────────────────────────────────────────────────

describe("GET /api/health", () => {
  it("returns {status, timestamp} with ISO8601-millis timestamp", async () => {
    const json = await get("/api/health");
    assertField(json, "status", ["string"], "/api/health");
    assertField(json, "timestamp", ["string"], "/api/health");
    assert.match(
      json.timestamp,
      /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/,
      `/api/health timestamp must be ISO8601 with milliseconds + 'Z', got ${json.timestamp}`
    );
  });
});

// ── Error envelope ───────────────────────────────────────────────────────

describe("Error envelope", () => {
  it("404s carry {error:{code,message}}", async () => {
    const json = await get("/api/sessions/does-not-exist", 404);
    assert.ok(json.error && typeof json.error === "object", "error envelope must be {error:{code,message}}");
    assertField(json.error, "code", ["string"], "404 error envelope");
    assertField(json.error, "message", ["string"], "404 error envelope");
  });

  it("an unknown /api/* route 404s with the same envelope (no route matches at all)", async () => {
    const json = await get("/api/events/does-not-exist/full", 404);
    assertField(json.error, "code", ["string"], "unknown route 404");
    assertField(json.error, "message", ["string"], "unknown route 404");
  });

  it("GET /api/diagnostics does not exist — 404 with the same envelope", async () => {
    const json = await get("/api/diagnostics", 404);
    assertField(json.error, "code", ["string"], "/api/diagnostics 404");
    assertField(json.error, "message", ["string"], "/api/diagnostics 404");
  });
});

// ── /api/stats ───────────────────────────────────────────────────────────

describe("GET /api/stats", () => {
  it("matches types.ts Stats", async () => {
    const e = "/api/stats";
    const json = await get("/api/stats?tz_offset=0");
    snake(json, "total_sessions", ["number"], e);
    snake(json, "active_sessions", ["number"], e);
    snake(json, "active_agents", ["number"], e);
    snake(json, "total_agents", ["number"], e);
    snake(json, "total_events", ["number"], e);
    snake(json, "events_today", ["number"], e);
    snake(json, "ws_connections", ["number"], e);
    snake(json, "agents_by_status", ["object"], e);
    snake(json, "sessions_by_status", ["object"], e);
    assert.equal(json.total_sessions, 2);
  });
});

// ── /api/sessions family ─────────────────────────────────────────────────

describe("GET /api/sessions family", () => {
  it("list matches types.ts Session + pagination envelope", async () => {
    const e = "/api/sessions";
    const json = await get("/api/sessions?limit=10&sort_by=time&sort_desc=true");
    assertField(json, "sessions", ["array"], e);
    assertField(json, "total", ["number"], e);
    assertField(json, "limit", ["number"], e);
    assertField(json, "offset", ["number"], e);
    assertSessionShape(firstObject(json, "sessions", e), e);
  });

  it("facets lists distinct cwds", async () => {
    const json = await get("/api/sessions/facets");
    assertField(json, "cwds", ["array"], "/api/sessions/facets");
    assert.deepEqual(new Set(json.cwds), new Set([cwdA, cwdB]));
  });

  it(":id detail includes session + agents[] + events[] and the Agent-tool subagent", async () => {
    const e = "/api/sessions/:id";
    const json = await get(`/api/sessions/${sessionA}`);
    assert.ok(json.session, `${e}: missing 'session'`);
    assertSessionShape(json.session, e);
    assert.equal(json.session.status, "completed", "SessionEnd hook should complete session A");
    assertAgentShape(firstObject(json, "agents", e), e);
    assertEventShape(firstObject(json, "events", e), e);
    assert.ok(
      (json.agents || []).some((a) => a.type === "subagent"),
      `${e}: subagent from Agent tool_use missing`
    );
  });

  it(":id/stats matches types.ts SessionStats", async () => {
    const e = "/api/sessions/:id/stats";
    const json = await get(`/api/sessions/${sessionA}/stats`);
    snake(json, "session_id", ["string"], e);
    snake(json, "total_events", ["number"], e);
    snake(json, "events_by_type", ["array"], e);
    snake(json, "tools_used", ["array"], e);
    snake(json, "error_count", ["number"], e);
    snake(json, "first_event_at", ["string", "null"], e);
    snake(json, "last_event_at", ["string", "null"], e);
    assert.ok(json.agents, `${e}: missing 'agents'`);
    assertField(json.agents, "total", ["number"], e);
    assertField(json.agents, "main", ["number"], e);
    assertField(json.agents, "subagent", ["number"], e);
    assertField(json.agents, "compaction", ["number"], e);
    snake(json.agents, "by_status", ["object"], e);
    snake(json, "subagent_types", ["array"], e);
    assert.ok(json.tokens, `${e}: missing 'tokens'`);
    snake(json.tokens, "input_tokens", ["number"], e);
    snake(json.tokens, "output_tokens", ["number"], e);
    snake(json.tokens, "cache_read_tokens", ["number"], e);
    snake(json.tokens, "cache_write_tokens", ["number"], e);
    if (json.events_by_type[0]) {
      snake(json.events_by_type[0], "event_type", ["string"], e);
      assertField(json.events_by_type[0], "count", ["number"], e);
    }
    if (json.tools_used[0]) {
      snake(json.tools_used[0], "tool_name", ["string"], e);
      assertField(json.tools_used[0], "count", ["number"], e);
    }
  });

  it(":id/transcripts lists main + subagent transcript entries", async () => {
    const e = "/api/sessions/:id/transcripts";
    const json = await get(`/api/sessions/${sessionA}/transcripts`);
    const entry = firstObject(json, "transcripts", e);
    assertField(entry, "id", ["string"], e);
    assertField(entry, "name", ["string"], e);
    assertField(entry, "type", ["string"], e);
    optionalSnake(entry, "subagent_type", ["string", "null"], e);
    snake(entry, "has_transcript", ["bool"], e);
    optionalSnake(entry, "db_agent_id", ["string", "null"], e);
    const entries = json.transcripts || [];
    assert.ok(entries.some((t) => t.type === "main"), `${e}: main transcript missing`);
    assert.ok(entries.some((t) => t.type === "subagent"), `${e}: subagent transcript missing`);
  });

  it(":id/transcript matches types.ts TranscriptResult + TranscriptMessage", async () => {
    const e = "/api/sessions/:id/transcript";
    const json = await get(`/api/sessions/${sessionA}/transcript`);
    assertField(json, "messages", ["array"], e);
    assertField(json, "total", ["number"], e);
    snake(json, "has_more", ["bool"], e);
    snake(json, "last_line", ["number"], e);
    snake(json, "first_line", ["number"], e);
    const message = firstObject(json, "messages", e);
    assertField(message, "type", ["string"], e);
    assertField(message, "timestamp", ["string", "null"], e);
    assertField(message, "content", ["array"], e);
    if (message.content[0]) assertField(message.content[0], "type", ["string"], e);
    const assistant = (json.messages || []).find((m) => m.type === "assistant");
    if (assistant && assistant.usage) {
      snake(assistant.usage, "input_tokens", ["number"], e);
      snake(assistant.usage, "output_tokens", ["number"], e);
      optionalSnake(assistant.usage, "cache_read_input_tokens", ["number"], e);
      optionalSnake(assistant.usage, "cache_creation_input_tokens", ["number"], e);
    }
  });
});

// ── /api/agents family ───────────────────────────────────────────────────

describe("GET /api/agents family", () => {
  it("list matches types.ts Agent", async () => {
    const e = "/api/agents";
    const json = await get(`/api/agents?session_id=${sessionA}`);
    assertAgentShape(firstObject(json, "agents", e), e);
  });

  // GET /api/agents/:id and POST /api/agents were trimmed from the Swift
  // server's public surface (audit B6) but upstream still serves both — the
  // client never calls either (ROADMAP N2-GAP.md P6 note), so this asserts
  // upstream's ACTUAL behavior rather than reintroducing the trim here.
  it(":id (kept-dormant upstream endpoint, client never calls it) returns the agent", async () => {
    const e = "/api/agents/:id";
    const json = await get(`/api/agents/${sessionA}-main`);
    assert.ok(json.agent, `${e}: missing 'agent'`);
    assertAgentShape(json.agent, e);
  });

  it(":id 404s with the standard envelope for an unknown agent", async () => {
    const json = await get("/api/agents/does-not-exist", 404);
    assertField(json.error, "code", ["string"], "/api/agents/:id 404");
    assertField(json.error, "message", ["string"], "/api/agents/:id 404");
  });

  it("POST / (kept-dormant upstream endpoint, client never calls it) creates an agent", async () => {
    const { status, json } = await request("POST", "/api/agents", {
      id: "contract-manual-agent-1",
      session_id: sessionA,
      name: "Manually created",
    });
    assert.equal(status, 201);
    assert.ok(json.agent, "POST /api/agents: missing 'agent'");
    assertAgentShape(json.agent, "POST /api/agents");
    assert.equal(json.agent.id, "contract-manual-agent-1");
  });
});

// ── /api/events family ───────────────────────────────────────────────────

describe("GET /api/events family", () => {
  it("list matches types.ts DashboardEvent + pagination envelope", async () => {
    const e = "/api/events";
    const json = await get(`/api/events?session_id=${sessionA}&limit=50`);
    assertField(json, "events", ["array"], e);
    assertField(json, "limit", ["number"], e);
    assertField(json, "offset", ["number"], e);
    assertField(json, "total", ["number"], e);
    assertEventShape(firstObject(json, "events", e), e);
  });

  it("facets lists distinct event_types/tool_names", async () => {
    const e = "/api/events/facets";
    const json = await get(e);
    snake(json, "event_types", ["array"], e);
    snake(json, "tool_names", ["array"], e);
    assert.ok((json.event_types || []).includes("SessionStart"));
  });
});

// ── /api/analytics ───────────────────────────────────────────────────────

describe("GET /api/analytics", () => {
  it("matches types.ts Analytics, with real token totals from transcript extraction", async () => {
    const e = "/api/analytics";
    const json = await get("/api/analytics?tz_offset=0");
    assert.ok(json.tokens, `${e}: missing 'tokens'`);
    snake(json.tokens, "total_input", ["number"], e);
    snake(json.tokens, "total_output", ["number"], e);
    snake(json.tokens, "total_cache_read", ["number"], e);
    snake(json.tokens, "total_cache_write", ["number"], e);
    snake(json, "tool_usage", ["array"], e);
    snake(json, "daily_events", ["array"], e);
    snake(json, "daily_sessions", ["array"], e);
    snake(json, "agent_types", ["array"], e);
    snake(json, "event_types", ["array"], e);
    snake(json, "avg_events_per_session", ["number"], e);
    snake(json, "total_subagents", ["number"], e);
    snake(json, "agents_by_status", ["object"], e);
    snake(json, "sessions_by_status", ["object"], e);
    assert.ok(json.overview, `${e}: missing 'overview'`);
    snake(json.overview, "total_sessions", ["number"], e);
    snake(json.overview, "active_sessions", ["number"], e);
    snake(json.overview, "active_agents", ["number"], e);
    snake(json.overview, "total_agents", ["number"], e);
    snake(json.overview, "total_events", ["number"], e);
    assert.ok(json.tokens.total_input > 0, `${e}: transcript token extraction produced no tokens`);
    if (json.tool_usage[0]) {
      snake(json.tool_usage[0], "tool_name", ["string"], e);
      assertField(json.tool_usage[0], "count", ["number"], e);
    }
    if (json.daily_events[0]) {
      assertField(json.daily_events[0], "date", ["string"], e);
      assertField(json.daily_events[0], "count", ["number"], e);
    }
    if (json.agent_types[0]) {
      snake(json.agent_types[0], "subagent_type", ["string", "null"], e);
      assertField(json.agent_types[0], "count", ["number"], e);
    }
  });
});

// ── /api/search ──────────────────────────────────────────────────────────

describe("GET /api/search", () => {
  it("matches pages/Search.tsx's SearchResponse/SearchResult", async () => {
    const e = "/api/search";
    const json = await get("/api/search?q=flaky&limit=20&offset=0");
    assertField(json, "results", ["array"], e);
    assertField(json, "total", ["number"], e);
    assert.ok(json.results.length > 0, `${e}: expected hits for 'flaky' (session name + event summaries)`);
    const sessionHit = json.results.find((r) => r.type === "session");
    if (sessionHit) {
      snake(sessionHit, "session_id", ["string"], e);
      snake(sessionHit, "session_name", ["string", "null"], e);
      assertField(sessionHit, "cwd", ["string", "null"], e);
      assertField(sessionHit, "status", ["string", "null"], e);
      snake(sessionHit, "started_at", ["string", "null"], e);
    }
    const eventHit = json.results.find((r) => r.type === "event");
    if (eventHit) {
      snake(eventHit, "session_id", ["string"], e);
      snake(eventHit, "event_id", ["number"], e);
      snake(eventHit, "event_type", ["string", "null"], e);
      snake(eventHit, "tool_name", ["string", "null"], e);
      assertField(eventHit, "summary", ["string", "null"], e);
      snake(eventHit, "created_at", ["string", "null"], e);
    }
  });
});

// ── /api/pricing family ──────────────────────────────────────────────────

describe("GET /api/pricing family", () => {
  it("list matches types.ts ModelPricing (default seed is never empty)", async () => {
    const e = "/api/pricing";
    const json = await get(e);
    const rule = firstObject(json, "pricing", e);
    snake(rule, "model_pattern", ["string"], e);
    snake(rule, "display_name", ["string"], e);
    snake(rule, "input_per_mtok", ["number"], e);
    snake(rule, "output_per_mtok", ["number"], e);
    snake(rule, "cache_read_per_mtok", ["number"], e);
    snake(rule, "cache_write_per_mtok", ["number"], e);
    snake(rule, "updated_at", ["string"], e);
  });

  it("cost + cost/:sessionId match types.ts CostResult", async () => {
    const total = await get("/api/pricing/cost?tz_offset=0");
    assertCostResultShape(total, "/api/pricing/cost");
    assert.ok(total.breakdown.length > 0, "/api/pricing/cost: seeded tokens should yield a breakdown row");

    const perSession = await get(`/api/pricing/cost/${sessionA}?tz_offset=0`);
    assertCostResultShape(perSession, "/api/pricing/cost/:sessionId");
  });
});

// ── /api/settings/info ───────────────────────────────────────────────────

describe("GET /api/settings/info", () => {
  it("matches api.ts's mixed-casing literal shape", async () => {
    const e = "/api/settings/info";
    const json = await get(e);

    assert.ok(json.db, `${e}: missing 'db'`);
    assertField(json.db, "path", ["string"], e);
    assertField(json.db, "size", ["number"], e);
    assertField(json.db, "counts", ["object"], e);
    assert.ok(json.db.pragmas, `${e}: missing db.pragmas`);
    snake(json.db.pragmas, "journal_mode", ["string"], e);
    assertField(json.db.pragmas, "synchronous", ["number"], e);
    snake(json.db.pragmas, "auto_vacuum", ["number"], e);
    assertField(json.db.pragmas, "encoding", ["string"], e);
    snake(json.db.pragmas, "foreign_keys", ["number"], e);
    snake(json.db.pragmas, "busy_timeout", ["number"], e);
    assert.ok(json.db.load_stats, `${e}: missing db.load_stats`);
    assertField(json.db.load_stats, "m5", ["number"], e);
    assertField(json.db.load_stats, "m15", ["number"], e);
    assertField(json.db.load_stats, "h1", ["number"], e);

    assert.ok(json.hooks, `${e}: missing 'hooks'`);
    assertField(json.hooks, "installed", ["bool"], e);
    assertField(json.hooks, "path", ["string"], e);
    assertField(json.hooks, "hooks", ["object"], e);

    assert.ok(json.server, `${e}: missing 'server'`);
    assertField(json.server, "uptime", ["number"], e);
    snake(json.server, "node_version", ["string"], e);
    assertField(json.server, "platform", ["string"], e);
    snake(json.server, "ws_connections", ["number"], e);
    snake(json.server, "cpu_load", ["array"], e);
    assertField(json.server, "arch", ["string"], e);
    snake(json.server, "total_mem", ["number"], e);
    snake(json.server, "free_mem", ["number"], e);
    assertField(json.server, "cpus", ["number"], e);
    // Node's process.memoryUsage() keys are camelCase literals (api.ts).
    assert.ok(json.server.memory, `${e}: missing server.memory`);
    assertField(json.server.memory, "rss", ["number"], e);
    camel(json.server.memory, "heapTotal", ["number"], e);
    camel(json.server.memory, "heapUsed", ["number"], e);
    assertField(json.server.memory, "external", ["number"], e);

    // transcript_cache: snake_case container, camelCase `maxSize` inside.
    assert.ok(json.transcript_cache, `${e}: missing 'transcript_cache'`);
    assertAbsent(json, "transcriptCache", e);
    assertField(json.transcript_cache, "size", ["number"], e);
    camel(json.transcript_cache, "maxSize", ["number"], e);
    assertField(json.transcript_cache, "hits", ["number"], e);
    assertField(json.transcript_cache, "misses", ["number"], e);
    assertField(json.transcript_cache, "keys", ["array"], e);
  });
});

// ── /api/workflows (camelCase exception family) ──────────────────────────

describe("GET /api/workflows family", () => {
  it("aggregate matches types.ts WorkflowData", async () => {
    const e = "/api/workflows";
    const json = await get(e);

    assert.ok(json.stats, `${e}: missing 'stats'`);
    camel(json.stats, "totalSessions", ["number"], e);
    camel(json.stats, "totalAgents", ["number"], e);
    camel(json.stats, "totalSubagents", ["number"], e);
    camel(json.stats, "avgSubagents", ["number"], e);
    camel(json.stats, "successRate", ["number"], e);
    camel(json.stats, "avgDepth", ["number"], e);
    camel(json.stats, "avgDurationSec", ["number"], e);
    camel(json.stats, "totalCompactions", ["number"], e);
    camel(json.stats, "avgCompactions", ["number"], e);
    assertField(json.stats, "topFlow", ["object", "null"], e);

    assert.ok(json.orchestration, `${e}: missing 'orchestration'`);
    camel(json.orchestration, "sessionCount", ["number"], e);
    camel(json.orchestration, "mainCount", ["number"], e);
    camel(json.orchestration, "subagentTypes", ["array"], e);
    assertField(json.orchestration, "edges", ["array"], e);
    assertField(json.orchestration, "outcomes", ["array"], e);
    assertField(json.orchestration, "compactions", ["object"], e);
    if (json.orchestration.subagentTypes[0]) {
      const st = json.orchestration.subagentTypes[0];
      snake(st, "subagent_type", ["string", "null"], e);
      assertField(st, "count", ["number"], e);
      assertField(st, "completed", ["number"], e);
      assertField(st, "errors", ["number"], e);
    }

    camel(json, "toolFlow", ["object"], e);
    assertField(json.toolFlow, "transitions", ["array"], e);
    camel(json.toolFlow, "toolCounts", ["array"], e);

    assertField(json, "effectiveness", ["array"], e);
    if (json.effectiveness[0]) {
      const eff = json.effectiveness[0];
      snake(eff, "subagent_type", ["string", "null"], e);
      assertField(eff, "total", ["number"], e);
      camel(eff, "successRate", ["number"], e);
      camel(eff, "avgDuration", ["number", "null"], e);
      assertField(eff, "trend", ["array"], e);
    }

    assert.ok(json.patterns, `${e}: missing 'patterns'`);
    assertField(json.patterns, "patterns", ["array"], e);
    camel(json.patterns, "soloSessionCount", ["number"], e);
    camel(json.patterns, "soloPercentage", ["number"], e);

    camel(json, "modelDelegation", ["object"], e);
    camel(json.modelDelegation, "mainModels", ["array"], e);
    camel(json.modelDelegation, "subagentModels", ["array"], e);
    camel(json.modelDelegation, "tokensByModel", ["array"], e);
    if (json.modelDelegation.tokensByModel[0]) {
      const tk = json.modelDelegation.tokensByModel[0];
      assertField(tk, "model", ["string"], e);
      snake(tk, "input_tokens", ["number"], e);
      snake(tk, "output_tokens", ["number"], e);
    }

    camel(json, "errorPropagation", ["object"], e);
    camel(json.errorPropagation, "byDepth", ["array"], e);
    camel(json.errorPropagation, "byType", ["array"], e);
    camel(json.errorPropagation, "eventErrors", ["array"], e);
    camel(json.errorPropagation, "sessionsWithErrors", ["number"], e);
    camel(json.errorPropagation, "totalSessions", ["number"], e);
    camel(json.errorPropagation, "errorRate", ["number"], e);

    assert.ok(json.concurrency, `${e}: missing 'concurrency'`);
    camel(json.concurrency, "aggregateLanes", ["array"], e);

    assertField(json, "complexity", ["array"], e);
    if (json.complexity[0]) {
      const cx = json.complexity[0];
      assertField(cx, "id", ["string"], e);
      assertField(cx, "duration", ["number"], e);
      camel(cx, "agentCount", ["number"], e);
      camel(cx, "subagentCount", ["number"], e);
      camel(cx, "totalTokens", ["number"], e);
    }

    assert.ok(json.compaction, `${e}: missing 'compaction'`);
    camel(json.compaction, "totalCompactions", ["number"], e);
    camel(json.compaction, "tokensRecovered", ["number"], e);
    camel(json.compaction, "perSession", ["array"], e);
    camel(json.compaction, "sessionsWithCompactions", ["number"], e);
    camel(json.compaction, "totalSessions", ["number"], e);

    assertField(json, "cooccurrence", ["array"], e);
  });

  it("session/:id drill-in matches types.ts SessionDrillIn", async () => {
    const e = "/api/workflows/session/:id";
    const json = await get(`/api/workflows/session/${sessionA}`);

    assert.ok(json.session, `${e}: missing 'session'`);
    assertSessionShape(json.session, e);

    camel(json, "toolTimeline", ["array"], e);
    camel(json, "swimLanes", ["array"], e);
    assertField(json, "tree", ["array"], e);
    assertField(json, "events", ["array"], e);

    const node = firstObject(json, "tree", e);
    assertField(node, "id", ["string"], e);
    assertField(node, "name", ["string"], e);
    assertField(node, "type", ["string"], e);
    snake(node, "subagent_type", ["string", "null"], e);
    assertField(node, "status", ["string"], e);
    assertField(node, "task", ["string", "null"], e);
    snake(node, "started_at", ["string"], e);
    snake(node, "ended_at", ["string", "null"], e);
    assertField(node, "children", ["array"], e);

    const timelineEntry = firstObject(json, "toolTimeline", e);
    assertField(timelineEntry, "id", ["number"], e);
    snake(timelineEntry, "tool_name", ["string", "null"], e);
    snake(timelineEntry, "event_type", ["string"], e);
    snake(timelineEntry, "agent_id", ["string", "null"], e);
    snake(timelineEntry, "created_at", ["string"], e);
    assertField(timelineEntry, "summary", ["string", "null"], e);

    const lane = firstObject(json, "swimLanes", e);
    assertField(lane, "id", ["string"], e);
    assertField(lane, "name", ["string"], e);
    assertField(lane, "type", ["string"], e);
    snake(lane, "subagent_type", ["string", "null"], e);
    assertField(lane, "status", ["string"], e);
    snake(lane, "started_at", ["string"], e);
    snake(lane, "ended_at", ["string", "null"], e);
    snake(lane, "parent_agent_id", ["string", "null"], e);

    assertEventShape(firstObject(json, "events", e), e);
  });
});

// ── /api/run family (deliberate camelCase "live" family) ────────────────

describe("GET/POST /api/run family", () => {
  it("start → list → detail → history → cwds → binary all match api.ts's RunHandle family", async () => {
    const { status: createStatus, json: handle } = await request("POST", "/api/run", {
      prompt: "contract check", mode: "headless", cwd: tempDir,
    });
    assert.equal(createStatus, 201, `POST /api/run — body: ${JSON.stringify(handle)}`);
    assertRunHandleShape(handle, "POST /api/run");

    const e = "/api/run";
    const list = await get(e);
    assertField(list, "items", ["array"], e);
    camel(list, "maxConcurrent", ["number"], e);
    camel(list, "activeCount", ["number"], e);
    assertRunHandleShape(firstObject(list, "items", e), e);

    const detail = await get(`/api/run/${handle.id}?envelopes=1`);
    assertRunHandleShape(detail, "/api/run/:id");
    assertField(detail, "envelopes", ["array"], "/api/run/:id?envelopes=1");

    // history: DB snake_case columns + the one hand-added camelCase `isLive`.
    const eh = "/api/run/history";
    const history = await get(`${eh}?limit=50`);
    const item = firstObject(history, "items", eh);
    assertField(item, "id", ["string"], eh);
    snake(item, "session_id", ["string", "null"], eh);
    assertField(item, "mode", ["string"], eh);
    assertField(item, "cwd", ["string"], eh);
    assertField(item, "model", ["string", "null"], eh);
    snake(item, "permission_mode", ["string", "null"], eh);
    assertField(item, "effort", ["string", "null"], eh);
    snake(item, "resume_session_id", ["string", "null"], eh);
    snake(item, "prompt_preview", ["string", "null"], eh);
    assertField(item, "status", ["string"], eh);
    snake(item, "exit_code", ["number", "null"], eh);
    snake(item, "started_at", ["string"], eh);
    snake(item, "ended_at", ["string", "null"], eh);
    camel(item, "isLive", ["bool"], eh);

    const cwds = await get("/api/run/cwds");
    assertField(cwds, "items", ["array"], "/api/run/cwds");
    if (cwds.items[0]) {
      assertField(cwds.items[0], "kind", ["string"], "/api/run/cwds");
      assertField(cwds.items[0], "path", ["string"], "/api/run/cwds");
      assertField(cwds.items[0], "label", ["string"], "/api/run/cwds");
    }
    const binary = await get("/api/run/binary");
    assertField(binary, "found", ["bool"], "/api/run/binary");
    assertField(binary, "path", ["string", "null"], "/api/run/binary");
  });
});

// ── /api/push/vapid-public-key ───────────────────────────────────────────

describe("GET /api/push/vapid-public-key", () => {
  it("matches lib/push.ts's { publicKey }", async () => {
    const e = "/api/push/vapid-public-key";
    const json = await get(e);
    camel(json, "publicKey", ["string"], e);
    assert.ok(json.publicKey.length > 0);
  });
});

// ── /api/import/guide ────────────────────────────────────────────────────

describe("GET /api/import/guide", () => {
  it("matches api.ts's ImportGuide shape", async () => {
    const e = "/api/import/guide";
    const json = await get(e);
    assertField(json, "platform", ["string"], e);
    snake(json, "default_projects_dir", ["string"], e);
    snake(json, "default_projects_dir_display", ["string"], e);
    snake(json, "default_projects_dir_exists", ["bool"], e);
    snake(json, "archive_command", ["string"], e);
    snake(json, "supported_extensions", ["array"], e);
    snake(json, "max_upload_bytes", ["number"], e);
    snake(json, "max_upload_files", ["number"], e);
    assert.ok(json.default_projects_dir_stats, `${e}: missing 'default_projects_dir_stats'`);
    assertAbsent(json, "defaultProjectsDirStats", e);
    assertField(json.default_projects_dir_stats, "projects", ["number"], e);
    snake(json.default_projects_dir_stats, "jsonl_files", ["number"], e);
    const step = firstObject(json, "steps", e);
    assertField(step, "id", ["string"], e);
    assertField(step, "title", ["string"], e);
    assertField(step, "body", ["string"], e);
  });
});

// ── /api/cc-config family (camelCase exception family) ───────────────────

describe("GET /api/cc-config family", () => {
  it("overview matches api.ts's CcConfigOverview", async () => {
    const e = "/api/cc-config/overview";
    const json = await get(e);

    assert.ok(json.roots, `${e}: missing 'roots'`);
    camel(json.roots, "claudeHome", ["string"], e);
    camel(json.roots, "projectClaudeDir", ["string"], e);
    camel(json.roots, "projectRoot", ["string"], e);
    camel(json.roots, "claudeJson", ["string"], e);

    assert.ok(json.counts, `${e}: missing 'counts'`);
    assertField(json.counts, "skills", ["object"], e);
    assertField(json.counts, "agents", ["object"], e);
    assertField(json.counts, "commands", ["object"], e);
    camel(json.counts, "outputStyles", ["object"], e);
    assertField(json.counts, "plugins", ["number"], e);
    camel(json.counts, "pluginsEnabled", ["number"], e);
    camel(json.counts, "pluginsDisabled", ["number"], e);
    assertField(json.counts, "marketplaces", ["number"], e);
    assertField(json.counts, "keybindings", ["number"], e);
    camel(json.counts, "mcpServers", ["object"], e);
    assertField(json.counts, "hooks", ["object"], e);
    assertField(json.counts, "memory", ["number"], e);
    camel(json.counts, "settingsFiles", ["number"], e);

    assert.equal(json.counts.skills.user, 1, `${e}: fixture seeded exactly one user skill`);
    assert.equal(json.counts.agents.user, 1, `${e}: fixture seeded exactly one user agent`);
  });

  it("skills/agents/settings/hooks/mcp panels match api.ts", async () => {
    const eSkills = "/api/cc-config/skills";
    const skills = await get(`${eSkills}?scope=user`);
    const skill = firstObject(skills, "items", eSkills);
    assertField(skill, "scope", ["string"], eSkills);
    assertField(skill, "name", ["string"], eSkills);
    assertField(skill, "path", ["string"], eSkills);
    assertField(skill, "file", ["string"], eSkills);
    assertField(skill, "size", ["number"], eSkills);
    assertField(skill, "mtime", ["number"], eSkills);
    assertField(skill, "truncated", ["bool"], eSkills);
    assertField(skill, "frontmatter", ["object"], eSkills);
    assertField(skill, "preview", ["string"], eSkills);
    assert.equal(skill.name, "demo-skill");

    const eAgents = "/api/cc-config/agents";
    const agents = await get(`${eAgents}?scope=user`);
    const agent = firstObject(agents, "items", eAgents);
    assertField(agent, "scope", ["string"], eAgents);
    assertField(agent, "name", ["string"], eAgents);
    assertField(agent, "file", ["string"], eAgents);
    assertField(agent, "frontmatter", ["object"], eAgents);
    assertField(agent, "preview", ["string"], eAgents);
    assert.equal(agent.name, "reviewer");
    assert.equal(agent.frontmatter.description, "Reviews code");

    const eSettings = "/api/cc-config/settings";
    const settings = await get(eSettings);
    assert.ok(Array.isArray(settings.items), `${eSettings}: missing 'items'`);
    const userSource = settings.items.find((s) => s.scope === "user");
    assert.ok(userSource);
    assertField(userSource, "scope", ["string"], eSettings);
    assertField(userSource, "file", ["string"], eSettings);
    assertField(userSource, "exists", ["bool"], eSettings);
    assert.equal(userSource.exists, true, `${eSettings}: fixture settings.json exists`);
    optionalSnake(userSource, "raw_size", ["number"], eSettings);

    const eHooks = "/api/cc-config/hooks";
    const hooks = await get(eHooks);
    assert.ok(Array.isArray(hooks.items), `${eHooks}: missing 'items'`);
    const userHooks = hooks.items.find((s) => s.scope === "user");
    assert.ok(userHooks);
    assertField(userHooks, "scope", ["string"], eHooks);
    assertField(userHooks, "file", ["string"], eHooks);
    assertField(userHooks, "exists", ["bool"], eHooks);
    assert.ok(userHooks.hooks, `${eHooks}: missing 'hooks' map`);
    const preToolUse = userHooks.hooks.PreToolUse;
    assert.ok(Array.isArray(preToolUse), `${eHooks}: fixture PreToolUse hook missing`);
    const entry = preToolUse[0];
    assert.ok(entry);
    assertField(entry, "matcher", ["string"], eHooks);
    assertField(entry, "type", ["string"], eHooks);
    assertField(entry, "command", ["string", "null"], eHooks);
    assertField(entry, "timeout", ["number", "null"], eHooks);

    const eMcp = "/api/cc-config/mcp";
    const mcp = await get(eMcp);
    assertField(mcp, "user", ["array"], eMcp);
    camel(mcp, "projectScoped", ["array"], eMcp);
    const server = firstObject(mcp, "user", eMcp);
    assertField(server, "name", ["string"], eMcp);
    assertField(server, "source", ["string"], eMcp);
    assertField(server, "kind", ["string"], eMcp);
    assert.equal(server.name, "demo-mcp");
    assert.equal(server.kind, "stdio");
  });
});

// ── /api/updates/status ──────────────────────────────────────────────────

describe("GET /api/updates/status", () => {
  it("matches the ACTUAL wire shape — RepoUpdatesStatusResponse, not the unused legacy UpdateStatusPayload", async () => {
    // types.ts documents two shapes: the pre-fork Node dashboard's git-based
    // `UpdateStatusPayload` (unused since the standalone app checks GitHub
    // releases instead — see types.ts's own comment on RepoUpdatesStatusResponse)
    // and `RepoUpdatesStatusResponse`, which is what server/lib/update-check.js
    // (ported from Sources/PodiumCore/Discovery/UpdateCheck.swift, ROADMAP
    // P2/P7) actually returns. Assert the real shape.
    const e = "/api/updates/status";
    const json = await get(e);
    assertField(json, "git_repo", ["bool"], e);
    assertField(json, "update_available", ["bool"], e);
    assertField(json, "current_sha", ["string"], e);
    assertField(json, "latest_sha", ["string"], e);
    assertField(json, "checked_at", ["string"], e);
    assert.ok(json.app, `${e}: missing 'app'`);
    assertField(json.app, "repo", ["string"], e);
    assertField(json.app, "checked", ["bool"], e);
    assertField(json.app, "update_available", ["bool"], e);
    // PODIUM_APP_GITHUB_REPO=unconfigured (no slash) forces the offline
    // branch — deterministic, no live network call in this suite.
    assert.equal(json.app.checked, false);
    assert.equal(json.update_available, false);
  });
});

// ── /api/export + /api/import round trip ─────────────────────────────────

describe("GET /api/export/session/:id + POST /api/import/session round trip", () => {
  it("bundle matches export.js's EXPORT_VERSION shape and round-trips through import", async () => {
    // The Swift suite posted the bundle back to "/api/export/session" — on
    // Node the round-trip endpoint is actually POST /api/import/session
    // (routes/import.js); export.js only ever served the GET side (ROADMAP
    // N3 — ported independently from the plugin-era reference server). This
    // asserts upstream's actual round-trip path, not the Swift server's.
    const e = "/api/export/session/:id";
    const bundle = await get(`/api/export/session/${sessionA}`);
    snake(bundle, "podium_export_version", ["string"], e);
    snake(bundle, "exported_at", ["string"], e);
    assertField(bundle, "session", ["object"], e);
    assertField(bundle, "agents", ["array"], e);
    assertField(bundle, "events", ["array"], e);
    snake(bundle, "token_usage", ["array"], e);
    assert.equal(bundle.podium_export_version, "1.0");
    assertSessionShape(bundle.session, e);

    const { status, json: importResult } = await request("POST", "/api/import/session", bundle);
    assert.equal(status, 200, "POST /api/import/session round trip");
    snake(importResult, "session_id", ["string"], "POST /api/import/session");
    assert.equal(importResult.session_id, sessionA);
  });
});
