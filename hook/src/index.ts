// podium-hook — hook client for Claude Code (N5-B).
//
// Port of Sources/PodiumHook/main.swift + Sources/PodiumCore/Hooks/HookClient.swift
// (themselves ports of the plugin-era hook.mjs). Reads the hook event JSON on
// stdin, discovers every live Podium dashboard server, and POSTs
// `{hook_type, data}` to /api/hooks/event on each one.
//
// Invariants (same as the Swift binary):
//   - ALWAYS exits 0, whatever happens — the hook must never fail or block
//     a Claude Code session.
//   - Hard 1.5s process deadline (Claude Code kills hooks after 2s).
//   - Per-request timeout: 1s.
//   - Port discovery: CLAUDE_DASHBOARD_PORT env var wins outright; else
//     ~/.claude/.agent-dashboard.json (multi-server `{servers:[{port,pid}]}`
//     or legacy single `{port,pid}`), filtered to live pids via kill(pid, 0)
//     (EPERM counts as alive); else fallback [4820].
//
// Compiled to a single-file binary with `bun build --compile` and installed
// by the server-side installer module (N5-A scope — not here).

import { readFileSync } from "node:fs";
import { homedir } from "node:os";

interface DashboardServerEntry {
  port: number;
  pid: number | null;
}

const FALLBACK_PORTS = [4820];
const REQUEST_TIMEOUT_MS = 1000;
const PROCESS_DEADLINE_MS = 1500;

// Superset of the hook types install-hooks.js registers (HOOK_TYPES):
// routes/hooks.js depends on Stop (waiting badge) and Notification
// (blocked-waiting detection + watchdog) — dropping them here silently
// breaks those features even though the hooks fire.
const HANDLED_EVENTS = new Set([
  "SessionStart",
  "UserPromptSubmit",
  "PreToolUse",
  "PostToolUse",
  "PostToolUseFailure",
  "Stop",
  "SubagentStart",
  "SubagentStop",
  "SessionEnd",
  "Notification",
]);

function homeDirectory(): string {
  const home = process.env.HOME;
  if (home && home.length > 0) return home;
  // Same spirit as FileManager.homeDirectoryForCurrentUser; os.homedir()
  // consults the passwd db when HOME is unset.
  return homedir();
}

function defaultInfoPath(): string {
  return `${homeDirectory()}/.claude/.agent-dashboard.json`;
}

// True if the process is alive (or we can't tell — EPERM counts as alive,
// mirroring hook.mjs's `e.code === 'EPERM'` check).
function isProcessAlive(pid: number): boolean {
  if (pid <= 0) return true;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e: unknown) {
    return (e as NodeJS.ErrnoException)?.code === "EPERM";
  }
}

function intValue(v: unknown): number | null {
  if (typeof v === "number" && Number.isFinite(v) && Number.isInteger(v)) return v;
  return null;
}

// Parse .agent-dashboard.json — multi-server or legacy single format.
// Returns [] on malformed JSON or unknown shape.
function parseServerEntries(raw: string): DashboardServerEntry[] {
  let obj: unknown;
  try {
    obj = JSON.parse(raw);
  } catch {
    return [];
  }
  if (typeof obj !== "object" || obj === null || Array.isArray(obj)) return [];
  const o = obj as Record<string, unknown>;

  if (Array.isArray(o.servers)) {
    const out: DashboardServerEntry[] = [];
    for (const el of o.servers) {
      if (typeof el !== "object" || el === null) continue;
      const d = el as Record<string, unknown>;
      const port = intValue(d.port);
      if (port === null) continue;
      out.push({ port, pid: intValue(d.pid) });
    }
    return out;
  }

  const port = intValue(o.port);
  if (port !== null) return [{ port, pid: intValue(o.pid) }];
  return [];
}

function liveEntries(entries: DashboardServerEntry[]): DashboardServerEntry[] {
  return entries.filter((e) => {
    if (e.pid === null || e.pid <= 0) return true;
    return isProcessAlive(e.pid);
  });
}

// Full port discovery: env override → info file (live entries) → fallback.
// De-duplicates ports preserving order ([...new Set(...)] in hook.mjs).
function resolvePorts(): number[] {
  const envRaw = process.env.CLAUDE_DASHBOARD_PORT;
  if (envRaw !== undefined) {
    const envPort = parseInt(envRaw.trim(), 10);
    if (Number.isFinite(envPort) && envPort > 0) return [envPort];
  }

  let raw: string;
  try {
    raw = readFileSync(defaultInfoPath(), "utf8");
  } catch {
    return FALLBACK_PORTS;
  }

  const live = liveEntries(parseServerEntries(raw));
  if (live.length === 0) return FALLBACK_PORTS;
  return [...new Set(live.map((e) => e.port))];
}

// Port of hook.mjs's run() gate: post only for handled events with a
// non-empty session_id. `data` is the raw parsed payload, posted verbatim.
function buildEvent(payload: unknown): { hookType: string; data: object } | null {
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)) return null;
  const p = payload as Record<string, unknown>;
  const name = p.hook_event_name;
  if (typeof name !== "string" || name.length === 0) return null;
  const sid = p.session_id;
  if (sid === null || sid === undefined || (typeof sid === "string" && sid.length === 0)) return null;
  if (!HANDLED_EVENTS.has(name)) return null;
  return { hookType: name, data: p };
}

async function postToPort(port: number, body: string): Promise<void> {
  try {
    await fetch(`http://127.0.0.1:${port}/api/hooks/event`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  } catch {
    // Errors, refusals, and timeouts are all fine — never block the session.
  }
}

async function readStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString("utf8");
}

async function main(): Promise<void> {
  const input = await readStdin();

  let payload: unknown;
  try {
    payload = JSON.parse(input);
  } catch {
    process.exit(0);
  }

  const event = buildEvent(payload);
  if (!event) process.exit(0);

  let body: string;
  try {
    body = JSON.stringify({ hook_type: event.hookType, data: event.data });
  } catch {
    process.exit(0);
  }

  const ports = resolvePorts();
  await Promise.allSettled(ports.map((port) => postToPort(port, body)));
  process.exit(0);
}

// Hard safety net: whatever happens, this process must not outlive 1.5s.
// unref() so the timer itself never keeps the process alive.
setTimeout(() => process.exit(0), PROCESS_DEADLINE_MS).unref();

main().catch(() => process.exit(0));
