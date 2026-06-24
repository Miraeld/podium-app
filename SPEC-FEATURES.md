# PodiumSwiftApp — Feature Specs

Each section describes a missing or extended feature with wireframe layout, behavior rules, and API dependencies.

---

## 1. Activity Feed (standalone)

**NavDestination:** `.activityFeed`  
**Keyboard shortcut:** ⌘4  
**Sidebar icon:** `waveform`

The dashboard shows only 15 events. This view shows the full paginated stream.

### Layout

```
┌─ Toolbar: [All Types ▼] [All Sessions ▼] [Date Range ▼]  [Search…] ─┐
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ [●] session_start  · 2s ago  · session-abc123                    │  │
│  │   "Project: wp-content/plugins/imagify"                          │  │
│  ├──────────────────────────────────────────────────────────────────┤  │
│  │ [⚡] tool_use  · 3s ago  · agent-xyz                             │  │
│  │   Bash: "git status"                                             │  │
│  ├──────────────────────────────────────────────────────────────────┤  │
│  │ [✓] agent_stop  · 5s ago  · agent-xyz                            │  │
│  ├──────────────────────────────────────────────────────────────────┤  │
│  │ Load more… (42 events remaining)                                 │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

### Behavior

- Loads 50 events at a time; "Load more" appends next page
- New events slide in at the top when WebSocket fires (same connection as AppState)
- Filters are additive (AND logic), reset individually
- Each row is expandable: tap → reveals full `data` JSON in a scrollable code block
- Filter pill row stays pinned at top on scroll (inside a `safeAreaInset`)

### Event type → color map

Reuse `EventFeedRow.eventColor` from DashboardView.

### API

```
GET /api/events?limit=50&offset=0&type=tool_use&sessionId=abc
```

---

## 2. Workflows

**NavDestination:** `.workflows`  
**Keyboard shortcut:** ⌘5  
**Sidebar icon:** `arrow.triangle.branch`

Visualises orchestration runs: which agents spawned which sub-agents, timing, errors.

### Layout (two-panel)

```
┌─ Left: Session picker ─────┬─ Right: Detail tabs ─────────────────────┐
│  [Search sessions…]         │  [DAG] [Timeline] [Metrics]              │
│  ─────────────────          │                                           │
│  ● session-abc  2m ago     │  DAG tab:                                 │
│    imagify · 3 agents      │  ┌───────────────────────────────────┐    │
│  ● session-def  5m ago     │  │  [orchestrator]                   │    │
│    wp-rocket · 1 agent     │  │       │ spawned                   │    │
│  ○ session-ghi  1h ago     │  │  [backend-agent]  [qa-engineer]   │    │
│    ...                      │  │       │ error                     │    │
│                             │  │  [lead-reviewer]                  │    │
│                             │  └───────────────────────────────────┘    │
│                             │                                           │
│                             │  Timeline tab:                            │
│                             │  [horizontal Gantt-style bars]            │
│                             │                                           │
│                             │  Metrics tab:                             │
│                             │  [cost, tokens, agent count stats]        │
└─────────────────────────────┴───────────────────────────────────────────┘
```

### DAG View

- Render using SwiftUI `Canvas` — draw nodes as rounded rectangles, edges as Bézier curves
- Nodes: colored by status (cyan=active, green=completed, red=error)
- Edges: animated dotted line while source agent is active
- Tap a node → opens the agent's event timeline in a popover
- Pinch to zoom (`MagnificationGesture`), drag to pan

### Timeline View

- Horizontal bars per agent, sorted by start time
- X-axis: relative seconds from session start
- Bar color = agent status
- Overlap shown correctly (parallel agents)

### Metrics View

Reuse `StatCard` grid:
- Total agents spawned
- Max concurrency
- Total tokens (input + output)
- Total cost
- Error rate %
- Duration

### API

```
POST /api/workflows/session/{id}    → WorkflowData model
```

---

## 3. Kanban Board

**NavDestination:** `.kanban`  
**Keyboard shortcut:** ⌘6  
**Sidebar icon:** `squares.below.rectangle`

Drag-and-drop columns for sessions or agents by status.

### Layout

```
┌─ Toggle: [Sessions] [Agents]  ──────────────────────────────────────────┐
│                                                                           │
│  ┌─ Active ───────┐  ┌─ Completed ────┐  ┌─ Error ────────┐  ┌─ Abnd ─┐ │
│  │                │  │                │  │                │  │        │ │
│  │  ┌──────────┐  │  │  ┌──────────┐  │  │  ┌──────────┐  │  │  ...   │ │
│  │  │ session  │  │  │  │ session  │  │  │  │ session  │  │  │        │ │
│  │  │ name     │  │  │  │ name     │  │  │  │ name     │  │  │        │ │
│  │  │ $0.12    │  │  │  │ $0.45    │  │  │  │ error    │  │  │        │ │
│  │  └──────────┘  │  │  └──────────┘  │  │  └──────────┘  │  │        │ │
│  │                │  │                │  │                │  │        │ │
│  └────────────────┘  └────────────────┘  └────────────────┘  └────────┘ │
└───────────────────────────────────────────────────────────────────────────┘
```

### Behavior

- Drag cards between columns using `dropDestination` / `draggable` (iOS 16+ / macOS 13+ API)
- Dropping a session into "Abandoned" calls `PATCH /api/sessions/{id}` with `{status: "abandoned"}`
- Dropping an agent only updates local state (agents are not manually status-changed via API)
- Columns scroll vertically independently
- Card tap → opens SessionDetailView / agent sub-panel
- Toggle persists to `UserDefaults("kanbanMode")`

### Card mini layout

```
┌─────────────────────────────┐
│  [●] Project name           │  ← status dot + last path component of cwd
│  started 5m ago             │
│  3 agents · $0.12           │
└─────────────────────────────┘
```

Use `.glassEffect()` for cards, column headers get a tinted glass panel.

---

## 4. Run (Spawn Claude Subprocess)

**NavDestination:** `.run`  
**Keyboard shortcut:** ⌘7  
**Sidebar icon:** `terminal`

Lets the user launch a Claude Code run from within Podium and watch it stream in real-time.

### Layout

```
┌─ Left: Run list ────────────┬─ Right: Active run ──────────────────────┐
│  [+ New Run]                │  Working directory: [/path/to/project ▼]  │
│  ─────────────────          │  Prompt:                                  │
│  ● Run #1  (active)         │  ┌──────────────────────────────────────┐ │
│    groom issue #42          │  │                                      │ │
│  ○ Run #2  (done)           │  │  Type your prompt here…              │ │
│    review PR                │  │                                      │ │
│                             │  └──────────────────────────────────────┘ │
│                             │  [▶ Run]   [One-shot] [Conversation]       │
│                             │  ─────────────────────────────────────────│
│                             │  Streaming output:                         │
│                             │  ┌──────────────────────────────────────┐ │
│                             │  │ [tool_use] Bash: git status          │ │
│                             │  │ [text] Analyzing changes…            │ │
│                             │  │ [tool_result] On branch main…        │ │
│                             │  └──────────────────────────────────────┘ │
│                             │  Cost: $0.003 · 1m 24s · [■ Stop]         │
└─────────────────────────────┴───────────────────────────────────────────┘
```

### Behavior

- Working directory picker: `NSOpenPanel` for folder selection
- Prompt: multiline `TextEditor` (not `TextField`)
- Mode: **Conversation** (multi-turn) vs **One-shot** (headless, `--print` flag)
- Run button → `POST /api/run` → receives `runId`
- Output streams via WebSocket messages with `type: "run_event"` and `runId`
- Each event is rendered as a typed row:
  - `text` → plain text block with markdown rendering
  - `tool_use` → colored badge + tool name + truncated input
  - `tool_result` → indented result block
  - `error` → red bordered block
- Stop button → `DELETE /api/run/{id}`
- Conversation mode: after run completes, input field re-enables for follow-up

### API

```
POST   /api/run                         → { runId }
POST   /api/run/{id}/message            (follow-up message)
DELETE /api/run/{id}                    (kill run)
GET    /api/run                         → [RunSummary]
```

WS events: `{ type: "run_event", runId, event: { type, content } }`

---

## 5. Global Search

**Trigger:** ⌘F (context-aware, ⌘Shift+F for global search panel)  
**Sidebar:** Search icon at bottom of nav, or keyboard only

### Behavior

- ⌘F within Sessions → filters that list (already handled by `searchable`)
- ⌘Shift+F → opens a floating search panel (not a modal, not a sheet — a floating window)
- Results grouped by type: Sessions, Agents, Events
- Arrow keys navigate results; Enter opens the item
- Escape dismisses

### Panel layout

```
┌──────────────────────────────────────────────────┐
│  🔍  Search Podium…                       [⎋]   │  ← .glassEffect() floating
├──────────────────────────────────────────────────┤
│  Sessions (3)                                    │
│    ○ imagify-plugin · 2h ago                     │
│    ○ wp-rocket · 3h ago                          │
│  ──────────────────────────────────────────────  │
│  Events (12)                                     │
│    ⚡ tool_use: Bash "git diff" · session-abc    │
│    ⚡ agent_start · session-def                  │
└──────────────────────────────────────────────────┘
```

This is a `NSPanel` (non-activating), or a SwiftUI `WindowGroup` with `.windowStyle(.plain)` and custom chrome.

### API

```
GET /api/search?q=imagify&limit=20
→ { sessions: [], agents: [], events: [] }
```

---

## 6. Settings (Extended)

**NavDestination:** `.settings` (existing, extend it)  
**Shortcut:** ⌘,

Extend the existing single-field SettingsView with tabbed sections.

### Tabs

#### Connection (existing content)
- Server URL field
- Test connection button
- Status indicator

#### Pricing Rules
- Table of model → cost per 1M tokens (input/output)
- Add / Edit / Delete rules inline
- "Reset to defaults" button
- Changes auto-saved, affect cost calculations immediately

```
Model                   Input $/1M   Output $/1M   [Edit]
claude-opus-4-8         $15.00       $75.00        [✎]
claude-sonnet-4-6       $3.00        $15.00        [✎]
claude-haiku-4-5        $0.25        $1.25         [✎]
[+ Add rule]
```

#### Notifications
- Toggle: enable macOS notifications (`UNUserNotificationCenter`)
- Notification triggers: session start, session complete, agent error, run complete
- Each trigger has an on/off toggle

#### System Info
- Server version, uptime
- Database: size, session count, event count, agent count
- WebSocket connections active
- Memory / CPU usage (if server exposes it)
- "Purge old sessions (> 30 days)" danger button

### API

```
GET  /api/settings/pricing         → [PricingRule]
POST /api/settings/pricing         (save all rules)
GET  /api/stats                    (existing, re-use for system info)
```

---

## 7. CC Config Explorer

**NavDestination:** `.ccConfig`  
**Sidebar icon:** `gearshape.2`  
**Section:** "Configure" (new sidebar section below "Observe")

Browse the Claude Code configuration loaded on the server machine.

### Layout (master-detail)

```
┌─ Categories ────────────────┬─ Detail ────────────────────────────────┐
│  Plugins (4)                │  Plugins                                 │
│  Skills (23)                │  ─────────────────────────────────────── │
│  Agents (18)                │  ● imagify-plugin                        │
│  MCP Servers (3)            │    path: ~/.claude/plugins/imagify        │
│  Keybindings (12)           │    skills: 8 · agents: 3                 │
│  Memory (5)                 │                                          │
│  Settings                   │  ● maestro                               │
│                             │    path: ~/.claude/plugins/maestro        │
│                             │    skills: 14 · agents: 12               │
└─────────────────────────────┴───────────────────────────────────────────┘
```

### Category views

- **Plugins** — list with skill/agent counts; expand → shows contained skills/agents
- **Skills** — list with description, trigger phrase; tap → shows full instruction
- **Agents** — list with description, tool list, model tier
- **MCP Servers** — name, transport, tools; read-only
- **Keybindings** — key → command table
- **Memory** — list of memory files; tap → shows content in a code block (read-only display)
- **Settings** — displays settings.json as formatted key-value pairs

All views are read-only (no editing in v1).

### API

```
GET /api/cc-config              → { plugins: [], skills: [], agents: [], mcpServers: [], ... }
GET /api/cc-config/plugins
GET /api/cc-config/skills
GET /api/cc-config/agents
GET /api/cc-config/memory
```

---

## 8. Menu Bar Status Item

**Always visible** even when main window is closed.

### Popover content

```
┌─────────────────────────────────────┐
│  Podium                ● Connected  │  ← .glassEffect(.regular.tint(.blue))
│  ───────────────────────────────────│
│  Active sessions:   3               │
│  Active agents:     7               │
│  Events today:      1,234           │
│  Total cost:        $2.14           │
│  ───────────────────────────────────│
│  Recent:                            │
│  ● imagify-plugin  working  2s ago  │
│  ● wp-rocket       done    14s ago  │
│  ───────────────────────────────────│
│  [Open Podium…]          [⚙ Prefs]  │
└─────────────────────────────────────┘
```

### Behavior

- Status item icon: `gauge.with.dots.needle.67percent`
- Icon badge (red dot with count) when `activeSessions > 0`
- Popover uses `.menuBarExtraStyle(.window)` for a native popover feel
- "Open Podium…" calls `NSApplication.shared.activate(ignoringOtherApps: true)`
- Data refreshes every 30s or on WebSocket events (shared `AppState`)

### Implementation note

`MenuBarExtra` (SwiftUI, macOS 13+) with `.menuBarExtraStyle(.window)` renders a popover attached to the status item. It shares the same `AppState` environment object as the main window.

---

## 9. Import Sessions

**NavDestination:** `.importSessions` (accessible from Settings or File menu)

### Layout

```
┌──────────────────────────────────────────────┐
│  Import Session History                       │
│                                              │
│  ┌──────────────────────────────────────┐   │
│  │                                      │   │
│  │  Drag & drop transcript files here   │   │
│  │       or [Choose Files…]             │   │
│  │                                      │   │
│  └──────────────────────────────────────┘   │
│                                              │
│  Selected: 3 files                           │
│  • session-abc123.jsonl                      │
│  • session-def456.jsonl                      │
│  • session-ghi789.jsonl                      │
│                                              │
│  [Import]     [Cancel]                       │
│                                              │
│  Progress: ████████░░  2/3                   │
└──────────────────────────────────────────────┘
```

### API

```
POST /api/import    multipart/form-data, files[] field
→ { imported: 3, skipped: 0, errors: [] }
```

---

## 10. Extended Session Detail

The existing `SessionDetailView` has three tabs (Overview, Agents, Events). Add:

### Tab 4: Conversation

Show the raw conversation transcript — the actual messages exchanged between the user and Claude:

- Alternating user / assistant bubbles
- Tool use blocks collapsed by default, expandable
- Markdown rendered in assistant messages (`AttributedString`)
- Code blocks in monospace with syntax coloring
- Scroll to bottom on load, auto-scroll disabled while reading up

### Tab 5: Cost Breakdown

More detailed than the existing cost row:

```
Model                  Calls   Input tokens   Output tokens   Cost
claude-opus-4-8        12      450,234        23,456          $0.89
claude-sonnet-4-6      4       120,000        8,900           $0.17
                               ─────────────────────────────────────
Total                  16      570,234        32,356          $1.06
```

Use a `Table` view (macOS-native sortable table).

---

## Priority Order

Implement in this order for maximum user impact:

1. Liquid Glass design system migration (Theme.swift, Components.swift)
2. Menu Bar Status Item (visible without launching main window)
3. Activity Feed standalone view
4. Global Search (⌘Shift+F)
5. Workflows DAG view
6. Settings extended (Pricing + Notifications + System Info)
7. Kanban Board
8. Run (spawn subprocess)
9. CC Config Explorer
10. Session Detail: Conversation + Cost Breakdown tabs
11. Import Sessions
