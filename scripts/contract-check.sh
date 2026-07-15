#!/bin/bash
# Out-of-process smoke complement to server/tests/contract/contract.test.js.
#
# The contract test suite boots server/index.js IN-PROCESS (child_process,
# same source tree) and asserts against raw JSON via node:test. This script
# instead boots the REAL server entrypoint (or the bun-compiled sidecar, if
# staged) as a separate process, seeds it through the same recorded-style
# hook sequence, and curls every GET endpoint the client covers — a coarser
# but more "real world" check that the shipped server, not just the test
# target, honors the wire contract.
#
# Usage:
#   scripts/contract-check.sh
#
# Exit code: 0 on PASS, non-zero on any failure (boot, seed, or assertion).
# Never touches ~/.claude or ~/.claude/podium/data — CLAUDE_HOME,
# DASHBOARD_DATA_DIR, and HOME are all redirected to a throwaway mktemp dir
# for the lifetime of the server process.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

# Prefer a bun-compiled sidecar if one is already staged (tauri/prepare-
# sidecar.sh output); otherwise fall back to running the source entrypoint
# directly with node — no build step needed for this smoke check.
SIDECAR_GLOB=("$SCRIPT_DIR"/tauri/src-tauri/bin/podium-server-*)
BIN_PATH=""
if [ -x "${SIDECAR_GLOB[0]:-}" ]; then
  BIN_PATH="${SIDECAR_GLOB[0]}"
  echo "▶ Using staged sidecar binary: $BIN_PATH"
else
  echo "▶ No staged sidecar binary found — running server/index.js with node"
fi

PASS_COUNT=0
FAIL_COUNT=0
FAILURES=()

# ---------------------------------------------------------------------------
# Step 2: boot on a random high port, fully isolated fixture dir
# ---------------------------------------------------------------------------

FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/podium-contract-check.XXXXXX")"
CLAUDE_HOME_DIR="$FIXTURE_DIR/claude-home"
DATA_DIR="$FIXTURE_DIR/data"
SERVER_LOG="$FIXTURE_DIR/server.log"
mkdir -p "$CLAUDE_HOME_DIR" "$DATA_DIR"

# Minimal CLAUDE_HOME fixture (mirrors ContractTests.seedClaudeHomeFixture):
# one user skill, one user agent, a settings.json with a hook + an MCP
# server — this feeds the /api/cc-config/* casing checks below.
mkdir -p "$CLAUDE_HOME_DIR/skills/demo-skill" "$CLAUDE_HOME_DIR/agents"
printf -- '---\ndescription: Demo skill\n---\nDemo body.\n' > "$CLAUDE_HOME_DIR/skills/demo-skill/SKILL.md"
printf -- '---\ndescription: Reviews code\n---\nReviewer body.\n' > "$CLAUDE_HOME_DIR/agents/reviewer.md"
cat > "$CLAUDE_HOME_DIR/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "echo hi", "timeout": 5}]}
    ]
  },
  "mcpServers": {
    "demo-mcp": {"command": "npx", "args": ["demo-server"]}
  }
}
JSON

# NEVER the real ~/.claude — ClaudeHome.current() defaults there; CLAUDE_HOME
# is the override. HOME is also redirected because cc-config reads
# ~/.claude.json (project-scoped MCP) via the real HOME, not CLAUDE_HOME.
export CLAUDE_HOME="$CLAUDE_HOME_DIR"
export DASHBOARD_DATA_DIR="$DATA_DIR"
export HOME="$FIXTURE_DIR"

SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT

# Portable random high port (works without external tools on macOS + Linux).
PORT=$(( (RANDOM % 10000) + 30000 ))

echo "▶ Booting podium-server on port $PORT (CLAUDE_HOME=$CLAUDE_HOME_DIR, HOME=$FIXTURE_DIR)…"
if [ -n "$BIN_PATH" ]; then
  "$BIN_PATH" --port "$PORT" --data-dir "$DATA_DIR" >"$SERVER_LOG" 2>&1 &
else
  node "$SCRIPT_DIR/server/index.js" --port "$PORT" --data-dir "$DATA_DIR" >"$SERVER_LOG" 2>&1 &
fi
SERVER_PID=$!

BASE_URL="http://127.0.0.1:$PORT"

# ---------------------------------------------------------------------------
# Step 3: wait for /api/health, bounded ~15s
# ---------------------------------------------------------------------------

echo "▶ Waiting for /api/health…"
HEALTHY=0
for _ in $(seq 1 150); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "✗ Server process died while waiting for health. Log tail:"
    tail -n 50 "$SERVER_LOG" || true
    exit 1
  fi
  if curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/api/health" 2>/dev/null | grep -q "^200$"; then
    HEALTHY=1
    break
  fi
  sleep 0.1
done

if [ "$HEALTHY" -ne 1 ]; then
  echo "✗ Server did not become healthy within ~15s. Log tail:"
  tail -n 50 "$SERVER_LOG" || true
  exit 1
