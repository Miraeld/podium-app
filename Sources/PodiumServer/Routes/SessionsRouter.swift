// SessionsRouter — port of dashboard/server/routes/sessions.js.
//
// Endpoints: GET / · GET /facets · GET /:id · GET /:id/stats · POST / ·
// PATCH /:id · GET /:id/transcripts · GET /:id/transcript.
//
// `/:id/transcripts` (listing, sessions.js lines 300–489) and
// `/:id/transcript` (JSONL parse + pagination, lines 491–761) landed in P3.1
// — see PodiumCore/Discovery/ClaudeHome.swift (path resolution, port of
// lib/claude-home.js) and PodiumCore/Transcripts/TranscriptMessageParser.swift
// (JSONL → message parsing/pagination). Both were previously 501 stubs
// pending that work.
//
// SQL/filter logic lives in PodiumCore/Database/PodiumStore+Filters.swift
// (`SessionFilter`, `listSessionsFiltered`, `countSessions`,
// `sessionCwdFacets`) — this file is HTTP mapping only.

import Foundation
import Hummingbird
import PodiumCore

public enum SessionsRouterMount: RouterMount {
    public static func mount(on router: PodiumRouter, context: ServerContext) {
        let group = router.group("/api/sessions")

        group.get { req, ctx in try await list(req, ctx, context: context) }
        group.get("/facets") { req, ctx in try await facets(req, ctx, context: context) }
        group.get("/:id") { req, ctx in try await detail(req, ctx, context: context) }
        group.get("/:id/stats") { req, ctx in try await stats(req, ctx, context: context) }
        group.get("/:id/transcripts") { req, ctx in try await transcripts(req, ctx, context: context) }
        group.get("/:id/transcript") { req, ctx in try await transcript(req, ctx, context: context) }
        group.post { req, ctx in try await create(req, ctx, context: context) }
        group.patch("/:id") { req, ctx in try await patch(req, ctx, context: context) }
    }

    // MARK: - GET /

    /// sessions.js lines 43–171: dynamic-WHERE list with search/status/cwd
    /// filters, three sort modes (`time` default, `duration`, `price`), and
    /// per-row cost attached from `token_usage` + `model_pricing`.
    private static func list(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let limit = min(req.uri.queryInt("limit", fallback: 50), 10000)
        let offset = req.uri.queryInt("offset", fallback: 0, min: 0)
        let filter = PodiumStore.SessionFilter(
            q: req.uri.queryTrimmed("q"),
            status: req.uri.queryValue("status"),
            cwd: req.uri.queryValue("cwd"),
            sortBy: req.uri.queryValue("sort_by") ?? "time",
            sortDesc: req.uri.queryValue("sort_desc") != "false"
        )

        let total = try context.store.countSessions(matching: filter)
        let sessions = try context.store.listSessionsFiltered(matching: filter, limit: limit, offset: offset)

        return try JSONResponse(SessionsResponse(sessions: sessions, total: total, limit: limit, offset: offset))
    }

    // MARK: - GET /facets

    private static func facets(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let cwds = try context.store.sessionCwdFacets()
        return try JSONResponse(SessionFacets(cwds: cwds))
    }

    // MARK: - GET /:id

    private static func detail(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let id = try ctx.parameters.require("id")
        guard let session = try context.store.getSession(id: id) else {
            return try JSONResponse(status: .notFound, CodedErrorResponse(code: "NOT_FOUND", message: "Session not found"))
        }
        let agents = try context.store.listAgentsBySession(sessionId: id)
        let events = try context.store.listEventsBySession(sessionId: id)
        return try JSONResponse(SessionDetailResponse(session: session, agents: agents, events: events))
    }

    // MARK: - GET /:id/stats

