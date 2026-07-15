/**
 * @file types.ts
 * @description Defines TypeScript types and interfaces for the agent dashboard application, including data structures for sessions, agents, events, statistics, analytics, model pricing, cost breakdowns, WebSocket messages, and workflow-related data. These types provide a clear contract for the shape of data used throughout the application and facilitate type safety when interacting with the backend API and managing state within the frontend components.
 * @author Gael Robin <robin.gael@gmail.com>
 */

export type SessionStatus = "active" | "completed" | "error" | "abandoned";
export type AgentStatus = "working" | "waiting" | "completed" | "error";
export type AgentType = "main" | "subagent";

/**
 * UI-only status that overlays the persisted SessionStatus/AgentStatus when
 * `awaiting_input_since` is set on a session or agent. Renders as a yellow
 * "Waiting" badge so the dashboard can flag sessions blocked on a Claude Code
 * permission prompt without changing the underlying lifecycle enum.
 */
export const AWAITING_STATUS = "waiting" as const;
export type EffectiveAgentStatus = AgentStatus | typeof AWAITING_STATUS;
export type EffectiveSessionStatus = SessionStatus | typeof AWAITING_STATUS;

export interface Session {
  id: string;
  name: string | null;
  status: SessionStatus;
  cwd: string | null;
  model: string | null;
  started_at: string;
  ended_at: string | null;
  metadata: string | null;
  agent_count?: number;
  last_activity?: string;
  cost?: number;
  /** ISO timestamp set when Claude Code is blocked waiting for the user
   * (permission prompt or "waiting for your input" notice). Cleared on the
   * next non-Notification hook event. Null when the session is not waiting. */
  awaiting_input_since?: string | null;
}

export interface Agent {
  id: string;
  session_id: string;
  name: string;
  type: AgentType;
  subagent_type: string | null;
  status: AgentStatus;
  task: string | null;
  current_tool: string | null;
  started_at: string;
  ended_at: string | null;
  updated_at: string;
  parent_agent_id: string | null;
  metadata: string | null;
  /** Mirrors the parent session: ISO timestamp when set, null otherwise. */
  awaiting_input_since?: string | null;
}

/** True when a session is paused on a permission prompt or input request. */
export function isSessionAwaitingInput(session: Session | undefined | null): boolean {
  return !!session?.awaiting_input_since && session.status === "active";
}

/** True when an agent is the one blocked on user input (typically a main agent). */
export function isAgentAwaitingInput(agent: Agent | undefined | null): boolean {
  if (!agent?.awaiting_input_since) return false;
  // Once the agent's lifecycle has ended, the waiting flag is stale; ignore it.
  return agent.status !== "completed" && agent.status !== "error";
}

export function effectiveAgentStatus(agent: Agent): EffectiveAgentStatus {
  return isAgentAwaitingInput(agent) ? AWAITING_STATUS : agent.status;
}

export function effectiveSessionStatus(session: Session): EffectiveSessionStatus {
  return isSessionAwaitingInput(session) ? AWAITING_STATUS : session.status;
}

export interface DashboardEvent {
  id: number;
  session_id: string;
  agent_id: string | null;
  event_type: string;
  tool_name: string | null;
  summary: string | null;
  data: string | null;
  created_at: string;
}

export interface Stats {
  total_sessions: number;
  active_sessions: number;
  active_agents: number;
  total_agents: number;
  total_events: number;
  events_today: number;
  ws_connections: number;
  agents_by_status: Record<string, number>;
  sessions_by_status: Record<string, number>;
}

export interface Analytics {
  tokens: {
    total_input: number;
    total_output: number;
    total_cache_read: number;
    total_cache_write: number;
  };
  tool_usage: Array<{ tool_name: string; count: number }>;
  daily_events: Array<{ date: string; count: number }>;
  daily_sessions: Array<{ date: string; count: number }>;
  agent_types: Array<{ subagent_type: string; count: number }>;
  event_types: Array<{ event_type: string; count: number }>;
  avg_events_per_session: number;
  total_subagents: number;
  overview: {
    total_sessions: number;
    active_sessions: number;
    active_agents: number;
    total_agents: number;
    total_events: number;
  };
  agents_by_status: Record<string, number>;
  sessions_by_status: Record<string, number>;
}

