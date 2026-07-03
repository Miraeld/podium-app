// LegacyImporter.swift — port of dashboard/scripts/import-history.js: walks
// `~/.claude/projects/**.jsonl`, reconstructs sessions/agents/events/
// token_usage exactly like Node's `importSession` pipeline, and is safe to
// run repeatedly (idempotent per-session dedup + a per-event-type "high
// water mark" so a still-growing session only gains genuinely-new rows on a
// re-import).
//
// Deliberately independent of Transcripts/TranscriptCache (the mtime-cached
// parser hooks.js/the sweep use for LIVE ingestion) — matches the Node
// source, where import-history.js has always done its own single-pass JSONL
// scan rather than sharing lib/transcript-cache.js's cache. Two separate
// parsers for two separate call sites, exactly like Node.
//
// Every store mutation this file performs is a `PodiumStore+Import.swift`
// method or an existing `PodiumStore` method — no raw SQL lives here.
//
// Deviations from Node (documented, not silently dropped):
//   - `importAllSessions` is implemented as `importFromDirectory(rootDir:
//     ClaudeHome.projectsDir())` rather than a separately-structured
//     per-project-directory walk — behaviorally equivalent (same
//     classification, same per-session import, same subagent discovery)
//     and keeps one code path instead of two. `importAllSessions` has NO
//     coupling to the `.legacy-import.done` marker file (that lives in
//     `ServicesRunner`'s `LegacyImportService`, exactly like Node's
//     `autoImportLegacySessions` wraps but does not modify
//     `importAllSessions` itself) — callers that want an unconditional
//     re-scan (P3.3's reimport seam) call this directly.
//   - A parse failure (unreadable file, zero JSONL entries with a
//     timestamp) is counted as `skipped`, not `errors` — Node distinguishes
//     "parseSessionFile threw" (error) from "parseSessionFile returned
//     null" (skip); this port's `parseSessionFile` returns `nil` for both,
//     collapsing the distinction. `errors` is still incremented for
//     failures inside `importSession` itself (a thrown `SQLiteError`, etc).
//   - `/api/import/upload` (ImportRouter.swift) accepts raw `.jsonl` /
//     `.meta.json` multipart parts only — no zip/tar/tar.gz extraction
//     (Node's `lib/archive.js`). Out of scope for this task's "multipart
//     JSONL upload" spec; noted for a future task if archive upload is
//     wanted.
//   - Live progress broadcasts (`import.progress` at every scan/parse tick)
//     are collapsed to a single "complete" broadcast per operation.

import Foundation

public enum LegacyImporter {
    // MARK: - Public result types

    /// Aggregate counters returned by every import entry point — a superset
    /// of import-history.js's two distinct return shapes (`importAllSessions`
    /// returns `{imported, skipped, errors}`; `importFromDirectory` returns
    /// the fuller `{imported, skipped, backfilled, errors, sessionsSeen,
    /// filesScanned}`). Since this port unifies both onto one
    /// implementation, every caller gets the fuller shape.
    public struct ImportCounters: Equatable, Sendable {
        public var imported = 0
        public var skipped = 0
        public var backfilled = 0
        public var errors = 0
        public var sessionsSeen = 0
        public var filesScanned = 0
    }

    public struct SessionImportResult: Equatable, Sendable {
        public var skipped: Bool
        public var backfilled: Bool
    }

    public struct SubagentScanResult: Equatable, Sendable {
        public var imported: Int
        public var created: Int
    }

    /// `{imported}` == a body-less `JSON.stringify({imported: true})` —
    /// shared by every "no interesting per-event data" synthetic event.
    private static let importedDataJSON = "{\"imported\":true}"

    // MARK: - Parsed intermediate types (import-only; not part of the wire API)

    struct ToolUseEntry: Sendable {
        var name: String
        var timestamp: String?
        var input: JSONValue?
    }

    struct ApiError: Sendable {
        var type: String
        var message: String
        var timestamp: String?
    }

    struct ToolResultError: Sendable {
        var content: String
        var timestamp: String?
    }

    struct ToolEventEntry: Sendable {
        var toolUseId: String
        var toolName: String
        var toolInput: JSONValue?
        var preTimestamp: String?
        var toolResponse: JSONValue?
        var isError: Bool
        var postTimestamp: String?
    }

    struct ParsedSession: Sendable {
        var sessionId: String
        var name: String
        var cwd: String?
        var model: String?
        var version: String?
        var slug: String?
        var gitBranch: String?
        var startedAt: String
        var endedAt: String?
        var teams: [String]
        var userMessages: Int
        var assistantMessages: Int
        var tokensByModel: [String: TranscriptTokens]
        var messageTimestamps: [String]
        var toolUses: [ToolUseEntry]
        var compactions: [TranscriptCompactionEntry]
        var apiErrors: [ApiError]
        var fileModifiedAtMs: Double?
        var turnDurations: [TranscriptTurnDuration]
        var entrypoint: String?
        var permissionMode: String?
        var thinkingBlockCount: Int
        var toolResultErrors: [ToolResultError]
        var parsedSubagents: [ParsedSubagent] = []
        var sourcePath: String
    }

    struct ParsedSubagent: Sendable {
        var agentId: String
        var agentType: String?
        var description: String?
        var spawnToolUseId: String?
        var task: String?
        var model: String?
        var startedAt: String
        var endedAt: String
        var userMessages: Int
        var assistantMessages: Int
        var tokensByModel: [String: TranscriptTokens]
        var toolNames: [String]
        var thinkingBlockCount: Int
        var toolEvents: [ToolEventEntry]
    }

    // MARK: - Entry points

    /// Port of `importAllSessions(dbModule)` — walks `~/.claude/projects/`
    /// (via `ClaudeHome.projectsDir()`) and imports every session found.
    /// See the file-level doc comment for the "unified with
    /// importFromDirectory" deviation.
    @discardableResult
    public static func importAllSessions(store: PodiumStore) throws -> ImportCounters {
        try importFromDirectory(store: store, rootDir: ClaudeHome.projectsDir())
    }