    /// sessions.js lines 196–253: aggregated counts for the SessionOverview
    /// panel, all computed in SQL.
    private static func stats(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let id = try ctx.parameters.require("id")
        guard try context.store.getSession(id: id) != nil else {
            return try JSONResponse(status: .notFound, CodedErrorResponse(code: "NOT_FOUND", message: "Session not found"))
        }

        let store = context.store
        let totalEvents = try store.sessionEventCount(sessionId: id)
        let eventsByType = try store.sessionEventTypeCounts(sessionId: id)
            .map { SessionStats.EventTypeCount(eventType: $0.eventType, count: $0.count) }
        let tools = try store.sessionToolUsageCounts(sessionId: id)
            .map { SessionStats.ToolCount(toolName: $0.toolName, count: $0.count) }
        let errors = try store.sessionErrorCount(sessionId: id)
        let timeRange = try store.sessionEventTimeRange(sessionId: id)
        let subagentTypeRows = try store.sessionAgentTypeCounts(sessionId: id)
        let agentStatusRows = try store.sessionAgentStatusCounts(sessionId: id)
        let tokenTotals = try store.sessionTokenTotals(sessionId: id)

        // Aggregate agent counts by category (sessions.js lines 218–239).
        var byStatus: [String: Int] = [:]
        var total = 0
        for row in agentStatusRows {
            total += row.count
            byStatus[row.status] = row.count
        }
        let compactionCount = subagentTypeRows.first { $0.subagentType == "compaction" }?.count ?? 0
        let mainSubCounts = try store.sessionAgentTypeCountsByType(sessionId: id)
        let mainCount = mainSubCounts["main"] ?? 0
        let subagentCount = mainSubCounts["subagent"] ?? 0

        let agentCounts = SessionStats.AgentCounts(
            total: total, main: mainCount, subagent: subagentCount, compaction: compactionCount, byStatus: byStatus
        )
        let subagentTypes = subagentTypeRows
            .filter { $0.subagentType != "compaction" }
            .map { SessionStats.SubagentTypeCount(subagentType: $0.subagentType, count: $0.count) }

        let sessionStats = SessionStats(
            sessionId: id,
            totalEvents: totalEvents,
            eventsByType: eventsByType,
            toolsUsed: tools,
            errorCount: errors,
            firstEventAt: timeRange.firstAt,
            lastEventAt: timeRange.lastAt,
            agents: agentCounts,
            subagentTypes: subagentTypes,
            tokens: SessionStats.TokenCounts(
                inputTokens: tokenTotals.totalInput,
                outputTokens: tokenTotals.totalOutput,
                cacheReadTokens: tokenTotals.totalCacheRead,
                cacheWriteTokens: tokenTotals.totalCacheWrite
            )
        )
        return try JSONResponse(sessionStats)
    }

    // MARK: - GET /:id/transcripts

    /// sessions.js lines 300–489: lists the main transcript plus every
    /// sub-agent/compaction JSONL file under `~/.claude/projects/**` for this
    /// session, best-effort-matched to `agents` rows by (subagent_type, time
    /// order within that group).
    private static func transcripts(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let id = try ctx.parameters.require("id")
        guard let session = try context.store.getSession(id: id) else {
            return try JSONResponse(status: .notFound, CodedErrorResponse(code: "NOT_FOUND", message: "Session not found"))
        }

        let dbAgents = try context.store.listAgentsBySession(sessionId: id)
        var mainEntry: TranscriptInfo?

        let mainPath = ClaudeHome.transcriptPath(sessionId: id, cwd: session.cwd)
            ?? ClaudeHome.findTranscriptPath(sessionId: id)
            ?? ClaudeHome.snapshotTranscriptPath(sessionId: id)
        if let mainPath, FileManager.default.fileExists(atPath: mainPath) {
            let mainAgent = dbAgents.first { $0.type.knownValue == .main }
            mainEntry = TranscriptInfo(id: "main", name: "Main Agent", type: "main", hasTranscript: true, dbAgentId: mainAgent?.id)
        }

        // Sub-agent transcript files: direct cwd-derived subagents dir, else
        // scan every project directory for `<dir>/<sessionId>/subagents`.
        var subagentDirs: [String] = []
        if let cwd = session.cwd, !cwd.isEmpty {
            let encoded = ClaudeHome.encodeCwd(cwd)
            let directDir = ((ClaudeHome.projectsDir() as NSString).appendingPathComponent(encoded) as NSString)
                .appendingPathComponent(id) as NSString
            let candidate = directDir.appendingPathComponent("subagents")
            if isDirectory(candidate) { subagentDirs.append(candidate) }
        }
        if subagentDirs.isEmpty {
            let projectsDir = ClaudeHome.projectsDir()
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) {
                for entry in entries.sorted() {
                    let entryPath = (projectsDir as NSString).appendingPathComponent(entry)
                    guard isDirectory(entryPath) else { continue }
                    let candidate = ((entryPath as NSString).appendingPathComponent(id) as NSString)
                        .appendingPathComponent("subagents")
                    if isDirectory(candidate) { subagentDirs.append(candidate) }
                }
            }
        }

        struct SubEntry {
            var id: String
            var name: String
            var type: String
            var subagentType: String?
            var dbAgentId: String?
            var sortTime: Double
        }
        var subEntries: [SubEntry] = []