export interface ModelPricing {
  model_pattern: string;
  display_name: string;
  input_per_mtok: number;
  output_per_mtok: number;
  cache_read_per_mtok: number;
  cache_write_per_mtok: number;
  updated_at: string;
}

export interface CostBreakdown {
  model: string;
  input_tokens: number;
  output_tokens: number;
  cache_read_tokens: number;
  cache_write_tokens: number;
  cost: number;
  matched_rule: string | null;
}

export interface CostResult {
  total_cost: number;
  breakdown: CostBreakdown[];
  daily_costs: Array<{ date: string; cost: number }>;
}

/**
 * Matches the actual server broadcast in `ImportRouter.swift` — only ever
 * `"complete"` (with `counters`) or `"error"` (with `error`). No granular
 * scan/extract/parse phases are sent; don't reintroduce client copy for them.
 */
export interface ImportProgressMessage {
  importId?: string;
  phase: "complete" | "error";
  source?: "default" | "path" | "upload";
  path?: string;
  error?: string;
  counters?: Record<string, number>;
}

/**
 * One repo's update status — `RepoUpdateStatus` in
 * `Sources/PodiumCore/Discovery/UpdateCheck.swift`. Nested under `app` in
 * `RepoUpdatesStatusResponse`.
 */
export interface RepoUpdateStatus {
  repo: string;
  checked: boolean;
  current_version?: string | null;
  latest_version?: string | null;
  update_available: boolean;
  release_url?: string | null;
  published_at?: string | null;
  error?: string | null;
  /** Markdown release notes (GitHub release `body`). */
  release_notes?: string | null;
}

/**
 * Actual GET /api/updates/status response shape — `UpdatesStatusResponse` in
 * `Sources/PodiumCore/Discovery/UpdateCheck.swift`. This is the real,
 * currently-shipping wire shape (as opposed to `UpdateStatusPayload` below,
 * which mirrors the pre-fork Node dashboard's git-based `update_status` WS
 * payload and is unused since the standalone app checks GitHub releases
 * instead of a git remote).
 */
export interface RepoUpdatesStatusResponse {
  git_repo: boolean;
  update_available: boolean;
  current_sha: string;
  latest_sha: string;
  app: RepoUpdateStatus;
  checked_at: string;
}

/** Payload for `update_status` WebSocket messages and GET /api/updates/status */
export interface UpdateStatusPayload {
  git_repo: boolean;
  update_available: boolean;
  repo_root?: string;
  remote_ref?: string | null;
  /** Remote name we compared against — "upstream" if configured (fork
   * convention), else "origin", else whatever single remote is set up. */
  canonical_remote?: string | null;
  /** Local branch HEAD points at. null on detached HEAD. */
  current_branch?: string | null;
  /** What the local branch tracks (e.g. "origin/feature/foo"). null when
   * no upstream is configured for the current branch. */
  tracking_upstream?: string | null;
  /** True when the local branch's tracked upstream is exactly remote_ref
   * — i.e. a plain `git pull --ff-only` will do the right thing. */
  tracks_canonical?: boolean;
  /** Categorical hint for the UI. Discriminated so callers can branch on
   * shape (e.g. show "Restart after running" only when the command
   * actually rewrites the working tree). */
  situation?:
    | "tracking_canonical"
    | "fork_or_diverged_tracking"
    | "feature_branch"
    | "detached_head";
  /** Plain-language explanation when the user is *not* on the canonical
   * default branch, so the manual command makes sense in context. */
  situation_note?: string | null;
  local_sha?: string | null;
  remote_sha?: string | null;
  commits_behind?: number;
  manual_command?: string | null;
  message?: string | null;
  fetch_error?: string;
}