    /// Port of `importFromDirectory(dbModule, rootDir, options)` — the
    /// generalized importer any directory (default projects dir, an
    /// arbitrary `scan-path`, or an `/upload` staging dir) funnels through.
    @discardableResult
    public static func importFromDirectory(store: PodiumStore, rootDir: String, snapshotTranscripts: Bool = true) throws -> ImportCounters {
        var counters = ImportCounters()
        guard isDirectoryPath(rootDir) else { return counters }

        let jsonlFiles = collectJsonlFiles(rootDir)
        counters.filesScanned = jsonlFiles.count

        var sessionFiles: [String] = []
        var standaloneSubagentFiles: [String] = []
        for file in jsonlFiles {
            if classifyJsonl(file) == .subagent {
                standaloneSubagentFiles.append(file)
            } else {
                sessionFiles.append(file)
            }
        }

        var parsedSessions: [ParsedSession] = []
        for file in sessionFiles {
            guard var session = parseSessionFile(file) else {
                counters.skipped += 1
                continue
            }
            let subPaths = findSessionSubagents(file)
            if !subPaths.isEmpty {
                session.parsedSubagents = subPaths.compactMap { parseSubagentFile($0) }
            }
            parsedSessions.append(session)
            counters.sessionsSeen += 1
        }

        for session in parsedSessions {
            do {
                let result = try importSession(store: store, session: session)
                if result.backfilled {
                    counters.backfilled += 1
                } else if result.skipped {
                    counters.skipped += 1
                } else {
                    counters.imported += 1
                }
            } catch {
                counters.errors += 1
            }
            if snapshotTranscripts {
                snapshotTranscript(sourcePath: session.sourcePath, sessionId: session.sessionId)
            }
        }

        // Orphan subagent JSONLs whose parent session lives outside this
        // batch (or was skipped) — try to attach them to a session that
        // already exists in the DB. Port of importFromDirectory's trailing
        // loop (import.js's two-candidate directory-layout probe).
        for subagentFile in standaloneSubagentFiles {
            guard let subData = parseSubagentFile(subagentFile) else { continue }
            guard let sessionId = resolveOrphanSubagentSessionId(subagentFile, store: store) else { continue }
            let mainAgentId = "\(sessionId)-main"
            do {
                if try importSubagentFromJsonl(store: store, sessionId: sessionId, mainAgentId: mainAgentId, sub: subData) > 0 {
                    counters.backfilled += 1
                }
            } catch {
                counters.errors += 1
            }
        }

        return counters
    }