        for dir in subagentDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for file in files.sorted() where file.hasSuffix(".jsonl") {
                // File name format: agent-<shortId>.jsonl
                let strippedPrefix = file.hasPrefix("agent-") ? String(file.dropFirst("agent-".count)) : file
                let idNoExt = strippedPrefix.hasSuffix(".jsonl") ? String(strippedPrefix.dropLast(".jsonl".count)) : strippedPrefix

                let metaPath = (dir as NSString).appendingPathComponent(String(file.dropLast(".jsonl".count)) + ".meta.json")
                var metaDescription: String?
                var metaAgentType: String?
                if let metaData = FileManager.default.contents(atPath: metaPath),
                   let meta = try? JSONDecoder().decode(JSONValue.self, from: metaData) {
                    metaDescription = meta.nonEmptyString("description")
                    metaAgentType = meta.nonEmptyString("agentType")
                }

                let isCompact = idNoExt.hasPrefix("acompact-")
                let name = isCompact ? "Context Compaction" : (metaDescription ?? metaAgentType ?? idNoExt)
                let subagentType = isCompact ? nil : metaAgentType

                var sortTime = Double.infinity
                let jsonlPath = (dir as NSString).appendingPathComponent(file)
                if let firstLine = firstNonEmptyLine(of: jsonlPath),
                   let data = firstLine.data(using: .utf8),
                   let entry = try? JSONDecoder().decode(JSONValue.self, from: data),
                   let ts = entry.string("timestamp"),
                   let date = PodiumDate.parse(ts) {
                    sortTime = date.timeIntervalSince1970
                }

                subEntries.append(SubEntry(
                    id: idNoExt, name: name, type: isCompact ? "compaction" : "subagent",
                    subagentType: subagentType, dbAgentId: nil, sortTime: sortTime
                ))
            }
        }

        // Match DB agents to transcripts: group both by (subagent_type ||
        // type) key, sort each group by time ascending, match positionally.
        var transcriptsByType: [String: [Int]] = [:]
        for (idx, entry) in subEntries.enumerated() {
            transcriptsByType[entry.subagentType ?? entry.type, default: []].append(idx)
        }
        for key in transcriptsByType.keys {
            transcriptsByType[key]!.sort { subEntries[$0].sortTime < subEntries[$1].sortTime }
        }

        var agentsByType: [String: [Agent]] = [:]
        for agent in dbAgents {
            agentsByType[agent.subagentType ?? agent.type.rawValue, default: []].append(agent)
        }
        for key in agentsByType.keys {
            agentsByType[key]!.sort { $0.startedAt < $1.startedAt }
        }

        for (key, indices) in transcriptsByType {
            let aGroup = agentsByType[key] ?? []
            var usedAgentIds = Set<String>()
            for (position, idx) in indices.enumerated() where position < aGroup.count {
                let candidateAgentId = aGroup[position].id
                guard !usedAgentIds.contains(candidateAgentId) else { continue }
                subEntries[idx].dbAgentId = candidateAgentId
                usedAgentIds.insert(candidateAgentId)
            }
        }

        var result: [TranscriptInfo] = []
        if let mainEntry { result.append(mainEntry) }
        result.append(contentsOf: subEntries.map {
            TranscriptInfo(id: $0.id, name: $0.name, type: $0.type, subagentType: $0.subagentType, hasTranscript: true, dbAgentId: $0.dbAgentId)
        })

        result.sort { a, b in
            if a.type == "main" { return true }
            if b.type == "main" { return false }
            let aAgent = dbAgents.first { $0.id == a.dbAgentId }
            let bAgent = dbAgents.first { $0.id == b.dbAgentId }
            let aTime = aAgent.flatMap { PodiumDate.parse($0.startedAt)?.timeIntervalSince1970 } ?? 0
            let bTime = bAgent.flatMap { PodiumDate.parse($0.startedAt)?.timeIntervalSince1970 } ?? 0
            if aTime != 0 && bTime != 0 { return aTime < bTime }
            if aTime != 0 { return true }
            if bTime != 0 { return false }
            return a.name < b.name
        }

        return try JSONResponse(TranscriptListResult(transcripts: result))
    }

    // MARK: - GET /:id/transcript

    /// sessions.js lines 491–761: reads the resolved JSONL file (live
    /// `~/.claude/projects` path, else the durable import-time snapshot) and
    /// returns a page of parsed messages per `agent_id`/`limit`/`after`/
    /// `before`/`offset`. Never 404s on a missing/unreadable file — mirrors
    /// Node returning the empty-result shape from its `catch` block.
    private static func transcript(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let id = try ctx.parameters.require("id")
        guard let session = try context.store.getSession(id: id) else {
            return try JSONResponse(status: .notFound, CodedErrorResponse(code: "NOT_FOUND", message: "Session not found"))
        }

        let agentId = req.uri.queryTrimmed("agent_id")
        let limit = min(req.uri.queryInt("limit", fallback: 50), 200)
        let after = req.uri.queryIntOrNil("after")
        let before = req.uri.queryIntOrNil("before")
        let offset = req.uri.queryInt("offset", fallback: 0, min: 0)

        let jsonlPath: String?
        if let agentId, agentId != "main" {
            jsonlPath = ClaudeHome.subagentTranscriptPath(sessionId: id, cwd: session.cwd, agentId: agentId)
                ?? ClaudeHome.findSubagentTranscriptPath(sessionId: id, agentId: agentId)
                ?? ClaudeHome.snapshotSubagentTranscriptPath(sessionId: id, agentId: agentId)
        } else {
            jsonlPath = ClaudeHome.transcriptPath(sessionId: id, cwd: session.cwd)
                ?? ClaudeHome.findTranscriptPath(sessionId: id)
                ?? ClaudeHome.snapshotTranscriptPath(sessionId: id)
        }

        guard let jsonlPath else {
            return try JSONResponse(TranscriptResult(messages: [], total: 0, hasMore: false, lastLine: 0, firstLine: 0))
        }

        let result = TranscriptMessageParser.page(path: jsonlPath, limit: limit, after: after, before: before, offset: offset)
        return try JSONResponse(result)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var flag: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &flag) else { return false }
        return flag.boolValue
    }

    /// Streams only the first non-empty line of a JSONL file — avoids
    /// loading the whole file just to read its opening timestamp (parity
    /// with sessions.js's `readFirstLine`).
    private static func firstNonEmptyLine(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        let chunkSize = 4096
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            buffer.append(chunk)
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                guard let line = String(data: lineData, encoding: .utf8) else { return nil }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        guard let line = String(data: buffer, encoding: .utf8) else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - POST /

    /// sessions.js lines 255–277: idempotent create-by-id (returns the
    /// existing row with `created: false` if the id already exists),
    /// broadcasts `session_created` only on actual insert.
    private static func create(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        var mutableRequest = req
        let body = try await mutableRequest.decodeJSONBody(as: SessionCreateRequest.self)
        guard let id = body.id, !id.isEmpty else {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "INVALID_INPUT", message: "id is required"))
        }

        if let existing = try context.store.getSession(id: id) {
            return try JSONResponse(status: .ok, SessionCreateResponse(session: existing, created: false))
        }

        try context.store.insertSession(
            id: id, name: body.name, status: .active, cwd: body.cwd, model: body.model, metadata: body.metadata
        )
        guard let session = try context.store.getSession(id: id) else {
            return try JSONResponse(status: .internalServerError, CodedErrorResponse(code: "INTERNAL", message: "session insert did not persist"))
        }
        await context.broadcaster.broadcast(type: "session_created", data: session)
        return try JSONResponse(status: .created, SessionCreateResponse(session: session, created: true))
    }

    // MARK: - PATCH /:id

    /// sessions.js lines 279–297: partial update (name/status/ended_at/
    /// metadata — the task spec calls out name/status but the Node body
    /// also accepts `ended_at`; `PodiumStore.updateSession` already exposes
    /// that fourth field, wired through here for full parity).
    private static func patch(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let id = try ctx.parameters.require("id")
        guard try context.store.getSession(id: id) != nil else {
            return try JSONResponse(status: .notFound, CodedErrorResponse(code: "NOT_FOUND", message: "Session not found"))
        }

        var mutableRequest = req
        let body = try await mutableRequest.decodeJSONBody(as: SessionPatchRequestExtended.self)
        try context.store.updateSession(id: id, name: body.name, status: body.status, endedAt: body.endedAt, metadata: body.metadata)

        guard let session = try context.store.getSession(id: id) else {
            return try JSONResponse(status: .internalServerError, CodedErrorResponse(code: "INTERNAL", message: "session update did not persist"))
        }
        await context.broadcaster.broadcast(type: "session_updated", data: session)
        return try JSONResponse(SessionDetailPatchResponse(session: session))
    }
}

/// `POST /api/sessions` response envelope (sessions.js lines 263, 276).
private struct SessionCreateResponse: Encodable {
    let session: Session
    let created: Bool
}

/// `PATCH /api/sessions/:id` response envelope (sessions.js line 296).
private struct SessionDetailPatchResponse: Encodable {
    let session: Session
}

/// `PATCH /api/sessions/:id` request body, extended with `ended_at` /
/// `metadata` beyond the task-spec-named name/status — sessions.js's actual
/// handler (line 280) destructures all four from `req.body`.
private struct SessionPatchRequestExtended: Decodable {
    let name: String?
    let status: SessionStatus?
    let endedAt: String?
    let metadata: String?
}