export interface RunStreamPayload {
  id: string;
  envelope: unknown;
}
export interface RunStatusPayload {
  id: string;
  status: "spawning" | "running" | "completed" | "error" | "killed";
  at: number;
  exitCode?: number;
  sessionId?: string | null;
  error?: string;
}
export interface RunInputAckPayload {
  id: string;
  messageId: string;
  at: number;
}

export interface CcConfigChangedPayload {
  source: "dashboard" | "fs";
  action?: "write" | "delete";
  scope?: "user" | "project";
  type?: string;
  name?: string | null;
  paths?: string[];
}

export interface WSMessage {
  type:
    | "session_created"
    | "session_updated"
    | "agent_created"
    | "agent_updated"
    | "new_event"
    | "import.progress"
    | "update_status"
    | "run_stream"
    | "run_status"
    | "run_input_ack"
    | "cc_config_changed"
    | "alert_triggered"
    | "alert_updated"
    | "workflow_upserted";
  data:
    | Session
    | Agent
    | DashboardEvent
    | ImportProgressMessage
    | UpdateStatusPayload
    | RunStreamPayload
    | RunStatusPayload
    | RunInputAckPayload
    | CcConfigChangedPayload
    | AlertEvent
    | WorkflowRun;
  timestamp: string;
}

// ── Alerts ──
// Rules-based alerting. Mirrors server/routes/alerts.js + server/lib/alerts.js.
// AlertRule.config is deserialized server-side; AlertEvent.details stays an
// opaque JSON string (parse before use).

/** Kind of condition an alert rule evaluates. event_pattern + token_threshold
 * run on every hook ingest; inactivity + status_duration run on a periodic
 * server sweep. */
export type AlertRuleType = "event_pattern" | "inactivity" | "status_duration" | "token_threshold";

/** Rule-type-specific settings. Which fields apply depends on `rule_type`
 * (validated by `validateRuleConfig` in server/lib/alerts.js). */
export interface AlertRuleConfig {
  event_type?: string;
  tool_name?: string;
  summary_contains?: string;
  count?: number;
  window_minutes?: number;
  minutes?: number;
  status?: "working" | "waiting";
  total_tokens?: number;
}

/** A user-defined alert rule (GET/POST/PATCH /api/alerts/rules). */
export interface AlertRule {
  id: string;
  name: string;
  rule_type: AlertRuleType;
  config: AlertRuleConfig;
  enabled: boolean;
  cooldown_seconds: number;
  created_at: string;
  updated_at: string;
}

/** One firing of a rule (GET /api/alerts); pushed live via alert_triggered
 * (new) / alert_updated (acknowledged) WS messages. */
export interface AlertEvent {
  id: number;
  rule_id: string;
  rule_name: string;
  rule_type: AlertRuleType;
  session_id: string | null;
  agent_id: string | null;
  message: string;
  /** Opaque JSON string with extra context; may be null. */
  details: string | null;
  triggered_at: string;
  acknowledged_at: string | null;
}

// ── Webhooks ──
// Outbound delivery of alerts to chat/incident/automation providers. Mirrors
// server/routes/webhooks.js + server/lib/webhook-providers.js. Secrets are
// always masked on the wire (url_preview, headers, secret config fields).

export type WebhookType =
  | "slack"
  | "discord"
  | "teams"
  | "google_chat"
  | "mattermost"
  | "rocketchat"
  | "telegram"
  | "pagerduty"
  | "opsgenie"
  | "splunk_oncall"
  | "zapier"
  | "make"
  | "n8n"
  | "pipedream"
  | "generic";

/** One provider-specific config field the "Add webhook" form renders. */
export interface WebhookProviderField {
  key: string;
  label: string;
  secret: boolean;
  required: boolean;
  type: "string" | "enum";
  options: string[] | null;
  default: string | null;
}

/** Redacted provider metadata (GET /api/webhooks/providers) driving the form. */
export interface WebhookProvider {
  type: WebhookType;
  label: string;
  family: "chat" | "api" | "generic";
  url_required: boolean;
  has_default_url: boolean;
  derives_url: boolean;
  allow_http: boolean;
  url_hint: string | null;
  supports_secret: boolean;
  supports_headers: boolean;
  fields: WebhookProviderField[];
}

