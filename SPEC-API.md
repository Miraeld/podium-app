# PodiumSwiftApp — API Spec

All new API methods go in `PodiumAPI.swift`, following the existing pattern.

---

## New Models (Models.swift additions)

```swift
// MARK: - Events

struct EventsPage: Codable {
    let events: [DashboardEvent]
    let total: Int
    let hasMore: Bool
}

// MARK: - Workflows

struct WorkflowData: Codable {
    let nodes: [WorkflowNode]
    let edges: [WorkflowEdge]
    let metrics: WorkflowMetrics
}

struct WorkflowNode: Codable, Identifiable {
    let id: String          // agent id
    let label: String       // agent type or name
    let status: String
    let startedAt: Date?
    let endedAt: Date?
    let tokenCount: Int?
    let cost: Double?
    let depth: Int          // for tree layout fallback
}

struct WorkflowEdge: Codable, Identifiable {
    var id: String { "\(source)-\(target)" }
    let source: String
    let target: String
    let label: String?      // "spawned", "delegated", etc.
}

struct WorkflowMetrics: Codable {
    let totalAgents: Int
    let maxConcurrency: Int
    let totalTokens: Int
    let totalCost: Double
    let errorRate: Double
    let durationSeconds: Double
}

// MARK: - Run

struct RunSession: Codable, Identifiable {
    let id: String
    let prompt: String
    let workingDir: String
    let mode: RunMode
    let status: RunStatus
    let startedAt: Date
    let endedAt: Date?
    let cost: Double?
    let durationSeconds: Double?
}

enum RunMode: String, Codable { case conversation, oneShot }
enum RunStatus: String, Codable { case running, completed, failed, killed }

struct RunEvent: Codable, Identifiable {
    let id: String
    let runId: String
    let type: RunEventType
    let content: String
    let toolName: String?
    let createdAt: Date
}

enum RunEventType: String, Codable { case text, toolUse, toolResult, error }

struct RunResponse: Codable { let runId: String }

// MARK: - Search

struct SearchResults: Codable {
    let sessions: [Session]
    let agents: [Agent]
    let events: [DashboardEvent]
}

// MARK: - Pricing

struct PricingRule: Codable, Identifiable {
    let id: String
    let model: String
    let inputCostPerMillion: Double
    let outputCostPerMillion: Double
}

// MARK: - CC Config

struct CCConfig: Codable {
    let plugins: [CCPlugin]
    let skills: [CCSkill]
    let agents: [CCAgent]
    let mcpServers: [CCMCPServer]
    let keybindings: [CCKeybinding]
    let memoryFiles: [CCMemoryFile]
}

struct CCPlugin: Codable, Identifiable {
    let id: String
    let name: String
    let path: String
    let skillCount: Int
    let agentCount: Int
}

struct CCSkill: Codable, Identifiable {
    let id: String
    let name: String
    let description: String
    let triggerPhrase: String?
    let content: String
}

struct CCAgent: Codable, Identifiable {
    let id: String
    let name: String
    let description: String
    let tools: [String]
    let model: String?
}

struct CCMCPServer: Codable, Identifiable {
    let id: String
    let name: String
    let transport: String
    let tools: [String]
}

struct CCKeybinding: Codable, Identifiable {
    let id: String
    let key: String
    let command: String
}

struct CCMemoryFile: Codable, Identifiable {
    let id: String
    let name: String
    let path: String
    let content: String
    let type: String?
}

// MARK: - Import

struct ImportResult: Codable {
    let imported: Int
    let skipped: Int
    let errors: [String]
}

// MARK: - System Info

struct SystemInfo: Codable {
    let serverVersion: String
    let uptime: Double
    let dbSizeBytes: Int
    let sessionCount: Int
    let eventCount: Int
    let agentCount: Int
    let wsConnections: Int
    let memoryUsageMB: Double?
    let cpuPercent: Double?
}
```

---

## New PodiumAPI Methods

Add these methods to the `PodiumAPI` actor/struct:

```swift
// MARK: - Events

func events(
    limit: Int = 50,
    offset: Int = 0,
    type: String? = nil,
    sessionId: String? = nil
) async throws -> EventsPage

// MARK: - Workflows

func workflowData(sessionId: String) async throws -> WorkflowData

// MARK: - Run

func createRun(prompt: String, workingDir: String, mode: RunMode) async throws -> RunResponse
func sendRunMessage(runId: String, message: String) async throws
func killRun(runId: String) async throws
func listRuns() async throws -> [RunSession]

// MARK: - Search

func search(query: String, limit: Int = 20) async throws -> SearchResults

// MARK: - Pricing

func pricingRules() async throws -> [PricingRule]
func savePricingRules(_ rules: [PricingRule]) async throws

// MARK: - CC Config

func ccConfig() async throws -> CCConfig
func ccConfigCategory(_ category: String) async throws -> Data   // raw JSON, decode per-category

// MARK: - Import

func importSessions(fileURLs: [URL]) async throws -> ImportResult

// MARK: - System Info

func systemInfo() async throws -> SystemInfo
```

---

## WebSocket Events (new types)

Extend `AppState.handleWebSocketMessage()` to decode:

```swift
// Run streaming event
// { "type": "run_event", "runId": "...", "event": { "type": "text", "content": "..." } }

// Push notification event (server → client)
// { "type": "notification", "title": "...", "body": "...", "sessionId": "..." }
```

---

## URL Query Parameter Conventions

Follows the existing server patterns:

| Parameter | Type | Notes |
|---|---|---|
| `limit` | Int | Pagination size, default 50 |
| `offset` | Int | Pagination offset |
| `type` | String | Event type filter |
| `sessionId` | String | Scope to one session |
| `status` | String | Filter by status enum value |
| `q` | String | Full-text search query |
| `from` | ISO8601 String | Date range start |
| `to` | ISO8601 String | Date range end |

---

## Error Handling

All new methods follow the existing throw-on-non-2xx pattern in `PodiumAPI`.
Add one new error case:

```swift
enum PodiumError: Error {
    case serverError(Int, String)   // HTTP status + body
    case decodingError(Error)
    case networkError(Error)
    case runNotFound                // new: 404 on run endpoints
    case importFailed([String])     // new: import errors array
}
```
