# Podium Web App — Complete Audit

**Purpose**: Ground truth for porting the Podium React dashboard to a native macOS SwiftUI app.  
**Audited**: `/Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/client/src/`  
**Date**: 2026-06-24  

---

## Table of Contents

1. [Web App Overview](#1-web-app-overview)
2. [Screen-by-Screen Feature Inventory](#2-screen-by-screen-feature-inventory)
3. [Feature Comparison Table](#3-feature-comparison-table)
4. [Gap Analysis by Priority](#4-gap-analysis-by-priority)
5. [Session Detail: Conversation Tab Deep Dive](#5-session-detail-conversation-tab-deep-dive)
6. [Dashboard Deep Dive](#6-dashboard-deep-dive)
7. [Implementation Recommendations](#7-implementation-recommendations)

---

## 1. Web App Overview

### Navigation Structure

The app uses a collapsible left sidebar (`Sidebar.tsx`). Collapsed state is persisted in `localStorage` key `sidebar-collapsed`. The sidebar shows a WebSocket connection indicator and a live event counter (events/sec, peak/sec, recent event type list — persisted in `localStorage` key `sidebar-connection-stats`).

**Nav items (in order)**:

| Route | Label | Icon | Visibility |
|---|---|---|---|
| `/` | Dashboard | LayoutDashboard | Always |
| `/search` | Search | Search | Always |
| `/kanban` | Kanban Board | Columns3 | Only if `localStorage["podium-show-kanban"] === "true"` |
| `/sessions` | Sessions | FolderOpen | Always |
| `/activity` | Activity Feed | Activity | Always |
| `/analytics` | Analytics | BarChart3 | Always |
| `/workflows` | Workflows | Workflow | Always |
| `/cc-config` | Claude Config | Boxes | Always |
| `/run` | Run Claude | Play | Always |
| `/import` | Import | Upload | Always |
| `/settings` | Settings | Settings | Always |

The Kanban Board is hidden by default; users enable it via the Settings page toggle. The sidebar also provides:
- WS connection dot (green/red) with tooltip showing event stats
- Theme toggle (dark/light)
- Link to author website (wp-media.me) + GitHub link
- Cmd/Ctrl+K → navigates to `/search` (wired in `App.tsx`)

### Global Features

- **Dark/light mode**: Tailwind `dark:` classes everywhere; toggle stored in localStorage. The app respects system preference but lets users override.
- **WebSocket**: `eventBus` singleton (`EventBus` class). All pages subscribe via `eventBus.subscribe(handler)`. Connection state exposed via `useSyncExternalStore(eventBus.onConnection, () => eventBus.connected)`.
- **Advanced Metrics feature flag**: `localStorage["podium-advanced-metrics"]`. When off: hides token/cost stat cards on Dashboard, cost/token Analytics tabs, cost columns on Sessions, cost details on Session Detail. Toggled in Settings.
- **i18n**: `react-i18next`. All UI strings are in translation files. Several pages use `useTranslation("ccConfig")` etc. Language appears to be English only in practice but the architecture supports multi-language.
- **Keyboard shortcut**: Cmd/Ctrl+K → global search.

### Design Language

- Tailwind CSS utility classes
- Dark theme: `bg-surface-1/2/3/4`, `text-fg`, `text-fg-muted`
- Accent color: indigo/amber (`text-accent`, `bg-accent/15`)
- Card class: `.card` → subtle border, rounded corners, background surface
- Hoverable cards: `.card-hover`
- Status colors: cyan (active/working), emerald (completed), red (error), amber (abandoned), yellow (waiting)
- Pulsing dot for active/waiting states (CSS animation)
- Skeleton loaders (`<Skeleton />` component) for all loading states
- `animate-fade-in` class on every page root div
- Portal-based tooltips for chart hovers

---

## 2. Screen-by-Screen Feature Inventory

### 2.1 Dashboard (`/`)

**File**: `Dashboard.tsx` (1645 lines)

**Two tabs**: Monitor | Health

#### Monitor Tab

**Stat cards row** (always visible):
- Total Sessions (count)
- Active Agents (count)
- Active Subagents (count, always shown — not gated by advanced metrics)

**Stat cards (advanced metrics only)**:
- Events Today
- Total Events
- Total Cost (animated count-up, `fmtCostFull`)

**Push notification banner**: If browser notifications not granted and banner not dismissed → shows discoverability banner. Dismissed state in `localStorage["podium-notif-banner-dismissed"]`.

**"View Board" button**: Navigates to `/kanban`. Only shown if kanban is enabled.

**Active agents tree**:
- Fetches all active agents + their sessions
- Main agents shown as expandable rows with chevron toggle
- Subagents indented under parent with `border-l-2` left accent line
- Each node is an `AgentCard` component (see §2.4)
- Clicking an agent → navigates to that session's detail page
- Empty state: "No active agents" with Bot icon
- Count dynamically fills available height via `ResizeObserver`

**Recent activity feed** (right column):
- Last N events (N = available height / row height, via `ResizeObserver`)
- Each row: event_type pill, tool_name (if any), session name, time ago
- Clicking a row → navigates to `/sessions/${event.session_id}`
- WS: `new_event` → prepend to feed (no full reload needed)

**WS events handled**:
- `agent_created`, `agent_updated`, `session_created`, `session_updated` → full reload of agents + sessions + stats
- `new_event` → prepend to recent events list (no reload)

#### Health Tab

9 draggable system health cards using `@dnd-kit`. Order persisted in `localStorage`.

| Card | Content |
|---|---|
| Runtime | Node.js uptime, version, memory, CPU |
| Storage | SQLite DB size pie chart (sessions/agents/events/token_usage breakdown) |
| Health Score | Ring gauge (0–100) based on recent error rate, WS stability, etc. |
| Token Usage | Bars: input/output/cache read/cache write totals |
| Concurrency | Sparkline of active agent count over time |
| Tool Usage | Horizontal bars, top tools by call count |
| Subagent Effectiveness | Bars comparing subagent completion vs error rates |
| Integration | Hook status (installed/missing) + WS connection count |
| Platform | SQLite PRAGMA values (journal_mode, cache_size, page_size, etc.) |

---

### 2.2 Sessions (`/sessions`)

**File**: `Sessions.tsx` (624 lines)

**Table columns**: Session (name + optional tag chip + short ID), Status badge, Last Active (time ago), Duration, Agents count, Cost (advanced metrics only), Directory (cwd)

**Filters**:
- Text search (300ms debounce, hits `/api/sessions?q=...`)
- Directory dropdown (all unique cwds from loaded sessions)
- Sort: Last Active (default) | Duration | Cost, with asc/desc toggle button
- Group by cwd toggle (renders group header rows with project directory name)
- Status tabs: All | Active | Waiting | Completed | Error | Abandoned

**Inline rename on hover**: Pencil icon appears on name hover → inline editable `<input>` for name + optional tag input → `PATCH /api/sessions/:id` on blur/Enter.

**"Run" badge**: Shown on sessions that have an active run handle (from `/api/run/list`). Clicking navigates to `/run?session=<id>`.

**Group-by-cwd mode**: Renders collapsible group header rows. Each group shows the cwd path and session count.

**Pagination**: 10 per page (server-side), numbered pagination with first/last/prev/next.

**WS events handled**:
- `session_created`, `session_updated` → reload
- `new_event` with type `Stop` or `SessionEnd` → reload
- `run_status` → reload run handle list

---

### 2.3 Session Detail (`/sessions/:id`)

**File**: `SessionDetail.tsx` (1615 lines)

**Header**:
- Session name (editable on click? — uses same rename pattern as Sessions list)
- Status badge
- Error count chip — clicking jumps to Timeline tab filtered to errors only
- Session ID (first 16 chars), copyable
- Model badge (from session.model)
- Start time + duration
- Cost (advanced metrics only)
- cwd path (truncated, full path in tooltip)

**Annotation (sticky note)**:
- Stored in `localStorage["podium-annotation-${id}"]`
- Collapsed by default: shows first line as preview
- Expands to a full `<textarea>` for notes about the session
- Auto-saves on blur

**Share popover**:
- "Download JSON" → `GET /api/export/session/:id` (downloads full export bundle)
- "Copy URL" → copies current page URL to clipboard

**"Run in progress" banner**: Shown when a run handle is active for this session. Links to `/run`.

**Run Summary card**: Collapsed by default for completed/error sessions. Shows: Cost, Duration, Agents count, Tool calls, Errors, Files changed. Expanded by default for active sessions.

**Smart default tab**: If session has ≤ 1 agent AND user hasn't manually picked a tab → auto-selects Conversation tab.

**4 Tabs**:

#### Agents Tab
- Hierarchical tree of agents
- Main agents as expandable cards with chevron
- Subagents indented under parent
- Each agent uses `AgentCard` component
- Compaction agents labeled `#1 · HH:MM` format
- Clicking a leaf agent (subagent) → switches to Conversation tab showing that agent's transcript

#### Conversation Tab
- Renders `<ConversationView sessionId={id} initialTranscriptId={pendingTranscriptId} />`
- Agent selector dropdown (if multiple agents/transcripts)
- See §5 for full deep dive

#### Thinking Tab (`ThinkingTab`)
- Fetches all available transcripts for the session
- Extracts all `type: "thinking"` content blocks chronologically
- Shows a timeline of thinking entries
- Agent filter dropdown (all agents → filter to one)
- Each entry: expand/collapse, timestamp, char count
- "→ See context" button: jumps to Conversation tab at that message
- Empty state if no thinking content

#### Timeline Tab
- `EventFilters` component (full filter panel: status presets, tool_name, agent_id, session_id, text query, date range)
- `EventFiltersInfo` info banner describing active filters
- Grouped/flat view toggle
  - Grouped: `EventGroupRow` component (events grouped by some dimension)
  - Flat: `EventDetail` inline expansion per row
- "Load more" button (server-side pagination)
- Scrollable container (max 600px height)
- Error chip in header → pre-filters Timeline to error events

**Cost breakdown table** (advanced metrics only):
- Per-model breakdown: model name, input tokens, output tokens, cache read tokens, cache write tokens, cost
- Only rendered when advanced metrics enabled

**WS events handled**:
- `agent_created`, `agent_updated`, `session_updated` → `load()` (full reload)
- `new_event` → debounced `refreshEventsWithPagination()` (500ms)

---

### 2.4 Analytics (`/analytics`)

**File**: `Analytics.tsx` (1429 lines)

**Stat pills row** (top):
- Total Sessions
- Total Agents
- Total Tokens (advanced metrics only)
- Total Cost (advanced metrics only)
- Total Events (advanced metrics only)

**Activity heatmap**: 52-week GitHub-style contribution grid. Color-coded: indigo shades in dark mode, amber shades in light mode. Shows session activity per day. Clicking a day — unimplemented (shows date tooltip only).

**30-day sparkline**: Small inline sparkline of daily session count. Shows peak day value + total for period.

**Export JSON button**: Downloads full analytics payload as JSON.

**4 tabs**:

| Tab | Visibility | Content |
|---|---|---|
| Cost Analytics | Advanced metrics only | Daily cost trend (SVG line chart), cost by model (donut + table), cost by weekday (bar chart) |
| Token Analytics | Advanced metrics only | Token distribution bars (input/output/cache read/cache write), token breakdown table, token mix donut |
| Productivity | Always | Tool usage bars (top 12), session outcomes donut, daily session trends sparkline + last 7 days |
| Workflow Intelligence | Always | Agent type bars (subagent_type), agent status donut, event type bars |

All charts have hover tooltips via React portal (to avoid z-index/overflow issues).

**WS**: Any session/agent/event WS message → reload. Also polls every 15 seconds.

---

### 2.5 Activity Feed (`/activity`)

**File**: `ActivityFeed.tsx` (637 lines)

**Real-time event stream** with pause/resume:
- "Pause" button → buffers incoming events, shows buffered count badge
- "Resume" button → flushes buffer, resumes live updates

**Quick filter presets**: "Errors only" | "Tool calls only" | "Clear filters"

**`EventFilters` component**: Full filter panel:
- Status preset buttons (all/errors/tools)
- `tool_name` text filter
- `agent_id` selector
- `session_id` selector
- Free-text query
- Date range (from/to)

**`EventFiltersInfo` banner**: Shows active filter summary (dismissible).

**Grouped/flat toggle**:
- Flat view: each row clickable → inline `EventDetail` expansion; row has "View session" external link
- Grouped view: `EventGroupRow` component

**Session name lookup**: Fetches all sessions on mount to enrich event rows with session names.

**Agent info lookup**: Fetches all agents on mount to enrich event rows with agent names.

**Pagination**: 50 per page. Full pagination controls: first/prev/numbered pages (with ellipsis for large ranges)/next/last.

**Filter state persistence**: `sessionStorage["podium-activity-filters"]` (resets on tab close).

**WS**: `new_event` → debounced refresh (500ms).

---

### 2.6 Kanban Board (`/kanban`)

**File**: `KanbanBoard.tsx` (471 lines)

**Two board views** (toggle in header):
- **Agents** (4 columns): working | waiting | completed | error
- **Sessions** (5 columns): active | waiting | completed | error | abandoned

View persisted in `localStorage["kanban-board-view"]`.

**Column anatomy**:
- Header: colored status dot (pulsing for active/working/waiting states), status label, count badge, info tooltip (describes what the status means)
- Cards: `AgentCard` (agents view) or `SessionCard` (sessions view)
- "Show more" button: 10 items/column, client-side pagination

**AgentCard** (`components/AgentCard.tsx`):
- Agent name, subagent_type label, status badge
- Current tool pill (if `agent.current_tool` set)
- Task preview (truncated)
- Parent session link
- Status-colored left accent bar
- Pulsing dot for working/waiting

**SessionCard** (`components/SessionCard.tsx`):
- Session name or auto-generated from cwd
- Status badge, cost (if available), agent count
- cwd path (truncated, monospace)
- Last active time ago
- Click → navigate to session detail

**WS**: Debounced 300ms reload on any `agent_*` or `session_*` event.

---

### 2.7 Workflows (`/workflows`)

**File**: `Workflows.tsx` (731 lines) + `components/workflows/` directory

**Stats row** (`WorkflowStats` component): Summary stats at the top.

**Featured sections** (expanded by default):
- **Session Drilldown** (`SessionDrillIn`): Select a specific session → deep workflow breakdown
- **Error Propagation Map** (`ErrorPropagationMap`): Visual map of how errors spread across agents

**Advanced Analytics group** (collapsed by default). Each is an accordion panel, state persisted in `localStorage` with prefix `podium-workflow-section-`:

| Component | Description |
|---|---|
| `OrchestrationDAG` | Directed acyclic graph of agent spawn relationships |
| `ConcurrencyTimeline` | Gantt-style timeline of agent concurrency |
| `AgentCollaborationNetwork` | Network graph of agent interactions |
| `ModelDelegationFlow` | Sankey/flow diagram of which models delegate to which |
| `SubagentEffectiveness` | Bar charts: subagent success/fail rates by type |
| `ToolExecutionFlow` | Flow of tool calls across agents |
| `WorkflowPatterns` | Detected recurring patterns in agent workflows |
| `SessionComplexityScatter` | Scatter plot: session complexity vs duration/cost |

**Controls**:
- "Expand all" / "Collapse all" buttons for advanced group
- Status filter: all | active | completed
- Chart info popovers: each chart has an info icon → "what this chart shows / how to read it / why it matters"
- Export JSON button

**WS**: Any event → debounced 3s reload.

---

### 2.8 Run Claude (`/run`)

**File**: `Run.tsx` (3743 lines)

**Two modes**:
- **Conversation** (default): Multi-turn chat with Claude subprocess
- **Headless**: One-shot mode, no interactive follow-up

**Spawn**: `POST /api/run` → starts Claude subprocess on the server.

**Streaming**: WS `run_stream` events. Uses `TypewriterEnvelopes` hook for character-by-character rendering (smooth typewriter effect). Stream event envelopes are merged/accumulated before display.

**Active runs switcher** (header): If multiple run handles exist → dropdown to switch between them.

**Run history**: Stores last 50 runs. "Resume" resumes a previous session (`claude --resume <id>`).

**Config card** (left panel):
- Prompt textarea with autocomplete:
  - `/` → slash command autocomplete (shows builtin[CLI-only tagged]/user/project/plugin commands with source badges)
  - `@` → file path autocomplete (fetches files from working directory via `GET /api/run/files`)
  - Arrow keys / Tab / Enter to select, Escape to dismiss
  - Cmd+Enter to submit
- cwd selector with server-suggested directories
- Model selector (all Claude models)
- Permission mode selector (default/acceptEdits/bypassPermissions etc.)
- Effort level selector
- "Resume existing session" toggle

**Limitations banner**: Explains what works in browser mode vs Claude TUI (e.g., no native TUI rendering). Minimizable, state in localStorage.

**Token/context-window meter**: Shows token usage vs context window limit. Color thresholds: green (< 70%) → amber (70–85%) → red (> 85%).

**Chat view** (RunSession component): Renders the streaming conversation. Uses the same `MessageList`/`ToolCallBlock`/`CodeBlock` components as ConversationView. Tool use blocks appear inline as they stream.

**WS `run_status`**: Updates run handle status (idle/running/error).

---

### 2.9 Claude Config (`/cc-config`)

**File**: `CcConfig.tsx` (1000+ lines)

**Purpose**: Surfaces every Claude Code configuration artifact known to the CLI — read-only for dangerous surfaces (plugins, MCP, hooks-in-settings, settings.json), read/create/edit/delete for safe text-file surfaces.

**Global controls**:
- Scope filter: all | user | project
- Search filter (filters items within active tab)
- Refresh button + last-updated timestamp
- WS: `cc_config_changed` event → debounced 250ms refetch

**12 tabs**:

| Tab | Key | Mutable | Content |
|---|---|---|---|
| Overview | `overview` | No | Summary counts: skills, agents, commands, plugins, MCP servers, hooks, memory files, settings files |
| Skills | `skills` | Yes | List of skill `.md` files (user + project scope). Create/edit/delete. File path, scope badge, description preview |
| Agents | `agents` | Yes | List of agent `.md` files. Same CRUD as Skills |
| Commands | `commands` | Yes | Slash command `.md` files. CRUD |
| Output Styles | `outputStyles` | Yes | Output style `.md` files. CRUD |
| Plugins | `plugins` | No (read-only) | Installed Claude Code plugins. Shows name, version, description, source |
| Marketplaces | `marketplaces` | No | Configured marketplace sources |
| MCP Servers | `mcp` | No (read-only) | MCP server configs (name, transport, command/URL, scope) |
| Hooks | `hooks` | No (read-only) | Hook configurations from settings. Shows hook type, matcher, command |
| Keybindings | `keybindings` | No | Current keybinding map |
| Settings | `settings` | No | Parsed settings.json contents for each scope |
| Memory | `memory` | Yes | CLAUDE.md memory files (user + project). Create/edit/delete |

**Editor** (for mutable tabs):
- Full-screen modal slide-over panel
- Textarea with monospace font
- Create mode: template pre-filled based on type
- Edit mode: fetches current file content via `GET /api/cc/file?path=...`
- Save: `POST /api/cc/artifact` (create) or `PUT /api/cc/artifact` (update)
- Delete: `DELETE /api/cc/artifact` with confirmation modal

**File viewer**: Read-only modal for any file. Shows raw content with syntax highlighting.

**Backups**: Accordion panel showing recent file backups (`CcBackup[]`). Can restore a backup.

**Toast notifications**: Success/error toasts (auto-dismiss 5s).

---

### 2.10 Search (`/search`)

**File**: `Search.tsx` (413 lines)

**Global search** across sessions, tool calls, and conversations.

**Input**: Auto-focused on mount. Cmd/Ctrl+K shortcut in `App.tsx` navigates to this page. Escape clears input.

**Behavior**:
- Minimum 2 characters to trigger search
- 300ms debounce
- Below minimum: falls back to showing 10 most recent sessions (`GET /api/sessions?limit=10&sort_by=time&sort_desc=true`) labeled "Recent sessions"

**Results** (grouped):
- Sessions section: session name, status badge, cwd path (monospace), highlight snippet with `<mark>` tag rendering
- Events section: event_type, tool_name badge, "in {session_name}" link, summary snippet with highlights

**Navigation**:
- Session result → `/sessions/:id`
- Event result → `/sessions/:id?tab=timeline`

**Highlight rendering**: `<Highlight>` component splits server-returned text on `<mark>...</mark>` tags and renders spans — no `dangerouslySetInnerHTML`.

**Limit**: 20 results total.

---

### 2.11 Settings (`/settings`)

**File**: `Settings.tsx` (1480 lines)

**Interface section**:
- Kanban Board visibility toggle (writes `localStorage["podium-show-kanban"]`, fires `podium-settings-changed` custom event)
- Advanced Metrics toggle (writes `localStorage["podium-advanced-metrics"]`, fires same event)

**Model Pricing table**:
- Lists all pricing rules (model name, input cost per M tokens, output cost per M tokens, cache read/write costs)
- Add new rule, edit existing (inline), delete with confirmation
- "Reset to defaults" button
- Info tooltip explaining what the pricing affects

**Hook Configuration section**:
- Shows Claude Code hooks installation status (installed / not installed)
- "Reinstall hooks" button → `POST /api/settings/hooks/reinstall`
- Per-hook status grid: each hook type (PreToolUse, PostToolUse, Stop, etc.) → installed/missing badge
- Hook file path display

**Claude Home**: Configurable path for the `claude` binary. Text input + save button.

**`ImportHistory` component**: Inline list of previous import operations (session imports). Shows file name, imported session ID, timestamp, link to session.

**Notifications section**:
- Master enable/disable toggle (requests browser Push permission)
- Permission status badge (Granted / Denied / Not requested)
- Per-event toggles: new session created | session completed | session error | subagent spawned
- "Send test notification" button

**Data Management section**:
- DB overview: counts for sessions/agents/events/token_usage/model_pricing rows + DB file size
- Session Cleanup: two inputs (abandon sessions idle for N hours, purge sessions older than N days) + "Run cleanup" button
- Danger Zone: "Clear all data" with two-step confirmation (type "DELETE" to confirm)

**About section**: Server uptime, Node.js version, platform, WebSocket connections count.

**Total cost summary card** (advanced metrics only): Animated count-up of total all-time cost.

**Export data**: Download link → `GET /api/settings/export` (full DB export).

---

### 2.12 Import Session (`/import`)

**File**: `ImportSession.tsx` (~400 lines)

**Purpose**: Load a Podium session export bundle (`.json`) and either import it into the DB or preview it without importing.

**Input methods**:
1. **Drag-and-drop zone**: Large dashed drop target, click to open file picker
2. **File picker**: `.json` / `application/json` only
3. **Paste JSON**: Toggle to show a `<textarea>` for pasting raw JSON

**Validation**:
- Must be valid JSON
- Must have `podium_export_version === "1.0"` (constant `EXPORT_VERSION`)
- Must have a `session` object with an `id` string

**After loading a valid bundle — two actions**:
1. **Import**: `POST /api/import/session` with full bundle JSON → on success, navigate to the new session's detail page
2. **Preview** (read-only): Toggle to see session details, agents list, event log without importing

**Preview content**:
- Session card: name, status badge, cwd, model, start/end time, duration, cost
- Agents list: name, type, subagent_type, status, start/end
- Events list: event_type, tool_name, summary, timestamp
- No mutation possible in preview mode

**Reset button**: Clears loaded bundle and returns to upload screen.

---

## 3. Feature Comparison Table

| Feature | Web App | Swift App | Notes |
|---|---|---|---|
| **Navigation** | 11 nav items, collapsible sidebar, Kanban hidden by default | 4 nav items (Dashboard, Sessions, Analytics, Activity Feed) | Swift missing 7 screens entirely |
| **WS live updates** | Full eventBus, all pages subscribe | WebSocketClient with reconnect, AppState handles WS | Both have reconnect; Swift uses exponential backoff |
| **Dark/light mode** | Toggle, localStorage | Hardcoded dark | Web supports both |
| **Keyboard shortcut** | Cmd+K global search | Cmd+1-4 nav shortcuts | Swift has nav shortcuts; web has global search shortcut |
| **Dashboard: stat cards** | 3 always + 3 advanced metrics | 4 always (Active Sessions, Total Sessions, Active Agents, Cost) | Different cards; web has Events Today, Total Events |
| **Dashboard: active agents tree** | Expandable tree with AgentCard, click → session | Not present | P1 gap |
| **Dashboard: health tab** | 9 draggable health cards | Not present | P2 gap |
| **Dashboard: live feed** | Event feed in right column, clickable rows | EventFeedRow in right column | Both have feeds; web rows are clickable to navigate |
| **Sessions: table columns** | Name+tag+ID, Status, Last Active, Duration, Agents, Cost, Directory | SessionListRow with name, status, start time, cwd, agents | Web has more columns (duration, cost) |
| **Sessions: inline rename** | Pencil on hover, PATCH API | Not present | P1 gap |
| **Sessions: tag** | Tag chip, editable | Not present | P2 gap |
| **Sessions: group by cwd** | Toggle | Not present | P2 gap |
| **Sessions: sort** | Last Active / Duration / Cost, asc/desc | Not present (server default order) | P2 gap |
| **Sessions: directory filter** | Dropdown | Not present | P2 gap |
| **Sessions: pagination** | Server-side, 10/page, numbered | Load more button | Web has full pagination; Swift has load-more |
| **Session Detail: tabs** | 4 (Agents, Conversation, Thinking, Timeline) | 5 (Overview, Agents, Events, Conversation, Cost) | Swift has Overview+Cost; web has Thinking+Timeline(=Events) |
| **Session Detail: annotation** | localStorage sticky note | Not present | P2 gap |
| **Session Detail: share/export** | Download JSON, Copy URL | Not present | P2 gap |
| **Session Detail: run banner** | Shows if session driven from /run | Not present | P3 gap |
| **Session Detail: smart tab** | Auto-selects Conversation for simple sessions | Not present | P3 polish |
| **Session Detail: error chip** | Clickable, filters Timeline to errors | Not present | P2 gap |
| **Session Detail: cost breakdown** | Per-model table (adv. metrics) | Yes (CostTabView) | Both have it; web is tab section, Swift is separate tab |
| **Conversation: transcript** | Full JSONL with pagination, 50/page, load history | ConversationTabView (implementation not fully audited) | Both have it; web has incremental tail-fetch |
| **Conversation: agent selector** | Dropdown for multi-agent sessions | Unknown | Need to verify in Swift |
| **Conversation: thinking blocks** | Collapsible ThinkingBlock with preview | Unknown | Need to verify in Swift |
| **Conversation: tool blocks** | ToolCallBlock with syntax highlighting, per-tool formatting | Unknown | Need to verify in Swift |
| **Conversation: markdown** | Full CommonMark+GFM renderer (no dangerouslySetInnerHTML) | Unknown | Need to verify in Swift |
| **Conversation: TUI segments** | CommandPill, TerminalBlock, CaveatBlock, CollapsibleBlock | Unknown | Need to verify in Swift |
| **Thinking tab** | Dedicated tab extracting thinking blocks across all agents | Not present in Swift | P1 gap |
| **Timeline/Events tab** | EventFilters + grouped/flat + pagination | Events tab: flat list | Web has much richer filtering |
| **Analytics: heatmap** | 52-week activity heatmap | Not present | P1 gap |
| **Analytics: charts** | Line, donut, bar, sparkline (SVG + Swift Charts) | Bar charts (MiniBarChart), token breakdown | Web has many more chart types |
| **Analytics: tabs** | 4 (Cost, Token, Productivity, Workflow) | Single view with all analytics | Web separates by concern |
| **Analytics: advanced metrics gate** | Cost + Token tabs hidden without flag | Always shown | Swift doesn't implement the flag |
| **Activity Feed** | Pause/resume, EventFilters, grouped/flat, full pagination | ActivityFeedView (basic) | Web version is much richer |
| **Kanban Board** | Full drag-free board with agents/sessions views | Not present | P1 gap |
| **Workflows** | 10 workflow analysis charts | Not present | P2 gap |
| **Run Claude** | Full in-app Claude runner with streaming | Not present | P1 gap |
| **Claude Config** | Full 12-tab config explorer with CRUD | Not present | P2 gap |
| **Global Search** | Cross-entity search with highlights | Not present | P1 gap |
| **Settings: pricing** | Full CRUD pricing table | Not present | P2 gap |
| **Settings: hooks** | Hook status + reinstall | Not present | P2 gap |
| **Settings: notifications** | Web Push per-event toggles | Not present | P3 gap (use UNUserNotification instead) |
| **Settings: data management** | DB overview, cleanup, danger zone | Not present | P2 gap |
| **Import Session** | Full drag/drop import + preview | Not present | P3 gap |
| **Advanced metrics flag** | localStorage gate on cost/token data | Not implemented | P2 gap |
| **Session: "Run" badge** | Badge if session has active run handle | Not present | P3 gap |
| **Sidebar WS stats** | Event counts, peak/sec in sidebar | ConnectionBanner + LiveBadge in toolbar | Web more detailed |
| **Loading states** | Skeleton loaders everywhere | ProgressView + LoadingView | Web more granular |
| **Session refresh behavior** | Smart: WS events trigger targeted refreshes | Full reload on WS event (causes spinner flicker) | Known issue in CLAUDE.md |

---

## 4. Gap Analysis by Priority

### P0 — Broken / Embarrassing (Fix Immediately)

1. **Constant spinner on refresh**: AppState triggers a full reload on every WS event, causing a loading spinner to flash constantly. The web app uses targeted, incremental updates (prepend events, patch agent in cache, etc.). This is called out in CLAUDE.md as a known annoyance.
   - Fix: Use the WS event type to decide what to reload. `new_event` should prepend to the live feed without a full refresh. `agent_updated` should patch the cached session detail in place (the `SessionDetailResponse` already uses `var` fields for this purpose).

2. **Sidebar can't be collapsed**: CLAUDE.md notes this. The `NavigationSplitView` uses `.constant(.all)`. 
   - Fix: Use `@State private var columnVisibility = NavigationSplitViewVisibility.all` and let the user control it.

3. **Session always refreshes**: The loading spinner pops in constantly per CLAUDE.md.
   - Same root cause as #1 — targeted WS updates would fix this.

### P1 — Missing Features to Port (High Value)

4. **Global search**: The web has `/search` with full cross-entity search. Swift has no search across sessions, events, or conversations. The API endpoint `/api/search` is already available.

5. **Active agents tree on Dashboard**: The web Dashboard Monitor tab prominently shows all active agents as an expandable tree. Swift shows only a recent sessions list. This is the most-watched panel during active Claude Code runs.

6. **Kanban Board**: A visual board view of all agents/sessions by status. Good for monitoring multiple concurrent Claude sessions. The API data already flows through AppState.

7. **Run Claude in-app**: The ability to spawn Claude Code from within the app (two-way terminal-like experience). This is complex but differentiating — the web has a full runner with streaming, slash commands, file references.

8. **Thinking tab**: The dedicated Thinking tab extracts extended thinking blocks across all agents in a session. This provides visibility into model reasoning that the current Swift app doesn't expose at all.

9. **Session Detail: Verify Conversation tab completeness**: The Swift `ConversationTabView` exists but wasn't fully audited. Confirm it has:
   - Multi-agent transcript selector dropdown
   - Thinking block rendering (indigo collapsible block with char count)
   - Tool call blocks (collapsible, per-tool formatting for Read/Write/Bash/Edit)
   - Full CommonMark+GFM markdown (headings, lists, tables, code blocks with syntax highlighting)
   - TUI segment rendering (CommandPill, TerminalBlock stdout/stderr, CaveatBlock)
   - "Load history" (scroll to top → load older messages)
   - "New message" floating button when scrolled up

10. **EventFilters on Activity Feed and Session Timeline**: The web's event filtering is far more powerful (tool_name filter, agent_id filter, date range, free text). Swift shows a flat event list with no filtering beyond status.

### P2 — Polish & Completeness (Ship Soon)

11. **Session inline rename + tags**: Editing session names directly in the sessions list without going to a detail view. Web has pencil-on-hover PATCH pattern.

12. **Session sort + directory filter**: Sort sessions by duration or cost. Filter by project directory. Currently Swift just shows server-default order.

13. **Session Detail annotation (sticky note)**: Per-session notes stored locally. Useful for tracking findings during long runs.

14. **Advanced metrics feature flag**: Gate cost/token data behind a toggle (matching web behavior). Also affects which Analytics tabs are shown.

15. **Analytics: 52-week activity heatmap**: High visual impact, shows overall usage patterns at a glance.

16. **Analytics: richer charts**: The web has line charts (daily cost trend), donut charts (cost by model), weekday bars (cost by weekday). Swift only has bar charts.

17. **Session Detail: share/export**: Download session JSON for sharing or backup. `GET /api/export/session/:id` is ready.

18. **Workflows page**: The 10 workflow analysis charts provide deep insight into multi-agent orchestration. Good for power users.

19. **Settings: data management**: DB size overview, session cleanup (abandon/purge), danger zone. Operational necessity for long-running installs.

20. **Settings: hook status**: Shows whether Podium hooks are installed into Claude Code. Important for first-time setup.

21. **Session Detail: error count chip → filter**: Clicking the error count chip in the session header should jump to the Events tab filtered to errors only.

### P3 — Native macOS Superpowers (Delight)

22. **Menu bar extra**: Show active agent count and total cost in the menu bar without opening the main window. SwiftUI `MenuBarExtra` + a compact popover.

23. **Notifications**: `UNUserNotificationCenter` alerts when a session completes or errors. The web uses Web Push; the macOS app should use native notifications with actionable buttons (e.g., "View Session").

24. **Cmd+K global search**: App-wide keyboard shortcut to focus the search field / open a search panel.

25. **Session "Awaiting Input" detection**: The web shows a yellow "Awaiting Input" badge when `session.awaiting_input_since` is non-null. Swift has this badge in `SessionDetailHeader` but may not show it in the sessions list row.

26. **Import Session**: Drag a `.json` export into the app to import it. macOS can use `onDrop` with UTType.json.

27. **Sidebar WS event statistics**: The web sidebar shows a live event count + peak events/sec. For Swift: a popover from the LiveBadge showing event type breakdown would be the native equivalent.

---

## 5. Session Detail: Conversation Tab Deep Dive

### Architecture

`ConversationView.tsx` is the entry point. It manages:
- Transcript selection (which agent's JSONL to show)
- Incremental message fetching
- WS + polling coordination
- Scroll position + "new message" floating button
- Rendering delegation to `MessageList`

### Data Flow

```
GET /api/sessions/:id/transcripts → list of TranscriptInfo[]
  → agent_id + name for dropdown

GET /api/sessions/:id/transcript?agent_id=X&limit=50
  → { messages: TranscriptMessage[], total, has_more, first_line, last_line }
  → initial load: last 50 messages (most recent)

GET /api/sessions/:id/transcript?agent_id=X&after=<last_line>&limit=50
  → incremental tail fetch (WS trigger or poll)

GET /api/sessions/:id/transcript?agent_id=X&before=<first_line>&limit=50
  → history load (scroll to top)
```

JSONL messages are paginated by **line number** (not cursor/offset). `last_line` and `first_line` track the window.

### Polling Strategy

- **Primary trigger**: WS `new_event` (or any session/agent event) → `fetchNewMessages()`
- **Fallback poll**: `setInterval(3000ms)` — active only when the tab is visible (`document.visibilityState`). Closes gaps when WS misses hook fires (e.g., plain text turns between tool uses don't fire hooks).
- **Transcript list rescanned** every 15 seconds (so newly spawned subagents appear in the dropdown without page reload)
- **Coalescing**: If a fetch is in flight when a new trigger arrives, `pendingFetchRef` is set to true, and exactly one re-fetch runs after the in-flight request completes.

### TranscriptMessage Structure

```typescript
interface TranscriptMessage {
  type: "user" | "assistant";
  content: TranscriptContent[];
  timestamp?: string; // ISO8601
  model?: string;
}

interface TranscriptContent {
  type: "text" | "tool_use" | "tool_result" | "thinking" | "image";
  id?: string;        // tool_use id (for pairing with tool_result)
  text?: string;      // for type=text or type=thinking
  name?: string;      // tool name for type=tool_use
  input?: object;     // tool input for type=tool_use
  content?: string | TranscriptContent[]; // tool_result content
  is_error?: boolean; // tool_result error flag
}
```

### MessageList Rendering Logic

**Tool use/result pairing**: A pre-pass builds a `Map<string, TranscriptContent>` from tool_use id → tool_result. User messages that are purely `tool_result` (no text content) are skipped — they're rendered inside the preceding assistant message's `ToolCallBlock`.

**Message layout**:
- Left accent bar: indigo for assistant, amber for user
- Avatar: Bot icon (assistant) or User icon (user)
- User turn: tinted bubble (amber/accent background)
- Assistant turn: transparent, prose flows naturally

**Assistant message content rendering** (in order):

1. **Thinking blocks** (`type: "thinking"`): `ThinkingBlock` component
   - Indigo-tinted collapsible block
   - Header: Brain icon + "Thinking" label + char count (e.g., "2,341 chars")
   - Collapsed: shows first 500 chars of thinking text, "Show more" link
   - Expanded: full text in 600px max-height scrollable area
   - Renders thinking text via `MarkdownContent`

2. **Text blocks** (`type: "text"`): TUI segment detection → route through `parseTuiSegments`
   - **TUI segments** (when `hasTuiTags()` detects Claude CLI TUI markup):
     - `CommandPill`: green-tinted pill for slash command invocations (e.g., `/help`)
     - `TerminalBlock stdout`: dark terminal block for captured stdout
     - `TerminalBlock stderr`: red-tinted terminal block for stderr
     - `CaveatBlock`: amber info callout for limitation notices
     - `CollapsibleBlock (system-reminder)`: amber collapsible for system reminders
     - `CollapsibleBlock (persisted-output)`: indigo collapsible for persisted outputs
   - **Plain text**: `MarkdownContent` renderer

3. **Tool use blocks** (`type: "tool_use"`): `ToolCallBlock` component
   - Collapsible, header shows: tool icon (from `toolStyle.ts`) + tool name + one-line summary
   - Summary extracted from input: `file_path` / `path` / `command` / `pattern` / `query` / `url` / `description`
   - **Per-tool input rendering**:
     - `bash`: `CodeBlock` with `lang="bash"`, shows `command` + optional `description`
     - `write`: `CodeBlock` with inferred language from extension, shows `content`, filename as label
     - `edit` / `multiedit`: diff view (planned or implemented — ToolCallBlock.tsx handles this)
     - `read`: `CodeBlock` with inferred language, `file_path` as label
     - Others: JSON `CodeBlock` with full input object
   - **Paired result** (tool_result from toolResultMap): rendered inline below the input
     - Success: `CodeBlock` with `tone="success"` or plain text
     - Error: `CodeBlock` with `tone="danger"`, `is_error` flag
     - Truncated content: backend sends `{ _truncated: "..." }` → shown as truncated

4. **Image blocks** (`type: "image"`): Not fully implemented (renders a placeholder or base64 image if available)

### CodeBlock Component

Every code display goes through `CodeBlock.tsx`:
- Chrome bar: language pill (left) + optional filename + copy-to-clipboard button + line count (right)
- Syntax highlighting via `highlight.ts` (custom tokenizer — no external dependency)
- Line numbers in left gutter for ≥ 4 lines
- Default max-height: 24rem (scrollable)
- Tones: default | danger (red tint) | success (emerald tint)
- Copy button: shows checkmark for 2s after copy

Supported languages: JavaScript/TypeScript, Python, JSON, Bash/Shell, HTML, CSS, SQL, YAML, Diff.

### MarkdownContent Component

Custom CommonMark+GFM parser — no external library, no `dangerouslySetInnerHTML`:

**Block-level elements**:
- Fenced code blocks (``` or ~~~) with language tag → `CodeBlock`
- ATX headings H1–H6
- Ordered and unordered lists (with nesting, task list checkboxes)
- Blockquotes
- Horizontal rules
- GFM tables (with alignment: left/center/right)
- Paragraphs

**Inline elements** (in paragraphs, list items, headings):
- Inline code (backtick)
- Bold (`**text**`)
- Italic (`*text*` or `_text_`)
- Strikethrough (`~~text~~`)
- Links (`[text](url)`)
- Auto-linked URLs

**Dense prop**: When `dense={true}` (used in ThinkingBlock), reduces vertical spacing.

### Conversation Tab: Key UX Details

- **Scroll behavior**: Tracks `isAtBottomRef`. New messages appended → auto-scroll if user was at bottom. If user scrolled up → show floating "↓ New message" button.
- **Manual refresh button**: Spinner separate from skeleton loader (doesn't cause full re-render flash).
- **Load history**: "Load earlier messages" button at top of message list → fetches `before=first_line`.
- **Agent selector dropdown**: Shows all available transcripts (main agent + all subagents). Each transcript identified by agent_id.
- **Clicking an agent in the Agents tab**: Sets `pendingTranscriptId` in the parent, which flows down to `ConversationView` as `initialTranscriptId`.
- **Empty state**: "No conversation records found." for empty transcripts.

---

## 6. Dashboard Deep Dive

### Active Agents Section (Web)

The active agents section is the most critical real-time panel. It shows what Claude is doing right now.

**Data sources**:
- `GET /api/agents?status=working,waiting` — all currently active agents across all sessions
- Agent objects include: `id`, `name`, `type` (main/subagent), `subagent_type`, `status`, `current_tool`, `task`, `session_id`, `parent_agent_id`, `started_at`

**Tree construction**:
1. Filter agents by `type === "main"` → top-level nodes
2. For each main agent: find all agents with `parent_agent_id === main.id` → children
3. Orphaned subagents (no matching parent) → shown as top-level with special styling

**Expandable behavior**:
- Main agent rows have a chevron toggle to show/hide subagents
- Default: expanded
- Subagents indented with `border-l-2` left border (status-colored)
- Clicking either main or subagent row → navigates to `/sessions/${agent.session_id}`

**`AgentCard` content** (for each agent):
- Status dot (pulsing for working/waiting)
- Agent name or auto-derived label
- Subagent type badge (e.g., `claude-code-guide`, `maestro:backend-agent`)
- `current_tool` pill (e.g., `Bash`, `Write`) — shown when agent is mid-tool-call
- Task description (truncated, 2 lines)
- Status badge
- Time ago
- Parent session name (for subagents)

**Dynamic item count**: `ResizeObserver` on the panel → calculates how many agent rows fit → fetches that many. Prevents overflow without fixed heights.

**Empty state**: Bot icon + "No active agents" + "Sessions will appear here when Claude Code is running."

### Click Behavior (Web Dashboard)

| Element | Click action |
|---|---|
| Active agent row | Navigate to `/sessions/${agent.session_id}` |
| Recent activity event row | Navigate to `/sessions/${event.session_id}` |
| "View Board" button | Navigate to `/kanban` |
| Stat card | No navigation (cards are not clickable) |
| Health tab cards | No navigation (health info only) |

### Stat Cards (Web)

| Card | Value | Unit | Always / Gated |
|---|---|---|---|
| Total Sessions | `stats.total_sessions` | integer | Always |
| Active Agents | `stats.active_agents` | integer | Always |
| Active Subagents | `stats.active_subagents` | integer | Always |
| Events Today | `stats.events_today` | integer | Advanced metrics |
| Total Events | `stats.total_events` | integer | Advanced metrics |
| Total Cost | `pricing/cost.total_cost` | formatted $ | Advanced metrics |

The Total Cost card uses `GET /api/pricing/cost` (not `/api/stats`). It renders an animated count-up number.

### Recent Activity Feed (Web)

- Fetches last N events (N = dynamic based on height)
- Event row: colored type pill + tool name (monospace if tool call) + session name + time ago
- Rows are clickable links to the session
- WS `new_event` → prepend (no spinner, no full reload)
- "View all" link → navigates to `/activity`

### Swift Dashboard Differences

The current Swift `DashboardView` has:
- 4 stat cards: Active Sessions, Total Sessions, Active Agents, Total Cost (always shown, no gating)
- Recent Sessions list (8 sessions, SessionRow component)
- Live Feed (15 events, EventFeedRow component)
- No active agents tree
- No Health tab
- Live Feed rows are not clickable/navigable
- SessionRow in dashboard: does navigate to SessionDetailView via the sessions split view (unclear if direct navigation works)

---

## 7. Implementation Recommendations

Ordered by impact-to-effort ratio (highest first).

### 1. Fix WS-Triggered Refresh Flicker (P0, 1–2 hours)

The root cause is `AppState.refresh()` being called on every WS event. Replace with event-type-aware updates:

```
new_event         → append to recentEvents only; no sessions/stats reload
agent_updated     → patch agent in sessionDetailCache[session_id].agents
session_updated   → patch session in sessions array
agent_created     → append to sessionDetailCache[session_id].agents
session_created   → prepend to sessions array
stats_update      → update stats directly from WS payload
```

This alone eliminates the spinner flicker and makes the app feel live.

### 2. Collapsible Sidebar (P0, 30 minutes)

Change `NavigationSplitView(columnVisibility: .constant(.all))` to `@State private var columnVisibility`. Add a toolbar button or use the standard macOS sidebar toggle. Persist state to UserDefaults.

### 3. Global Search (P1, 4–6 hours)

Add a 5th nav item "Search" using a new `SearchView`. Wire up `GET /api/search?q=&limit=20`. Add Cmd+K shortcut. Show sessions and events grouped separately. Use `AttributedString` for highlight markup from the server.

### 4. Active Agents Tree on Dashboard (P1, 3–4 hours)

Add an "Active Agents" section above (or replacing) "Recent Sessions" on the Dashboard. Fetch from `GET /api/agents?status=working,waiting`. Build tree from `parent_agent_id`. Expand/collapse main agents with subagents indented using a VStack + padding approach.

### 5. Thinking Block Rendering in Conversation (P1, 2–3 hours)

If `ConversationTabView` doesn't already handle `type: "thinking"` content blocks, add a collapsible `ThinkingBlockView` styled in indigo. Show char count in collapsed header. Use a `DisclosureGroup` or custom toggle.

### 6. Dedicated Thinking Tab (P1, 2–3 hours)

Add a 6th tab to SessionDetailView: "Thinking". Fetch all transcripts, extract thinking blocks, render as a chronological list. Filter by agent dropdown. Each entry: timestamp, char count, collapsible content. "→ See context" could navigate to Conversation tab.

### 7. Event Filters on Events/Activity Tabs (P1, 3–4 hours)

Add filter state to `SessionEventsTab` and `ActivityFeedView`:
- Status preset buttons (All, Errors, Tool calls)
- Tool name text filter (search field)
- Apply filters as query params to `GET /api/sessions/:id/events?type=error&tool_name=Bash`

### 8. Kanban Board (P1, 4–6 hours)

New `KanbanView` with two modes (Agents / Sessions). Show columns by status. Use `LazyVGrid` with fixed columns. Each column: header with pulsing dot + count + `AgentCard`/`SessionCard`. No drag-and-drop needed (the web Kanban doesn't drag either — cards just stay in columns).

### 9. Session Inline Rename (P2, 2–3 hours)

In `SessionListRow` and `SessionDetailHeader`: double-click name → show `TextField`. On commit → `PATCH /api/sessions/:id` with `{ name }`. Update local state optimistically.

### 10. Analytics: Activity Heatmap (P2, 3–4 hours)

A 52-week heatmap using `Canvas` or `Path` drawing in SwiftUI. Each cell = 1 day, color = session count. Use `GET /api/analytics` which returns daily activity data. This is high visual impact for the Analytics tab.

### 11. Session Detail: Annotation (P2, 1 hour)

Per-session notes stored in `UserDefaults` keyed by `annotation-{sessionId}`. A collapsed card in the session header area. Tap to expand a `TextEditor`. Auto-save on focus loss.

### 12. Session Detail: Export (P2, 1 hour)

A toolbar button in `SessionDetailView` → `GET /api/export/session/:id` → save panel dialog (`NSSavePanel`) to save the JSON bundle.

### 13. Notifications (P3, 2–3 hours)

Request `UNUserNotificationCenter` authorization. Subscribe to WS events in AppState. When `session_updated` fires with `status = "completed"` or `status = "error"` → fire a local notification with the session name and status. Notification action → bring window to front + navigate to that session.

### 14. Menu Bar Extra (P3, 3–4 hours)

Add a `MenuBarExtra` to `PodiumApp.swift`. Content: active agent count + last 24h cost. Clicking opens a compact popover with the active agents list and a "Open Podium" button. Uses AppState which is already shared.

### 15. Run Claude (P1 effort = very high, 20+ hours)

This is the most complex feature — spawning Claude subprocesses, streaming via WS, rendering the conversation live with typewriter effect. Recommend scoping a v1 that is headless-only (one-shot prompt → watch stream → done) before attempting full multi-turn conversation mode.

---

## Appendix: API Endpoints Reference

| Endpoint | Method | Used By |
|---|---|---|
| `/api/health` | GET | Connectivity check |
| `/api/stats` | GET | Dashboard stat cards |
| `/api/sessions` | GET | Sessions list, Search fallback |
| `/api/sessions/:id` | GET | Session detail |
| `/api/sessions/:id` | PATCH | Inline rename |
| `/api/sessions/:id/stats` | GET | Session overview tab |
| `/api/sessions/:id/events` | GET | Timeline/Events tab |
| `/api/sessions/:id/transcript` | GET | Conversation tab |
| `/api/sessions/:id/transcripts` | GET | Transcript selector dropdown |
| `/api/agents` | GET | Active agents tree, Kanban |
| `/api/analytics` | GET | Analytics page |
| `/api/pricing/cost` | GET | Total cost card |
| `/api/pricing/cost/:id` | GET | Session cost breakdown |
| `/api/search` | GET | Global search |
| `/api/export/session/:id` | GET | Export/download session |
| `/api/import/session` | POST | Import session bundle |
| `/api/run` | POST | Start Claude subprocess |
| `/api/run/list` | GET | Active run handles |
| `/api/run/files` | GET | File autocomplete in Run |
| `/api/settings/export` | GET | Export all data |
| `/api/settings/cleanup` | POST | Session cleanup |
| `/api/cc/overview` | GET | CC Config overview |
| `/api/cc/skills` | GET | Skills list |
| `/api/cc/agents` | GET | Agents list |
| `/api/cc/commands` | GET | Commands list |
| `/api/cc/memory` | GET | Memory files list |
| `/api/cc/artifact` | POST/PUT/DELETE | Create/edit/delete CC artifacts |
| `/ws` | WS | All live updates |

**WS message types received** (from server):
- `session_created`, `session_updated`
- `agent_created`, `agent_updated`
- `new_event`
- `stats_update`
- `run_stream`, `run_status`
- `cc_config_changed`

---

## 8. Implementation Session — Technical Notes (2026-06-24)

This section documents the specific changes made in the first implementation sprint, for future reference and debugging.

### 8.1 WS Refresh Flicker Fix (`AppState.swift`)

**Problem**: `handleWSMessage` called `Task { await refreshStats() }` on `agent_created` and `agent_updated`, and some paths triggered a full `refresh()`. This caused the loading spinner to flash on every WebSocket message.

**Fix**: Each event type now does the minimum targeted update:

| WS Event | Before | After |
|---|---|---|
| `session_created` | upsertSession + refreshStats | upsertSession + refreshStats (unchanged) |
| `session_updated` | upsertSession + refreshStats | upsertSession only |
| `agent_created` | updateAgentInCache + refreshStats | updateAgentInCache + upsertActiveAgent |
| `agent_updated` | updateAgentInCache + refreshStats | updateAgentInCache + upsertActiveAgent |
| `new_event` | prepend to recentEvents | unchanged (already correct) |
| `stats_update` | update stats | unchanged (already correct) |

The `refreshStats()` private method is retained — it still fires on `session_created` since a new session meaningfully changes aggregate stats. The `stats_update` WS event is the primary mechanism for keeping stats current without polling.

**Key property added**: `var activeAgents: [Agent] = []`

**New methods**:
- `private func upsertActiveAgent(_ agent: Agent)` — inserts/updates if status is `.working`/`.waiting`; removes otherwise
- `func loadActiveAgents() async` — calls `api.agents(status: "working,waiting")`
- `start()` now calls `await loadActiveAgents()` after `await refresh()`

**New AppState property**: `var navigationRequest: NavDestination? = nil` — allows any view to trigger a sidebar navigation change. ContentView consumes it via `.onChange(of: state.navigationRequest)`.

---

### 8.2 Light/Dark Mode Support (`Theme.swift`, `ContentView.swift`)

**Problem**: `.preferredColorScheme(.dark)` in ContentView locked the app to dark mode. The 82% opacity gradient tint also blocked too much of the wallpaper.

**Changes**:

- Removed `.preferredColorScheme(.dark)` — app now respects system color scheme
- Added `Theme.lightBackgroundGradient` — soft lavender tones (rgb ~0.85/0.82/0.98)
- `ContentView` reads `@Environment(\.colorScheme)` and applies:
  - Dark: `darkBackgroundGradient` at **0.70** opacity (was 0.82)
  - Light: `lightBackgroundGradient` at **0.25** opacity (wallpaper shows through clearly)
- `GlassCardModifier` now reads `@Environment(\.colorScheme)`:
  - Dark: `.ultraThinMaterial` + white gradient border (1/5 opacity) + `shadow opacity: 0.30`
  - Light: `.regularMaterial` + black gradient border (1/10 opacity) + `shadow opacity: 0.12`

**Sidebar**: Changed `columnVisibility: .constant(.all)` to `@State private var columnVisibility` initialized from `UserDefaults("sidebar_visible")`. Persisted via `.onChange(of: columnVisibility)`. Standard macOS ⌘⌥S toggle now works.

---

### 8.3 Active Agents Tree on Dashboard (`DashboardView.swift`)

**What was added**: `ActiveAgentsSection` view shown in the left column when `state.activeAgents` is non-empty. Falls back to the original "Recent Sessions" list when there are no active agents.

**Tree structure**:
- Main agents (`agent.type == .main`) are top-level, expandable with disclosure triangle (default: expanded)
- Subagents grouped under parent by `parentAgentId`, indented 24pt with a 2px status-colored left border
- Orphaned subagents (no matching parent in list) shown as top-level

**Per-agent row** shows: pulsing StatusDot, name, task (2 lines), currentTool capsule badge, status badge, relative time.

**Tap action**: `state.selectedSessionId = agent.sessionId; state.navigationRequest = .sessions`

**Event feed rows**: now tappable → navigate to session. "View All" button at bottom sets `navigationRequest = .activityFeed`.

**Data refresh**: `.task` on appear calls `state.loadActiveAgents()`.

---

### 8.4 Thinking Blocks + Thinking Tab (`SessionDetailView.swift`)

**What was added**:

1. `ThinkingBlockView` (private struct) — collapsible indigo-styled block. Header shows brain icon + "Thinking" + char count. Expanding reveals scrollable text (capped 280pt).

2. In `MessageBubbleView` content block rendering: added `case "thinking"` branch → renders `ThinkingBlockView(text: block.text!)` for blocks where `type == "thinking"`.

3. `ThinkingTabView` (private struct) — new tab that fetches the transcript, extracts all `thinking` content blocks, and renders them as a chronological list with timestamps, model names, and char counts. Shows empty state if no thinking blocks.

4. `SessionTab` enum: added `case thinking = "Thinking"` between `.conversation` and `.cost`.

**API note**: `ThinkingTabView` calls `state.fetchTranscript(sessionId)` (no `before:` cursor → gets latest 50 messages). For sessions with long transcripts, the thinking tab shows only the most recent 50 messages' thinking blocks. Full pagination not implemented.

---

### 8.5 Remaining P0/P1/P3 Items Not Yet Implemented

| Item | Priority | Estimated effort |
|---|---|---|
| Global search (Cmd+K, `/api/search`) | P1 | 4–6 hours |
| Kanban Board | P1 | 6–8 hours |
| Run Claude in-app | P1 | 20+ hours |
| Event filters on Events/Activity tab | P1 | 3–4 hours |
| Session inline rename | P2 | 1–2 hours |
| Analytics: 52-week heatmap | P2 | 4–6 hours |
| Workflows DAG view | P2 | 8–10 hours |
| Native notifications (UNUserNotificationCenter) | P3 | 2–3 hours |
| Menu bar extra improvements | P3 | 2–3 hours |
| Spotlight indexing | P3 | 4–6 hours |
| Import session (drag .json) | P3 | 3–4 hours |
| Advanced metrics feature flag | P2 | 1–2 hours |