/** Compact summary of a target's most recent delivery attempt. */
export interface WebhookDeliverySummary {
  status: "success" | "failed";
  status_code: number | null;
  attempts: number;
  error: string | null;
  created_at: string;
}

/** A configured outbound webhook destination (GET/POST/PATCH /api/webhooks). */
export interface WebhookTarget {
  id: string;
  name: string;
  type: WebhookType;
  enabled: boolean;
  /** Masked host + last 4 chars; the full URL is never returned. */
  url_preview: string;
  has_secret: boolean;
  /** Generic targets only; values masked ("••••"). */
  headers: Record<string, string> | null;
  /** Provider config; secret values masked. */
  config: Record<string, string> | null;
  /** Rule ids this target is scoped to; null = all rules. */
  rule_ids: string[] | null;
  created_at: string;
  updated_at: string;
  last_delivery: WebhookDeliverySummary | null;
}

/** One row of a target's delivery log (GET /api/webhooks/:id/deliveries). */
export interface WebhookDelivery {
  id: number;
  target_id: string;
  target_name: string;
  target_type: WebhookType;
  alert_id: number | null;
  status: "success" | "failed";
  status_code: number | null;
  attempts: number;
  error: string | null;
  created_at: string;
}

/** Result of POST /api/webhooks/:id/test — a synchronous one-shot probe. */
export interface WebhookTestResult {
  ok: boolean;
  status: number | null;
  attempts: number;
  error: string | null;
}

// ── Session stats ──

export interface SessionStats {
  session_id: string;
  total_events: number;
  events_by_type: Array<{ event_type: string; count: number }>;
  tools_used: Array<{ tool_name: string; count: number }>;
  error_count: number;
  first_event_at: string | null;
  last_event_at: string | null;
  agents: {
    total: number;
    main: number;
    subagent: number;
    compaction: number;
    by_status: Record<string, number>;
  };
  subagent_types: Array<{ subagent_type: string; count: number }>;
  tokens: {
    input_tokens: number;
    output_tokens: number;
    cache_read_tokens: number;
    cache_write_tokens: number;
  };
}

// ── Workflow types ──

export interface WorkflowStats {
  totalSessions: number;
  totalAgents: number;
  totalSubagents: number;
  avgSubagents: number;
  successRate: number;
  avgDepth: number;
  avgDurationSec: number;
  totalCompactions: number;
  avgCompactions: number;
  topFlow: { source: string; target: string; count: number } | null;
}

export interface OrchestrationEdge {
  source: string;
  target: string;
  weight: number;
}

export interface OrchestrationData {
  sessionCount: number;
  mainCount: number;
  subagentTypes: Array<{ subagent_type: string; count: number; completed: number; errors: number }>;
  edges: OrchestrationEdge[];
  outcomes: Array<{ status: string; count: number }>;
  compactions: { total: number; sessions: number };
}

export interface ToolFlowTransition {
  source: string;
  target: string;
  value: number;
}

export interface ToolFlowData {
  transitions: ToolFlowTransition[];
  toolCounts: Array<{ tool_name: string; count: number }>;
}

export interface SubagentEffectivenessItem {
  subagent_type: string;
  total: number;
  completed: number;
  errors: number;
  sessions: number;
  successRate: number;
  avgDuration: number | null;
  trend: number[];
}

export interface WorkflowPattern {
  steps: string[];
  count: number;
  percentage: number;
}

export interface WorkflowPatternsData {
  patterns: WorkflowPattern[];
  soloSessionCount: number;
  soloPercentage: number;
}

export interface ModelDelegationData {
  mainModels: Array<{ model: string; agent_count: number; session_count: number }>;
  subagentModels: Array<{ model: string; agent_count: number }>;
  tokensByModel: Array<{
    model: string;
    input_tokens: number;
    output_tokens: number;
    cache_read_tokens: number;
    cache_write_tokens: number;
  }>;
}