    /// Port of `backfillCompactions(dbModule)` — scans EVERY session's JSONL
    /// (regardless of import status) for `isCompactSummary` entries and
    /// creates whatever compaction agents/events are missing.
    @discardableResult
    public static func backfillCompactions(store: PodiumStore) throws -> Int {
        let projectsDir = ClaudeHome.projectsDir()
        guard isDirectoryPath(projectsDir) else { return 0 }
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else { return 0 }

        var backfilled = 0
        for projDir in projectDirs {
            let projPath = (projectsDir as NSString).appendingPathComponent(projDir)
            guard isDirectoryPath(projPath) else { continue }
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: projPath) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                let sessionId = (file as NSString).deletingPathExtension
                guard let existing = try? store.getSession(id: sessionId), existing != nil else { continue }
                let filePath = (projPath as NSString).appendingPathComponent(file)
                let compactions = findCompactionsInFile(filePath)
                guard !compactions.isEmpty else { continue }
                let mainAgentId = "\(sessionId)-main"
                backfilled += (try? importCompactions(store: store, sessionId: sessionId, mainAgentId: mainAgentId, compactions: compactions)) ?? 0
            }
        }
        return backfilled
    }

    /// Port of `scanAndImportSubagents(dbModule, sessionId, transcriptPath)`
    /// — called from `HooksRouter` right after a `SubagentStop` hook event,
    /// fire-and-forget, so a subagent's own tool calls (never broadcast via
    /// hooks — they live only in its JSONL) show up without waiting for the
    /// periodic sweep.
    @discardableResult
    public static func scanAndImportSubagents(store: PodiumStore, sessionId: String, transcriptPath: String) throws -> SubagentScanResult {
        guard !sessionId.isEmpty, !transcriptPath.isEmpty else { return SubagentScanResult(imported: 0, created: 0) }
        let dir = (transcriptPath as NSString).deletingLastPathComponent
        let subDir = (((dir as NSString).appendingPathComponent(sessionId)) as NSString).appendingPathComponent("subagents")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: subDir) else {
            return SubagentScanResult(imported: 0, created: 0)
        }
        let subFiles = entries.filter { $0.hasSuffix(".jsonl") }
        guard !subFiles.isEmpty else { return SubagentScanResult(imported: 0, created: 0) }

        let mainAgentId = "\(sessionId)-main"
        var created = 0
        for file in subFiles {
            guard let subData = parseSubagentFile((subDir as NSString).appendingPathComponent(file)) else { continue }
            created += (try? importSubagentFromJsonl(store: store, sessionId: sessionId, mainAgentId: mainAgentId, sub: subData)) ?? 0
        }
        return SubagentScanResult(imported: subFiles.count, created: created)
    }

    // MARK: - importSession (the core pipeline)

    /// Port of `importSession(dbModule, session)`. New sessions are inserted
    /// wholesale; sessions already in the DB are only ever touched if they
    /// carry `metadata.imported === true` (never mutates a hook-tracked live
    /// session), and even then only genuinely-new rows are added, tracked
    /// via `PodiumStore.eventTypeCutoffs`'s per-event-type high-water mark.
    @discardableResult
    static func importSession(store: PodiumStore, session: ParsedSession) throws -> SessionImportResult {
        let mainAgentId = "\(session.sessionId)-main"

        if let existing = try store.getSession(id: session.sessionId) {
            return try backfillExistingSession(store: store, session: session, existing: existing, mainAgentId: mainAgentId)
        }
        try importNewSession(store: store, session: session, mainAgentId: mainAgentId)
        return SessionImportResult(skipped: false, backfilled: false)
    }

    private static func backfillExistingSession(
        store: PodiumStore, session: ParsedSession, existing: Session, mainAgentId: String
    ) throws -> SessionImportResult {
        let meta = decodeMetadata(existing.metadata)
        guard meta["imported"]?.asBool == true else {
            return SessionImportResult(skipped: true, backfilled: false)
        }

        var backfilled = false
        let cutoffs = try store.eventTypeCutoffs(sessionId: session.sessionId)
        func isNewer(_ type: String, _ ts: String?) -> Bool {
            guard let ts else { return false }
            guard let cutoff = cutoffs[type] else { return true }
            return ts > cutoff
        }

        if !session.messageTimestamps.isEmpty {
            var added = 0
            for ts in session.messageTimestamps where isNewer("Stop", ts) {
                try store.insertEventAt(
                    sessionId: session.sessionId, agentId: mainAgentId, eventType: "Stop", toolName: nil,
                    summary: "\(session.name) — response", data: importedDataJSON, createdAt: ts
                )
                added += 1
            }
            if added > 0 { backfilled = true }
        } else if cutoffs["Stop"] == nil {
            try store.insertEventAt(
                sessionId: session.sessionId, agentId: mainAgentId, eventType: "Stop", toolName: nil,
                summary: "Session: \(session.name) (\(session.userMessages) user / \(session.assistantMessages) assistant msgs)",
                data: importedDataJSON, createdAt: session.startedAt
            )
            backfilled = true
        }

        if !session.toolUses.isEmpty {
            var added = 0
            for tu in session.toolUses where isNewer("PostToolUse", tu.timestamp) {
                try store.insertEventAt(
                    sessionId: session.sessionId, agentId: mainAgentId, eventType: "PostToolUse", toolName: tu.name,
                    summary: "\(tu.name) (imported)", data: importedDataJSON, createdAt: tu.timestamp ?? session.startedAt
                )
                added += 1
            }
            if added > 0 { backfilled = true }
        }

        if try importCompactions(store: store, sessionId: session.sessionId, mainAgentId: mainAgentId, compactions: session.compactions) > 0 {
            backfilled = true
        }
        if try importSubagents(store: store, sessionId: session.sessionId, mainAgentId: mainAgentId, toolUses: session.toolUses) > 0 {
            backfilled = true
        }
        if try importApiErrors(store: store, sessionId: session.sessionId, mainAgentId: mainAgentId, apiErrors: session.apiErrors) > 0 {
            backfilled = true
        }
        for sub in session.parsedSubagents where try importSubagentFromJsonl(store: store, sessionId: session.sessionId, mainAgentId: mainAgentId, sub: sub) > 0 {
            backfilled = true
        }

        if !session.turnDurations.isEmpty {
            var added = 0
            for td in session.turnDurations {
                let ts = td.timestamp ?? session.startedAt
                guard isNewer("TurnDuration", ts) else { continue }
                try store.insertEventAt(
                    sessionId: session.sessionId, agentId: mainAgentId, eventType: "TurnDuration", toolName: nil,
                    summary: "Turn completed in \(formattedSeconds(td.durationMs))s",
                    data: turnDurationJSON(td), createdAt: ts
                )
                added += 1
            }
            if added > 0 { backfilled = true }
        }

        if !session.toolResultErrors.isEmpty {
            var added = 0
            for tre in session.toolResultErrors {
                let ts = tre.timestamp ?? session.startedAt
                guard isNewer("ToolError", ts) else { continue }
                try store.insertEventAt(
                    sessionId: session.sessionId, agentId: mainAgentId, eventType: "ToolError", toolName: nil,
                    summary: "Tool execution failed: \(String(tre.content.prefix(100)))",
                    data: toolResultErrorJSON(tre), createdAt: ts
                )
                added += 1
            }
            if added > 0 { backfilled = true }
        }

        if updateBackfilledMetadata(store: store, session: session, meta: meta) {
            backfilled = true
        }

        if let sessionEndedAt = session.endedAt, existing.status.knownValue != .active,
           (existing.endedAt == nil || sessionEndedAt > existing.endedAt!) {
            try store.setSessionEndedAt(id: session.sessionId, endedAt: sessionEndedAt)
            backfilled = true
        }

        let subagentTokensNonZero = session.parsedSubagents.contains { sub in
            sub.tokensByModel.values.contains { $0.inputTokens + $0.outputTokens + $0.cacheReadTokens + $0.cacheWriteTokens > 0 }
        }
        if subagentTokensNonZero,
           try writeSessionTokens(store: store, sessionId: session.sessionId, tokens: combineSessionTokens(session)) > 0 {
            backfilled = true
        }

        return SessionImportResult(skipped: !backfilled, backfilled: backfilled)
    }

    private static func updateBackfilledMetadata(store: PodiumStore, session: ParsedSession, meta: JSONValue) -> Bool {
        let metaChanged = (meta["user_messages"]?.asInt != session.userMessages)
            || (meta["assistant_messages"]?.asInt != session.assistantMessages)
            || (meta.nonEmptyString("entrypoint") == nil && (session.entrypoint != nil || !session.turnDurations.isEmpty))
        guard metaChanged else { return false }

        var newMeta = meta.objectValue ?? [:]
        newMeta["user_messages"] = .number(Double(session.userMessages))
        newMeta["assistant_messages"] = .number(Double(session.assistantMessages))
        newMeta["entrypoint"] = (meta.nonEmptyString("entrypoint") ?? session.entrypoint).map(JSONValue.string) ?? .null
        newMeta["permission_mode"] = (meta.nonEmptyString("permission_mode") ?? session.permissionMode).map(JSONValue.string) ?? .null
        newMeta["thinking_blocks"] = .number(Double(max(meta["thinking_blocks"]?.asInt ?? 0, session.thinkingBlockCount)))
        newMeta["turn_count"] = .number(Double(session.turnDurations.count))
        newMeta["total_turn_duration_ms"] = .number(Double(session.turnDurations.reduce(0) { $0 + $1.durationMs }))

        guard let metaJSON = jsonString(.object(newMeta)) else { return false }
        try? store.updateSession(id: session.sessionId, metadata: metaJSON)
        return true
    }

    private static func importNewSession(store: PodiumStore, session: ParsedSession, mainAgentId: String) throws {
        let recentThresholdMs: Double = 10 * 60 * 1000
        let isRecentlyActive = session.fileModifiedAtMs.map { Date().timeIntervalSince1970 * 1000 - $0 < recentThresholdMs } ?? false
        let sessionStatus: SessionStatus = isRecentlyActive ? .active : .completed
        let agentStatus: AgentStatus = isRecentlyActive ? .waiting : .completed

        let metaJSON = jsonString(.object([
            "version": session.version.map(JSONValue.string) ?? .null,
            "slug": session.slug.map(JSONValue.string) ?? .null,
            "git_branch": session.gitBranch.map(JSONValue.string) ?? .null,
            "user_messages": .number(Double(session.userMessages)),
            "assistant_messages": .number(Double(session.assistantMessages)),
            "imported": .bool(true),
            "entrypoint": session.entrypoint.map(JSONValue.string) ?? .null,
            "permission_mode": session.permissionMode.map(JSONValue.string) ?? .null,
            "thinking_blocks": .number(Double(session.thinkingBlockCount)),
            "turn_count": .number(Double(session.turnDurations.count)),
            "total_turn_duration_ms": .number(Double(session.turnDurations.reduce(0) { $0 + $1.durationMs })),
        ])) ?? "{}"

        try store.insertSession(id: session.sessionId, name: session.name, status: sessionStatus, cwd: session.cwd, model: session.model, metadata: metaJSON)
        try store.setSessionStartEnd(id: session.sessionId, startedAt: session.startedAt, endedAt: isRecentlyActive ? nil : session.endedAt)

        let agentLabel = "Main Agent — \(session.name)"
        try store.insertAgent(id: mainAgentId, sessionId: session.sessionId, name: agentLabel, type: .main, subagentType: nil, status: agentStatus, task: nil, parentAgentId: nil, metadata: nil)
        try store.setAgentStartEnd(id: mainAgentId, startedAt: session.startedAt, endedAt: isRecentlyActive ? nil : session.endedAt)

        for team in session.teams {
            let subId = "\(session.sessionId)-team-\(team)"
            try store.insertAgent(id: subId, sessionId: session.sessionId, name: team, type: .subagent, subagentType: "team", status: .completed, task: nil, parentAgentId: mainAgentId, metadata: nil)
            try store.setAgentStartEnd(id: subId, startedAt: session.startedAt, endedAt: session.endedAt)
        }

        if !session.messageTimestamps.isEmpty {
            for ts in session.messageTimestamps {
                try store.insertEventAt(sessionId: session.sessionId, agentId: mainAgentId, eventType: "Stop", toolName: nil, summary: "\(session.name) — response", data: importedDataJSON, createdAt: ts)
            }
        } else {
            try store.insertEventAt(
                sessionId: session.sessionId, agentId: mainAgentId, eventType: "Stop", toolName: nil,
                summary: "Session: \(session.name) (\(session.userMessages) user / \(session.assistantMessages) assistant msgs)",
                data: importedDataJSON, createdAt: session.startedAt
            )
            if let endedAt = session.endedAt, endedAt != session.startedAt {
                try store.insertEventAt(sessionId: session.sessionId, agentId: mainAgentId, eventType: "Stop", toolName: nil, summary: "Session ended: \(session.name)", data: importedDataJSON, createdAt: endedAt)
            }
        }

        for tu in session.toolUses {
            try store.insertEventAt(sessionId: session.sessionId, agentId: mainAgentId, eventType: "PostToolUse", toolName: tu.name, summary: "\(tu.name) (imported)", data: importedDataJSON, createdAt: tu.timestamp ?? session.startedAt)
        }

        try importCompactions(store: store, sessionId: session.sessionId, mainAgentId: mainAgentId, compactions: session.compactions)
        try importSubagents(store: store, sessionId: session.sessionId, mainAgentId: mainAgentId, toolUses: session.toolUses)
        try importApiErrors(store: store, sessionId: session.sessionId, mainAgentId: mainAgentId, apiErrors: session.apiErrors)

        for td in session.turnDurations {
            let ts = td.timestamp ?? session.startedAt
            try store.insertEventAt(sessionId: session.sessionId, agentId: mainAgentId, eventType: "TurnDuration", toolName: nil, summary: "Turn completed in \(formattedSeconds(td.durationMs))s", data: turnDurationJSON(td), createdAt: ts)
        }

        for tre in session.toolResultErrors {
            let ts = tre.timestamp ?? session.startedAt
            try store.insertEventAt(sessionId: session.sessionId, agentId: mainAgentId, eventType: "ToolError", toolName: nil, summary: "Tool execution failed: \(String(tre.content.prefix(100)))", data: toolResultErrorJSON(tre), createdAt: ts)
        }

        for sub in session.parsedSubagents {
            try importSubagentFromJsonl(store: store, sessionId: session.sessionId, mainAgentId: mainAgentId, sub: sub)
        }

        try writeSessionTokens(store: store, sessionId: session.sessionId, tokens: combineSessionTokens(session))
    }

    // MARK: - Compactions / Agent-tool subagents / API errors

    /// Port of `importCompactions` — dedup by `<sessionId>-compact-<uuid>`.
    @discardableResult
    static func importCompactions(store: PodiumStore, sessionId: String, mainAgentId: String, compactions: [TranscriptCompactionEntry]) throws -> Int {
        guard !compactions.isEmpty else { return 0 }
        var created = 0
        for (index, compaction) in compactions.enumerated() {
            guard let uuid = compaction.uuid, !uuid.isEmpty else { continue }
            let compactId = "\(sessionId)-compact-\(uuid)"
            guard try store.getAgent(id: compactId) == nil else { continue }

            let ts = compaction.timestamp ?? PodiumDate.now()
            try store.insertAgent(
                id: compactId, sessionId: sessionId, name: "Context Compaction", type: .subagent, subagentType: "compaction",
                status: .completed, task: "Automatic conversation context compression", parentAgentId: mainAgentId, metadata: nil
            )
            try store.setAgentStartEndUpdated(id: compactId, startedAt: ts, endedAt: ts, updatedAt: ts)

            let summary = "Context compacted — conversation history compressed (#\(index + 1))"
            let dataJSON = jsonString(.object([
                "uuid": .string(uuid), "timestamp": .string(ts),
                "compaction_number": .number(Double(index + 1)), "total_compactions": .number(Double(compactions.count)),
                "imported": .bool(true),
            ])) ?? "{}"
            try store.insertEventAt(sessionId: sessionId, agentId: compactId, eventType: "Compaction", toolName: nil, summary: summary, data: dataJSON, createdAt: ts)
            created += 1
        }
        return created
    }

    /// Port of `importSubagents` — subagents synthesized from `Agent`
    /// tool_use blocks found in the MAIN transcript (dedup by
    /// `<sessionId>-subagent-<index>`, where `index` counts only Agent
    /// tool_use blocks in file order — matches Node's `agentIndex`).
    @discardableResult
    static func importSubagents(store: PodiumStore, sessionId: String, mainAgentId: String, toolUses: [ToolUseEntry]) throws -> Int {
        guard !toolUses.isEmpty else { return 0 }
        var created = 0
        var agentIndex = 0
        for tu in toolUses {
            guard tu.name == "Agent", let input = tu.input else { continue }
            agentIndex += 1
            let subId = "\(sessionId)-subagent-\(agentIndex)"
            guard try store.getAgent(id: subId) == nil else { continue }

            let rawName: String
            if let description = input.nonEmptyString("description") {
                rawName = description
            } else if let subagentType = input.nonEmptyString("subagent_type") {
                rawName = subagentType
            } else if let prompt = input.nonEmptyString("prompt") {
                let firstLine = prompt.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? prompt
                rawName = String(firstLine.prefix(60))
            } else {
                rawName = "Subagent"
            }
            let subName = rawName.count > 60 ? String(rawName.prefix(57)) + "..." : rawName
            let ts = tu.timestamp ?? PodiumDate.now()

            try store.insertAgent(
                id: subId, sessionId: sessionId, name: subName, type: .subagent, subagentType: input.nonEmptyString("subagent_type"),
                status: .completed, task: input.nonEmptyString("prompt").map { String($0.prefix(500)) }, parentAgentId: mainAgentId, metadata: nil
            )
            try store.setAgentStartEndUpdated(id: subId, startedAt: ts, endedAt: ts, updatedAt: ts)

            let dataJSON = jsonString(.object([
                "imported": .bool(true),
                "subagent_type": input.nonEmptyString("subagent_type").map(JSONValue.string) ?? .null,
            ])) ?? "{}"
            try store.insertEventAt(sessionId: sessionId, agentId: subId, eventType: "PreToolUse", toolName: "Agent", summary: "Subagent spawned: \(subName) (imported)", data: dataJSON, createdAt: ts)
            created += 1
        }
        return created
    }

    /// Port of `importApiErrors` — dedup by `(session_id, event_type, summary)`.
    @discardableResult
    static func importApiErrors(store: PodiumStore, sessionId: String, mainAgentId: String, apiErrors: [ApiError]) throws -> Int {
        guard !apiErrors.isEmpty else { return 0 }
        var created = 0
        for err in apiErrors {
            let summary = "\(err.type): \(err.message)"
            let ts = err.timestamp ?? PodiumDate.now()
            guard try !store.eventSummaryExists(sessionId: sessionId, eventType: "APIError", summary: summary) else { continue }
            let dataJSON = jsonString(.object([
                "type": .string(err.type), "message": .string(err.message),
                "timestamp": err.timestamp.map(JSONValue.string) ?? .null,
            ])) ?? "{}"
            try store.insertEventAt(sessionId: sessionId, agentId: mainAgentId, eventType: "APIError", toolName: nil, summary: summary, data: dataJSON, createdAt: ts)
            created += 1
        }
        return created
    }

    // MARK: - Subagent JSONL import (matches into live rows, or creates a JSONL-keyed row)

    /// Port of `findLiveSubagentForJsonl`.
    static func findLiveSubagentForJsonl(store: PodiumStore, sessionId: String, sub: ParsedSubagent) throws -> String? {
        let excludePrefix = "\(sessionId)-jsonl-"
        if let toolUseId = sub.spawnToolUseId,
           let id = try store.liveSubagentIdBySpawnToolUseId(sessionId: sessionId, excludeIdPrefix: excludePrefix, toolUseId: toolUseId) {
            return id
        }
        guard let agentType = sub.agentType else { return nil }
        return try store.liveSubagentIdByTiming(sessionId: sessionId, subagentType: agentType, excludeIdPrefix: excludePrefix, startedAt: sub.startedAt, toleranceSeconds: 30)
    }

    /// Port of `importSubagentFromJsonl` — idempotent: re-running on an
    /// already-imported subagent backfills missing tool events without
    /// duplicating the agent row. If a live subagent (created via the
    /// PreToolUse "Agent" hook) matches, tool events land under ITS id;
    /// otherwise a `<sessionId>-jsonl-<agentId>` row is created.
    @discardableResult
    static func importSubagentFromJsonl(store: PodiumStore, sessionId: String, mainAgentId: String, sub: ParsedSubagent) throws -> Int {
        let jsonlSubId = "\(sessionId)-jsonl-\(sub.agentId)"
        let liveSubId = try findLiveSubagentForJsonl(store: store, sessionId: sessionId, sub: sub)
        let targetAgentId = liveSubId ?? jsonlSubId
        let existingJsonl = try store.getAgent(id: jsonlSubId)

        let subName = sub.agentType ?? "Subagent \(String(sub.agentId.prefix(8)))"
        var created = 0

        if liveSubId == nil, existingJsonl == nil {
            let metaJSON = jsonString(.object([
                "imported": .bool(true), "source": .string("jsonl"),
                "model": sub.model.map(JSONValue.string) ?? .null,
                "tools": .array(sub.toolNames.map(JSONValue.string)),
                "user_messages": .number(Double(sub.userMessages)),
                "assistant_messages": .number(Double(sub.assistantMessages)),
                "thinking_blocks": .number(Double(sub.thinkingBlockCount)),
            ])) ?? "{}"
            try store.insertAgent(id: jsonlSubId, sessionId: sessionId, name: subName, type: .subagent, subagentType: sub.agentType, status: .completed, task: sub.task, parentAgentId: mainAgentId, metadata: metaJSON)
            try store.setAgentStartEndUpdated(id: jsonlSubId, startedAt: sub.startedAt, endedAt: sub.endedAt, updatedAt: sub.endedAt)
            created += 1
        }

        if liveSubId == nil {
            let marker = "%\"subagent_id\":\"\(targetAgentId)\"%"
            if try !store.spawnEventExists(sessionId: sessionId, agentId: mainAgentId, dataLike: marker) {
                let dataJSON = jsonString(.object([
                    "imported": .bool(true),
                    "subagent_type": sub.agentType.map(JSONValue.string) ?? .null,
                    "subagent_id": .string(targetAgentId),
                    "source": .string("subagent_jsonl"),
                ])) ?? "{}"
                try store.insertEventAt(sessionId: sessionId, agentId: mainAgentId, eventType: "PreToolUse", toolName: "Agent", summary: "Subagent spawned: \(subName) (from JSONL)", data: dataJSON, createdAt: sub.startedAt)
                created += 1
            }
        }

        for tev in sub.toolEvents {
            guard !tev.toolUseId.isEmpty else { continue }
            let marker = "%\"tool_use_id\":\"\(tev.toolUseId)\"%"
            let preTs = tev.preTimestamp ?? sub.startedAt
            let truncatedInput = truncate(tev.toolInput)

            if try !store.eventDataLikeExists(agentId: targetAgentId, eventType: "PreToolUse", dataLike: marker) {
                let dataJSON = jsonString(.object([
                    "imported": .bool(true), "source": .string("subagent_jsonl"),
                    "tool_use_id": .string(tev.toolUseId), "tool_name": .string(tev.toolName),
                    "tool_input": truncatedInput ?? .null,
                ])) ?? "{}"
                try store.insertEventAt(sessionId: sessionId, agentId: targetAgentId, eventType: "PreToolUse", toolName: tev.toolName, summary: "Using tool: \(tev.toolName)", data: dataJSON, createdAt: preTs)
                created += 1
            }

            if let postTs = tev.postTimestamp, try !store.eventDataLikeExists(agentId: targetAgentId, eventType: "PostToolUse", dataLike: marker) {
                let dataJSON = jsonString(.object([
                    "imported": .bool(true), "source": .string("subagent_jsonl"),
                    "tool_use_id": .string(tev.toolUseId), "tool_name": .string(tev.toolName),
                    "tool_input": truncatedInput ?? .null,
                    "tool_response": truncate(tev.toolResponse) ?? .null,
                    "is_error": .bool(tev.isError),
                ])) ?? "{}"
                try store.insertEventAt(sessionId: sessionId, agentId: targetAgentId, eventType: "PostToolUse", toolName: tev.toolName, summary: "Tool completed: \(tev.toolName)", data: dataJSON, createdAt: postTs)
                created += 1
            }
        }

        return created
    }

    // MARK: - Token merge/write

    static func combineSessionTokens(_ session: ParsedSession) -> [String: TranscriptTokens] {
        var combined: [String: TranscriptTokens] = [:]
        func merge(_ source: [String: TranscriptTokens]) {
            for (model, tokens) in source {
                var existing = combined[model] ?? TranscriptTokens(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
                existing.inputTokens += tokens.inputTokens
                existing.outputTokens += tokens.outputTokens
                existing.cacheReadTokens += tokens.cacheReadTokens
                existing.cacheWriteTokens += tokens.cacheWriteTokens
                combined[model] = existing
            }
        }
        merge(session.tokensByModel)
        for sub in session.parsedSubagents { merge(sub.tokensByModel) }
        return combined
    }

    @discardableResult
    static func writeSessionTokens(store: PodiumStore, sessionId: String, tokens: [String: TranscriptTokens]) throws -> Int {
        var written = 0
        for (model, tok) in tokens {
            guard tok.inputTokens > 0 || tok.outputTokens > 0 || tok.cacheReadTokens > 0 || tok.cacheWriteTokens > 0 else { continue }
            try store.replaceTokenUsage(sessionId: sessionId, model: model, inputTokens: tok.inputTokens, outputTokens: tok.outputTokens, cacheReadTokens: tok.cacheReadTokens, cacheWriteTokens: tok.cacheWriteTokens)
            written += 1
        }
        return written
    }

    // MARK: - Directory walking

    enum JsonlKind { case session, subagent }

    /// Port of `classifyJsonl` — subagent JSONLs live under a `subagents/`
    /// folder (either directly, or as the file's grandparent).
    static func classifyJsonl(_ path: String) -> JsonlKind {
        let parentDir = (path as NSString).deletingLastPathComponent
        let parentName = (parentDir as NSString).lastPathComponent
        if parentName == "subagents" { return .subagent }
        let grandparentDir = (parentDir as NSString).deletingLastPathComponent
        if (grandparentDir as NSString).lastPathComponent == "subagents" { return .subagent }
        return .session
    }

    /// Port of `collectJsonlFiles` — recursive walk, symlinks followed.
    static func collectJsonlFiles(_ rootDir: String) -> [String] {
        var out: [String] = []
        var stack = [rootDir]
        var seen = Set<String>()
        while let dir = stack.popLast() {
            let key = (try? URL(fileURLWithPath: dir).resolvingSymlinksInPath().path) ?? dir
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in entries {
                let full = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    stack.append(full)
                } else if full.hasSuffix(".jsonl") {
                    out.append(full)
                }
            }
        }
        return out
    }

    /// Port of `findSessionSubagents` — probes both directory layouts Claude
    /// Code has used: `<dir>/<sessionId>/subagents/*.jsonl` (default) and
    /// `<dir>/subagents/<sessionId>/*.jsonl` (alternative).
    static func findSessionSubagents(_ sessionJsonlPath: String) -> [String] {
        let dir = (sessionJsonlPath as NSString).deletingLastPathComponent
        let sessionId = ((sessionJsonlPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let candidateDirs = [
            ((dir as NSString).appendingPathComponent(sessionId) as NSString).appendingPathComponent("subagents"),
            ((dir as NSString).appendingPathComponent("subagents") as NSString).appendingPathComponent(sessionId),
        ]
        var result: [String] = []
        for subDir in candidateDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: subDir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                result.append((subDir as NSString).appendingPathComponent(file))
            }
        }
        return result
    }

    /// For a standalone subagent JSONL whose parent session wasn't part of
    /// the current import batch, probe both directory-layout candidates
    /// (the segment before/after "subagents" in the path) against sessions
    /// already in the DB.
    private static func resolveOrphanSubagentSessionId(_ subagentFile: String, store: PodiumStore) -> String? {
        let parts = (subagentFile as NSString).pathComponents
        guard let idx = parts.lastIndex(of: "subagents") else { return nil }
        var candidates: [String] = []
        if idx - 1 >= 0 { candidates.append(parts[idx - 1]) }
        if idx + 1 < parts.count { candidates.append(parts[idx + 1]) }
        for candidate in candidates {
            if (try? store.getSession(id: candidate)) != nil, (try? store.getSession(id: candidate) ?? nil) != nil {
                return candidate
            }
        }
        return nil
    }

    /// Port of `findCompactionsInFile` — lightweight single-purpose scan
    /// used only by `backfillCompactions`.
    static func findCompactionsInFile(_ path: String) -> [TranscriptCompactionEntry] {
        guard let lines = readLines(path) else { return [] }
        var out: [TranscriptCompactionEntry] = []
        for lineData in lines {
            guard let entry = decodeLine(lineData) else { continue }
            if entry["isCompactSummary"]?.asBool == true {
                out.append(TranscriptCompactionEntry(uuid: entry.nonEmptyString("uuid"), timestamp: entry.string("timestamp")))
            }
        }
        return out
    }

    // MARK: - Transcript snapshotting (durable copy surviving Claude Code pruning)

    /// Port of `snapshotTranscript` — best-effort, non-fatal copy of a
    /// session's transcript (+ subagent transcripts) into
    /// `ClaudeHome.transcriptSnapshotDir()`, so the Conversation tab keeps
    /// working after Claude Code prunes the original.
    static func snapshotTranscript(sourcePath: String, sessionId: String) {
        let snapDir = ClaudeHome.transcriptSnapshotDir()
        let destMain = (snapDir as NSString).appendingPathComponent("\(sessionId).jsonl")
        if standardizedPath(sourcePath) != standardizedPath(destMain) {
            copyIfNewer(src: sourcePath, dest: destMain)
        }
        for subPath in findSessionSubagents(sourcePath) {
            let subagentsDir = ((snapDir as NSString).appendingPathComponent(sessionId) as NSString).appendingPathComponent("subagents")
            let destSub = (subagentsDir as NSString).appendingPathComponent((subPath as NSString).lastPathComponent)
            guard standardizedPath(subPath) != standardizedPath(destSub) else { continue }
            copyIfNewer(src: subPath, dest: destSub)
        }
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Copies `src` to `dest` only when `dest` is missing or smaller than
    /// `src` (source grew) — port of `copyIfNewer`.
    private static func copyIfNewer(src: String, dest: String) {
        let fm = FileManager.default
        guard let srcSize = (try? fm.attributesOfItem(atPath: src))?[.size] as? Int else { return }
        let destSize = (try? fm.attributesOfItem(atPath: dest))?[.size] as? Int ?? -1
        guard destSize < srcSize else { return }
        try? fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: dest)
        try? fm.copyItem(atPath: src, toPath: dest)
    }

    // MARK: - JSONL parsing

    /// Port of `parseSessionFile` — a single-pass scan of a session's
    /// top-level JSONL transcript, extracting everything `importSession`
    /// needs. Returns `nil` if the file is unreadable or has no entry with
    /// a timestamp (Node: `if (!firstTimestamp) return null`).
    static func parseSessionFile(_ path: String) -> ParsedSession? {
        guard let lines = readLines(path) else { return nil }

        var cwd: String?, model: String?, version: String?, slug: String?, gitBranch: String?
        var firstTimestamp: String?, lastTimestamp: String?
        var teams = Set<String>()
        var userMessageCount = 0, assistantMessageCount = 0
        var tokensByModel: [String: TranscriptTokens] = [:]
        var messageTimestamps: [String] = []
        var toolUses: [ToolUseEntry] = []
        var compactions: [TranscriptCompactionEntry] = []
        var apiErrors: [ApiError] = []
        var turnDurations: [TranscriptTurnDuration] = []
        var entrypoint: String?, permissionMode: String?
        var thinkingBlockCount = 0
        var toolResultErrors: [ToolResultError] = []

        for lineData in lines {
            guard let entry = decodeLine(lineData) else { continue }

            if entry["isCompactSummary"]?.asBool == true {
                compactions.append(TranscriptCompactionEntry(uuid: entry.nonEmptyString("uuid"), timestamp: entry.string("timestamp")))
            }

            if entry.string("type") == "system", entry.string("subtype") == "turn_duration",
               let durationMs = entry["durationMs"]?.asInt, durationMs != 0 {
                turnDurations.append(TranscriptTurnDuration(timestamp: isoTimestamp(entry["timestamp"]), durationMs: durationMs))
            }

            if entry["isApiErrorMessage"]?.asBool == true {
                let content = entry["message"]?["content"]?.asArray ?? []
                let errText = content.first?["text"]?.asString.map { String($0.prefix(500)) } ?? "Unknown error"
                apiErrors.append(ApiError(type: entry.nonEmptyString("error") ?? "unknown_error", message: errText, timestamp: isoTimestamp(entry["timestamp"])))
            }

            let rawMsg = entry["message"] ?? entry
            if rawMsg.string("type") == "error", let err = rawMsg["error"] {
                apiErrors.append(ApiError(
                    type: err.nonEmptyString("type") ?? "unknown_error",
                    message: err.nonEmptyString("message") ?? "Unknown API error",
                    timestamp: isoTimestamp(entry["timestamp"])
                ))
            }

            if cwd == nil, let v = entry.nonEmptyString("cwd") { cwd = v }
            if slug == nil, let v = entry.nonEmptyString("slug") { slug = v }
            if gitBranch == nil, let v = entry.nonEmptyString("gitBranch") { gitBranch = v }
            if version == nil, let v = entry.nonEmptyString("version") { version = v }
            if entrypoint == nil, let v = entry.nonEmptyString("entrypoint") { entrypoint = v }
            if permissionMode == nil, let v = entry.nonEmptyString("permissionMode") { permissionMode = v }

            let isoTs = isoTimestamp(entry["timestamp"])
            if let isoTs {
                if firstTimestamp == nil || isoTs < firstTimestamp! { firstTimestamp = isoTs }
                if lastTimestamp == nil || isoTs > lastTimestamp! { lastTimestamp = isoTs }
            }

            if let team = entry.nonEmptyString("teamName") { teams.insert(team) }

            if entry.string("type") == "user" {
                userMessageCount += 1
                if let toolUseResult = entry["toolUseResult"], toolUseResult.objectValue != nil, toolUseResult["is_error"]?.asBool == true {
                    let content: String
                    if let s = toolUseResult["content"]?.asString {
                        content = String(s.prefix(500))
                    } else if let c = toolUseResult["content"] {
                        content = String((jsonString(c) ?? "").prefix(500))
                    } else {
                        content = ""
                    }
                    toolResultErrors.append(ToolResultError(content: content, timestamp: isoTs))
                }
            }

            if entry.string("type") == "assistant" {
                assistantMessageCount += 1
                if let isoTs { messageTimestamps.append(isoTs) }
                let msg = entry["message"] ?? .null
                let msgModel = msg.nonEmptyString("model")
                if model == nil, let msgModel, msgModel != "<synthetic>" { model = msgModel }
                if let msgModel, msgModel != "<synthetic>", let usage = msg["usage"] {
                    accumulateTokens(&tokensByModel, model: msgModel, usage: usage)
                }
                if let content = msg["content"]?.asArray {
                    for block in content {
                        if block.string("type") == "tool_use", let name = block.nonEmptyString("name") {
                            toolUses.append(ToolUseEntry(name: name, timestamp: isoTs ?? firstTimestamp, input: block["input"]))
                        }
                        if block.string("type") == "thinking" { thinkingBlockCount += 1 }
                    }
                }
            }
        }

        guard let firstTimestamp else { return nil }

        let sessionId = (path as NSString).lastPathComponent.hasSuffix(".jsonl")
            ? String((path as NSString).lastPathComponent.dropLast(6))
            : (path as NSString).lastPathComponent
        let projectName = cwd.map { ($0 as NSString).lastPathComponent } ?? slug ?? "Session \(sessionId.prefix(8))"
        let name = slug.map { "\(projectName) (\($0))" } ?? "\(projectName) - \(sessionId.prefix(8))"

        var fileModifiedAtMs: Double?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path), let mtime = attrs[.modificationDate] as? Date {
            fileModifiedAtMs = mtime.timeIntervalSince1970 * 1000
        }

        return ParsedSession(
            sessionId: sessionId, name: name, cwd: cwd, model: model, version: version, slug: slug, gitBranch: gitBranch,
            startedAt: firstTimestamp, endedAt: lastTimestamp, teams: Array(teams), userMessages: userMessageCount,
            assistantMessages: assistantMessageCount, tokensByModel: tokensByModel, messageTimestamps: messageTimestamps,
            toolUses: toolUses, compactions: compactions, apiErrors: apiErrors, fileModifiedAtMs: fileModifiedAtMs,
            turnDurations: turnDurations, entrypoint: entrypoint, permissionMode: permissionMode,
            thinkingBlockCount: thinkingBlockCount, toolResultErrors: toolResultErrors, parsedSubagents: [], sourcePath: path
        )
    }

    /// Port of `parseSubagentFile`. Returns `nil` if unreadable / no entry
    /// with a timestamp.
    static func parseSubagentFile(_ path: String) -> ParsedSubagent? {
        guard let lines = readLines(path) else { return nil }
        let baseName = (path as NSString).lastPathComponent.hasSuffix(".jsonl")
            ? String((path as NSString).lastPathComponent.dropLast(6))
            : (path as NSString).lastPathComponent
        let agentId = baseName.hasPrefix("agent-") ? String(baseName.dropFirst(6)) : baseName

        var task: String?, model: String?
        var firstTimestamp: String?, lastTimestamp: String?
        var userMessageCount = 0, assistantMessageCount = 0
        var tokensByModel: [String: TranscriptTokens] = [:]
        var toolNames = Set<String>()
        var thinkingBlockCount = 0
        var toolCalls: [(id: String, name: String, input: JSONValue?, timestamp: String?)] = []
        var toolResults: [String: (content: JSONValue?, isError: Bool, timestamp: String?)] = [:]

        for lineData in lines {
            guard let entry = decodeLine(lineData) else { continue }
            let isoTs = isoTimestamp(entry["timestamp"])
            if let isoTs {
                if firstTimestamp == nil || isoTs < firstTimestamp! { firstTimestamp = isoTs }
                if lastTimestamp == nil || isoTs > lastTimestamp! { lastTimestamp = isoTs }
            }

            if entry.string("type") == "user" {
                userMessageCount += 1
                let msgContent = entry["message"]?["content"]
                if task == nil {
                    if let s = msgContent?.asString {
                        task = String(s.prefix(500))
                    } else if let arr = msgContent?.asArray, let textBlock = arr.first(where: { $0.string("type") == "text" }) {
                        task = String((textBlock.nonEmptyString("text") ?? "").prefix(500))
                    }
                }
                if let arr = msgContent?.asArray {
                    for block in arr where block.string("type") == "tool_result" {
                        if let toolUseId = block.nonEmptyString("tool_use_id") {
                            toolResults[toolUseId] = (content: block["content"], isError: block["is_error"]?.asBool ?? false, timestamp: isoTs)
                        }
                    }
                }
            }

            if entry.string("type") == "assistant" {
                assistantMessageCount += 1
                let msg = entry["message"] ?? .null
                let msgModel = msg.nonEmptyString("model")
                if model == nil, let msgModel, msgModel != "<synthetic>" { model = msgModel }
                if let msgModel, msgModel != "<synthetic>", let usage = msg["usage"] {
                    accumulateTokens(&tokensByModel, model: msgModel, usage: usage)
                }
                if let content = msg["content"]?.asArray {
                    for block in content {
                        if block.string("type") == "tool_use", let name = block.nonEmptyString("name") {
                            toolNames.insert(name)
                            if let id = block.nonEmptyString("id") {
                                toolCalls.append((id: id, name: name, input: block["input"], timestamp: isoTs))
                            }
                        }
                        if block.string("type") == "thinking" { thinkingBlockCount += 1 }
                    }
                }
            }
        }

        guard let firstTimestamp else { return nil }

        let toolEvents: [ToolEventEntry] = toolCalls.map { call in
            let result = toolResults[call.id]
            return ToolEventEntry(
                toolUseId: call.id, toolName: call.name, toolInput: call.input, preTimestamp: call.timestamp,
                toolResponse: result?.content, isError: result?.isError ?? false, postTimestamp: result?.timestamp
            )
        }

        var agentType: String?, spawnToolUseId: String?, description: String?
        let metaPath = path.hasSuffix(".jsonl") ? String(path.dropLast(6)) + ".meta.json" : path + ".meta.json"
        if let metaData = try? Data(contentsOf: URL(fileURLWithPath: metaPath)),
           let meta = try? JSONDecoder().decode(JSONValue.self, from: metaData) {
            agentType = meta.nonEmptyString("agentType")
            spawnToolUseId = meta.nonEmptyString("toolUseId")
            description = meta.nonEmptyString("description")
        }

        return ParsedSubagent(
            agentId: agentId, agentType: agentType, description: description, spawnToolUseId: spawnToolUseId, task: task,
            model: model, startedAt: firstTimestamp, endedAt: lastTimestamp ?? firstTimestamp, userMessages: userMessageCount,
            assistantMessages: assistantMessageCount, tokensByModel: tokensByModel, toolNames: Array(toolNames),
            thinkingBlockCount: thinkingBlockCount, toolEvents: toolEvents
        )
    }

    private static func accumulateTokens(_ tokensByModel: inout [String: TranscriptTokens], model: String, usage: JSONValue) {
        var tokens = tokensByModel[model] ?? TranscriptTokens(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
        tokens.inputTokens += usage["input_tokens"]?.asInt ?? 0
        tokens.outputTokens += usage["output_tokens"]?.asInt ?? 0
        tokens.cacheReadTokens += usage["cache_read_input_tokens"]?.asInt ?? 0
        tokens.cacheWriteTokens += usage["cache_creation_input_tokens"]?.asInt ?? 0
        tokensByModel[model] = tokens
    }

    // MARK: - Small shared helpers

    /// `entry.timestamp` where the value may be a numeric epoch-ms (Node:
    /// `typeof ts === "number" ? new Date(ts).toISOString() : ts`) or
    /// already an ISO string.
    private static func isoTimestamp(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .number(let ms): return PodiumDate.format(Date(timeIntervalSince1970: ms / 1000))
        case .string(let s): return s
        default: return nil
        }
    }

    private static func decodeMetadata(_ raw: String?) -> JSONValue {
        guard let raw, let data = raw.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .object([:])
        }
        return value
    }

    private static func jsonString(_ value: JSONValue) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func turnDurationJSON(_ td: TranscriptTurnDuration) -> String {
        jsonString(.object(["durationMs": .number(Double(td.durationMs)), "imported": .bool(true)])) ?? "{}"
    }

    private static func toolResultErrorJSON(_ tre: ToolResultError) -> String {
        jsonString(.object([
            "content": .string(tre.content), "timestamp": tre.timestamp.map(JSONValue.string) ?? .null, "imported": .bool(true),
        ])) ?? "{}"
    }

    private static func formattedSeconds(_ durationMs: Int) -> String {
        String(format: "%.1f", Double(durationMs) / 1000)
    }

    /// Caps a JSON-serializable value at 50 000 chars, matching
    /// `truncateForEvent` — subagent tool_response payloads (file contents,
    /// command stdout) can run into hundreds of KB.
    private static let subagentEventValueCap = 50_000
    private static func truncate(_ value: JSONValue?) -> JSONValue? {
        guard let value else { return value }
        if case .string(let s) = value {
            guard s.count > subagentEventValueCap else { return value }
            return .string(String(s.prefix(subagentEventValueCap)) + "\n…[truncated]")
        }
        guard let serialized = jsonString(value) else { return nil }
        guard serialized.count > subagentEventValueCap else { return value }
        return .object([
            "_truncated": .bool(true),
            "_original_length": .number(Double(serialized.count)),
            "preview": .string(String(serialized.prefix(subagentEventValueCap))),
        ])
    }

    private static func isDirectoryPath(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Reads a JSONL file into raw per-line `Data` (split on `\n`), ready
    /// for `decodeLine`. Returns `nil` if the file can't be read at all.
    private static func readLines(_ path: String) -> [Data]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        var lines: [Data] = []
        var start = data.startIndex
        for index in data.indices where data[index] == 0x0A {
            if index > start { lines.append(data.subdata(in: start..<index)) }
            start = data.index(after: index)
        }
        if start < data.endIndex { lines.append(data.subdata(in: start..<data.endIndex)) }
        return lines
    }

    /// Decodes one JSONL line, stripping a trailing `\r` (CRLF transcripts)
    /// and skipping blank/malformed lines exactly like Node's
    /// `if (!line.trim()) continue; try { JSON.parse(line) } catch { continue }`.
    private static func decodeLine(_ lineData: Data) -> JSONValue? {
        var bytes = lineData
        if bytes.last == 0x0D { bytes.removeLast() }
        guard !bytes.isEmpty else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: bytes)
    }
}