fi
echo "  ✓ healthy"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

post_hook() {
  # $1 = hook_type, $2 = data JSON object (already valid JSON)
  local hook_type="$1"
  local data_json="$2"
  local body
  body=$(jq -nc --arg ht "$hook_type" --argjson data "$data_json" '{hook_type: $ht, data: $data}')
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/api/hooks/event" \
    -H "Content-Type: application/json" -d "$body")
  if [ "$code" != "200" ]; then
    echo "✗ FAIL: POST /api/hooks/event ($hook_type) returned $code"
    exit 1
  fi
}

check() {
  # check <description> <endpoint-path> <jq-filter-expected-truthy>
  local desc="$1"
  local path="$2"
  local jq_filter="$3"
  local body
  local code
  local tmp_resp
  tmp_resp="$FIXTURE_DIR/resp.json"

  code=$(curl -s -o "$tmp_resp" -w "%{http_code}" "$BASE_URL$path")
  body=$(cat "$tmp_resp")

  if [ "$code" != "200" ]; then
    echo "✗ FAIL [$desc] GET $path -> HTTP $code"
    echo "  body: $body"
    FAILURES+=("$desc (HTTP $code)")
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return
  fi

  if ! echo "$body" | jq -e "$jq_filter" >/dev/null 2>&1; then
    echo "✗ FAIL [$desc] GET $path -> jq check '$jq_filter' failed"
    echo "  body: $body"
    FAILURES+=("$desc (jq check failed: $jq_filter)")
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return
  fi

  echo "  ✓ $desc"
  PASS_COUNT=$((PASS_COUNT + 1))
}

# ---------------------------------------------------------------------------
# Step 4: seed via POST /api/hooks/event (mirrors ContractTests.seedViaHooks)
# ---------------------------------------------------------------------------

echo "▶ Seeding via /api/hooks/event…"

SESSION_A="sess-contract-a"
SESSION_B="sess-contract-b"
CWD_A="/tmp/contract-proj-a"
CWD_B="/tmp/contract-proj-b"
TRANSCRIPT_PATH_A="$FIXTURE_DIR/transcript-a.jsonl"

# Minimal transcript so token extraction has something to chew on (not a full
# replica of ContractTests' fixture — this script's goal is wire-shape smoke,
# not transcript-parsing depth, which the in-process suite already covers).
mkdir -p "$(dirname "$TRANSCRIPT_PATH_A")"
{
  printf '{"type":"user","timestamp":"2026-07-03T10:00:00.000Z","message":{"content":"Fix the flaky test"}}\n'
  printf '{"type":"assistant","timestamp":"2026-07-03T10:00:05.000Z","message":{"model":"claude-sonnet-4-5","content":[{"type":"text","text":"Looking at it."},{"type":"tool_use","id":"tu_1","name":"Read","input":{"file_path":"/tmp/test.swift"}}],"usage":{"input_tokens":500,"output_tokens":80,"cache_read_input_tokens":10,"cache_creation_input_tokens":5}}}\n'
  printf '{"type":"user","timestamp":"2026-07-03T10:00:06.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","content":"file contents","is_error":false}]}}\n'
} > "$TRANSCRIPT_PATH_A"

post_hook "SessionStart" "$(jq -nc --arg sid "$SESSION_A" --arg cwd "$CWD_A" --arg tp "$TRANSCRIPT_PATH_A" \
  '{session_id: $sid, cwd: $cwd, model: "claude-sonnet-4-5", transcript_path: $tp}')"

post_hook "UserPromptSubmit" "$(jq -nc --arg sid "$SESSION_A" --arg tp "$TRANSCRIPT_PATH_A" \
  '{session_id: $sid, prompt: "Fix the flaky test", transcript_path: $tp}')"

post_hook "PreToolUse" "$(jq -nc --arg sid "$SESSION_A" --arg tp "$TRANSCRIPT_PATH_A" \
  '{session_id: $sid, tool_name: "Bash", tool_input: {command: "swift test"}, tool_use_id: "tu-bash-1", transcript_path: $tp}')"

post_hook "PostToolUse" "$(jq -nc --arg sid "$SESSION_A" --arg tp "$TRANSCRIPT_PATH_A" \
  '{session_id: $sid, tool_name: "Bash", tool_input: {command: "swift test"}, tool_response: "All tests passed", tool_use_id: "tu-bash-1", transcript_path: $tp}')"

post_hook "PreToolUse" "$(jq -nc --arg sid "$SESSION_A" --arg tp "$TRANSCRIPT_PATH_A" \
  '{session_id: $sid, tool_name: "Agent", tool_input: {description: "Investigate flaky test", subagent_type: "general-purpose", prompt: "Investigate the flaky test root cause"}, tool_use_id: "tu-agent-1", transcript_path: $tp}')"

post_hook "SubagentStop" "$(jq -nc --arg sid "$SESSION_A" --arg tp "$TRANSCRIPT_PATH_A" \
  '{session_id: $sid, agent_type: "general-purpose", description: "Investigate flaky test", transcript_path: $tp}')"