export interface ErrorPropagationData {
  byDepth: Array<{ depth: number; count: number }>;
  byType: Array<{ subagent_type: string; count: number }>;
  eventErrors: Array<{ summary: string; count: number }>;
  sessionsWithErrors: number;
  totalSessions: number;
  errorRate: number;
}

export interface ConcurrencyLane {
  name: string;
  avgStart: number;
  avgEnd: number;
  count: number;
}

export interface ConcurrencyData {
  aggregateLanes: ConcurrencyLane[];
}

export interface SessionComplexityItem {
  id: string;
  name: string | null;
  status: string;
  duration: number;
  agentCount: number;
  subagentCount: number;
  totalTokens: number;
  model: string | null;
}

export interface CompactionImpactData {
  totalCompactions: number;
  tokensRecovered: number;
  perSession: Array<{ session_id: string; compactions: number }>;
  sessionsWithCompactions: number;
  totalSessions: number;
}

export interface WorkflowData {
  stats: WorkflowStats;
  orchestration: OrchestrationData;
  toolFlow: ToolFlowData;
  effectiveness: SubagentEffectivenessItem[];
  patterns: WorkflowPatternsData;
  modelDelegation: ModelDelegationData;
  errorPropagation: ErrorPropagationData;
  concurrency: ConcurrencyData;
  complexity: SessionComplexityItem[];
  compaction: CompactionImpactData;
  cooccurrence: Array<{ source: string; target: string; weight: number }>;
}

// ── Dynamic Workflows (Workflow-tool runs, issue #167) ──
// Fleets of inner sub-agents spawned by the Claude Code "Workflow" tool,
// ingested from on-disk run journals — distinct from the events-derived
// WorkflowData analytics above. Served by GET /api/workflows/runs[/:runId] and
// pushed live via the `workflow_upserted` WebSocket message.

/** One named phase marker from a run journal's `phases[]` array — free-form,
 *  since the Workflow-tool launch script defines its own phase structure. */
export interface WorkflowPhase {
  /** Phase name, e.g. "Plan", "Implement", "Review". Matched against
   *  {@link WorkflowProgressEntry.phaseTitle} to group agents under a phase. */
  title?: string;
  /** Optional longer description of what the phase covers. */
  detail?: string;
  /** Script-defined extra fields pass through untyped. */
  [key: string]: unknown;
}

/** One entry in a {@link WorkflowRun.progress} log — a mixed timeline of phase
 *  markers ("workflow_phase") and inner-agent lifecycle updates
 *  ("workflow_agent"), in journal order. */
export interface WorkflowProgressEntry {
  /** "workflow_agent" (a real inner agent) or "workflow_phase" (a phase marker). */
  type?: string;
  /** For workflow_agent entries: the `agent-<agentId>.jsonl` transcript
   *  basename; the join key back to a real {@link Agent} row. */
  agentId?: string;
  /** Freeform inner-agent role/type as reported by the launch script. */
  agentType?: string | null;
  /** Model the inner agent ran with; overrides {@link WorkflowRun.default_model}. */
  model?: string | null;
  /** Inner-agent lifecycle state, e.g. "running", "done", "error" (freeform). */
  state?: string | null;
  /** Short display label for the agent (falls back to prompt preview). */
  label?: string | null;
  /** Phase this entry belongs to, matching a {@link WorkflowPhase.title}. */
  phaseTitle?: string | null;
  /** When the agent/phase started — ISO string or epoch, script-dependent. */
  startedAt?: string | number | null;
  /** Tokens consumed by this inner agent, once known. */
  tokens?: number;
  /** Tool calls made by this inner agent, once known. */
  toolCalls?: number;
  /** Wall-clock runtime in milliseconds; null while still running. */
  durationMs?: number | null;
  /** Most recent tool name the agent invoked, for a live hint. */
  lastToolName?: string | null;
  /** Truncated preview of the task/prompt handed to this inner agent. */
  promptPreview?: string | null;
  /** Truncated preview of the inner agent's final result, once done. */
  resultPreview?: string | null;
  /** Script-defined extra fields pass through untyped. */
  [key: string]: unknown;
}

/**
 * A fleet run of the Claude Code "Workflow" tool (or self-paced `/loop`) —
 * inner sub-agents that emit no hooks and are instead ingested from an on-disk
 * run journal (see server/lib/workflow-ingest.js). Returned by
 * GET /api/workflows/runs and /api/workflows/runs/:runId. Starts life as
 * `source: "live"` (only the launch script seen) and is promoted to
 * `source: "journal"` once the completed run journal exists on disk.
 */
export interface WorkflowRun {
  /** Stable run id, matching the `wf_<runId>.json` journal / launch script name. */
  run_id: string;
  /** Session that launched this run. FK into {@link Session.id}. */
  session_id: string;
  /** Correlates to a TaskCreate/TaskList task, if any; null otherwise. */
  task_id: string | null;
  /** Display name for the run; null falls back to `run_id` in the UI. */
  name: string | null;
  /** Run lifecycle, e.g. "running", "completed", "error" (freeform). */
  status: string;
  /** Default model inner agents used unless overridden per-agent; null if unset. */
  default_model: string | null;
  /** ISO timestamp the run started; null if not yet known. */
  started_at: string | null;
  /** ISO timestamp the run finished; null while still running. */
  ended_at: string | null;
  /** Total wall-clock runtime in milliseconds; null while still running. */
  duration_ms: number | null;
  /** Number of inner agents spawned (rolled up from `progress`). */
  agent_count: number;
  /** Sum of tokens across all inner agents (rolled up from `progress`). */
  total_tokens: number;
  /** Sum of tool calls across all inner agents (rolled up from `progress`). */
  total_tool_calls: number;
  /** Phase markers for the run; see {@link WorkflowPhase}. */
  phases: WorkflowPhase[];
  /** Interleaved phase + inner-agent timeline; see {@link WorkflowProgressEntry}. */
  progress: WorkflowProgressEntry[];
  /** Path to the generated launch script under `workflows/scripts/`; null if unknown. */
  script_path: string | null;
  /** Path to the `wf_<runId>.json` journal; null while `source === "live"`. */
  journal_path: string | null;
  /** "journal" once a completed run journal exists; "live" while only the
   *  launch script has been observed. */
  source: "journal" | "live";
  /** ISO timestamp this row was first ingested. */
  created_at: string;
  /** ISO timestamp this row was last updated (re-ingested/upserted). */
  updated_at: string;
}

/** Response shape of GET /api/workflows/runs — a paginated, optionally
 *  status/session-filtered list of workflow-tool runs. */
export interface WorkflowRunsResponse {
  /** The page of runs for the current `limit`/`offset`. */
  runs: WorkflowRun[];
  /** Total matching runs (respects the status filter, ignores paging). */
  total: number;
  /** Run count keyed by `status`, across all runs (ignores any filter). */
  counts: Record<string, number>;
  /** Page size that was applied. */
  limit: number;
  /** Zero-based offset of this page into the filtered result set. */
  offset: number;
}

/** Response shape of GET /api/workflows/runs/:runId — a single run plus its
 *  linked inner agents (as regular {@link Agent} rows) and their events. */
export interface WorkflowRunDetail {
  /** The run itself; see {@link WorkflowRun}. */
  workflow: WorkflowRun;
  /** Inner agents linked to this run via the `${sessionId}-jsonl-<agentId>` scheme. */
  agents: Agent[];
  /** Events attributed to this run's inner agents, chronological (up to 5000). */
  events: DashboardEvent[];
}

export interface SessionDrillIn {
  session: Session;
  tree: Array<{
    id: string;
    name: string;
    type: string;
    subagent_type: string | null;
    status: string;
    task: string | null;
    started_at: string;
    ended_at: string | null;
    children: SessionDrillIn["tree"];
  }>;
  toolTimeline: Array<{
    id: number;
    tool_name: string;
    event_type: string;
    agent_id: string | null;
    created_at: string;
    summary: string | null;
  }>;
  swimLanes: Array<{
    id: string;
    name: string;
    type: string;
    subagent_type: string | null;
    status: string;
    started_at: string;
    ended_at: string | null;
    parent_agent_id: string | null;
  }>;
  events: DashboardEvent[];
}