post_hook "Stop" "$(jq -nc --arg sid "$SESSION_A" --arg tp "$TRANSCRIPT_PATH_A" '{session_id: $sid, transcript_path: $tp}')"

post_hook "SessionEnd" "$(jq -nc --arg sid "$SESSION_A" --arg tp "$TRANSCRIPT_PATH_A" '{session_id: $sid, transcript_path: $tp}')"

# Second session, left active mid-tool-use.
post_hook "SessionStart" "$(jq -nc --arg sid "$SESSION_B" --arg cwd "$CWD_B" '{session_id: $sid, cwd: $cwd}')"

post_hook "PreToolUse" "$(jq -nc --arg sid "$SESSION_B" \
  '{session_id: $sid, tool_name: "Read", tool_input: {file_path: "/tmp/x"}}')"

echo "  ✓ seeded (session A completed, session B active)"

# ---------------------------------------------------------------------------
# Step 5: GET every endpoint + casing-sensitive spot checks
# ---------------------------------------------------------------------------

echo "▶ Checking endpoints…"

check "health" "/api/health" '.status and .timestamp'
check "stats (snake_case)" "/api/stats?tz_offset=0" '.total_sessions != null and (.totalSessions == null)'
check "sessions list (snake_case started_at)" "/api/sessions?limit=10" '.sessions[0].started_at != null and (.sessions[0].startedAt == null)'
check "sessions facets" "/api/sessions/facets" '.cwds != null'
check "session detail" "/api/sessions/$SESSION_A" '.session.started_at != null and .session.status == "completed"'
check "session stats" "/api/sessions/$SESSION_A/stats" '.session_id != null and .tokens.input_tokens != null'
check "session transcripts list" "/api/sessions/$SESSION_A/transcripts" '.transcripts != null'
check "session transcript" "/api/sessions/$SESSION_A/transcript" '.messages != null and (.has_more != null)'
check "agents list" "/api/agents?session_id=$SESSION_A" '.agents[0].session_id != null'
# "agent detail" (GET /api/agents/:id) removed in the pre-1.0 B6 API trim —
# no client caller; kept dormant upstream per P6 (see routes/agents.js).
check "events list" "/api/events?session_id=$SESSION_A&limit=50" '.events[0].session_id != null'
check "events facets" "/api/events/facets" '(.event_types // []) | index("SessionStart") != null'
check "analytics" "/api/analytics?tz_offset=0" '.tokens.total_input != null and .overview.total_sessions != null'
check "search" "/api/search?q=flaky&limit=20&offset=0" '.results != null and (.results | length) > 0'
check "pricing list" "/api/pricing" '.pricing[0].model_pattern != null'
check "pricing cost" "/api/pricing/cost?tz_offset=0" '.total_cost != null and .breakdown != null'
check "pricing cost per session" "/api/pricing/cost/$SESSION_A?tz_offset=0" '.total_cost != null'
check "settings info (transcript_cache.maxSize)" "/api/settings/info" '.transcript_cache.maxSize != null and (.transcriptCache == null)'
check "workflows aggregate (camelCase stats, no snake twin)" "/api/workflows" '.stats.totalSessions != null and (.stats.total_sessions == null)'
check "workflows session drill-in" "/api/workflows/session/$SESSION_A" '.swimLanes != null and .tree != null'
check "run history" "/api/run/history?limit=50" '.items != null'
check "run cwds" "/api/run/cwds" '.items != null'
check "run/binary (has key path, value may be null)" "/api/run/binary" 'has("path")'
check "push vapid public key" "/api/push/vapid-public-key" '.publicKey != null and (.publicKey | length) > 0'
check "import guide" "/api/import/guide" '.default_projects_dir != null'
check "cc-config overview" "/api/cc-config/overview" '.roots.claudeHome != null'
check "cc-config skills" "/api/cc-config/skills?scope=user" '.items[0].name == "demo-skill"'
check "cc-config agents" "/api/cc-config/agents?scope=user" '.items[0].name == "reviewer"'
check "cc-config mcp (camelCase projectScoped)" "/api/cc-config/mcp" '.projectScoped != null'
check "updates status (git_repo present)" "/api/updates/status" 'has("git_repo")'
# "diagnostics" (GET /api/diagnostics) removed in the pre-1.0 B6 API trim —
# no client/skill caller (the /podium skill uses /api/health + /api/stats).
check "export session bundle" "/api/export/session/$SESSION_A" '.podium_export_version == "1.0"'

# ---------------------------------------------------------------------------
# Step 6: PASS/FAIL summary (cleanup runs via trap EXIT)
# ---------------------------------------------------------------------------

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo ""
echo "─────────────────────────────────────────"
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "PASS — $PASS_COUNT/$TOTAL endpoint checks passed"
  echo "─────────────────────────────────────────"
  exit 0
else
  echo "FAIL — $PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  echo "─────────────────────────────────────────"
  exit 1
fi