export const STATUS_CONFIG: Record<
  EffectiveAgentStatus,
  { labelKey: string; color: string; bg: string; dot: string }
> = {
  working: {
    labelKey: "common:status.working",
    color: "text-emerald-700 dark:text-emerald-400",
    bg: "bg-emerald-50 dark:bg-emerald-500/10 border-emerald-200 dark:border-emerald-500/20",
    dot: "bg-emerald-400",
  },
  waiting: {
    labelKey: "common:status.waiting",
    color: "text-amber-600 dark:text-yellow-400",
    bg: "bg-amber-50 dark:bg-yellow-500/10 border-amber-200 dark:border-yellow-500/20",
    dot: "bg-amber-500 dark:bg-yellow-400",
  },
  completed: {
    labelKey: "common:status.completed",
    color: "text-indigo-700 dark:text-indigo-400",
    bg: "bg-indigo-50 dark:bg-indigo-500/10 border-indigo-200 dark:border-indigo-500/20",
    dot: "bg-indigo-400",
  },
  error: {
    labelKey: "common:status.error",
    color: "text-red-700 dark:text-red-400",
    bg: "bg-red-50 dark:bg-red-500/10 border-red-200 dark:border-red-500/20",
    dot: "bg-red-400",
  },
};

// ── Transcript / Conversation types ──

export interface TranscriptContent {
  type: "text" | "tool_use" | "tool_result" | "thinking";
  text?: string;
  name?: string;
  id?: string;
  input?: Record<string, unknown> | { _truncated: string };
  output?: string;
  is_error?: boolean;
}

export interface TranscriptMessage {
  type: "user" | "assistant";
  timestamp: string | null;
  content: TranscriptContent[];
  model?: string;
  usage?: {
    input_tokens: number;
    output_tokens: number;
    cache_read_input_tokens?: number;
    cache_creation_input_tokens?: number;
  };
}

export interface TranscriptResult {
  messages: TranscriptMessage[];
  total: number;
  has_more: boolean;
  last_line: number;
  first_line: number;
}

export interface TranscriptInfo {
  id: string;
  name: string;
  type: "main" | "subagent" | "compaction";
  subagent_type?: string | null;
  has_transcript: boolean;
  db_agent_id?: string | null;
}

export interface TranscriptListResult {
  transcripts: TranscriptInfo[];
}

export const SESSION_STATUS_CONFIG: Record<
  EffectiveSessionStatus,
  { labelKey: string; color: string; bg: string; dot: string }
> = {
  active: {
    labelKey: "common:status.active",
    color: "text-emerald-700 dark:text-emerald-400",
    bg: "bg-emerald-50 dark:bg-emerald-500/10 border-emerald-200 dark:border-emerald-500/20",
    dot: "bg-emerald-400",
  },
  waiting: {
    labelKey: "common:status.waiting",
    color: "text-amber-600 dark:text-yellow-400",
    bg: "bg-amber-50 dark:bg-yellow-500/10 border-amber-200 dark:border-yellow-500/20",
    dot: "bg-amber-500 dark:bg-yellow-400",
  },
  completed: {
    labelKey: "common:status.completed",
    color: "text-indigo-700 dark:text-indigo-400",
    bg: "bg-indigo-50 dark:bg-indigo-500/10 border-indigo-200 dark:border-indigo-500/20",
    dot: "bg-indigo-400",
  },
  error: {
    labelKey: "common:status.error",
    color: "text-red-700 dark:text-red-400",
    bg: "bg-red-50 dark:bg-red-500/10 border-red-200 dark:border-red-500/20",
    dot: "bg-red-400",
  },
  abandoned: {
    // Muted slate distinguishes "given up / faded out" from yellow Waiting
    // (attention required).
    labelKey: "common:status.abandoned",
    color: "text-slate-700 dark:text-slate-400",
    bg: "bg-slate-500/10 border-slate-500/20",
    dot: "bg-slate-400",
  },
};
