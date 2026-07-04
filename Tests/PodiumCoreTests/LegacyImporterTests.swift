import XCTest
@testable import PodiumCore

/// Coverage for `LegacyImporter` (port of scripts/import-history.js):
/// JSONL parsing, idempotent import (run-twice-count-once), token-0 legacy
/// sessions gaining real token_usage from the transcript, subagent JSONL
/// import (live-match + JSONL-keyed fallback), and compaction backfill.
final class LegacyImporterTests: XCTestCase {
    private var tempHome: URL!
    private var tempDataDir: URL!
    private var originalClaudeEnv: [String: String]!
    private var originalPathsEnv: [String: String]!
    private var store: PodiumStore!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory.appendingPathComponent("podium-legacy-import-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)

        tempDataDir = FileManager.default.temporaryDirectory.appendingPathComponent("podium-legacy-import-data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDataDir, withIntermediateDirectories: true)

        originalClaudeEnv = ClaudeHome.environment
        originalPathsEnv = PodiumPaths.environment
        ClaudeHome.environment = ["CLAUDE_HOME": tempHome.path]
        PodiumPaths.environment = ["DASHBOARD_DATA_DIR": tempDataDir.path]
        ClaudeHome.resetOverrideCacheForTesting()

        store = try PodiumStore(path: tempDataDir.appendingPathComponent("dashboard.db").path)
    }

    override func tearDownWithError() throws {
        ClaudeHome.environment = originalClaudeEnv
        PodiumPaths.environment = originalPathsEnv
        ClaudeHome.resetOverrideCacheForTesting()
        try? FileManager.default.removeItem(at: tempHome)
        try? FileManager.default.removeItem(at: tempDataDir)
    }

    // MARK: - Fixture helpers

    private let cwd = "/Users/test/project"

    private func projectDir() throws -> URL {
        let encoded = ClaudeHome.encodeCwd(cwd)
        let dir = tempHome.appendingPathComponent("projects", isDirectory: true).appendingPathComponent(encoded, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a realistic session JSONL: one user turn, two assistant turns
    /// (usage on both, one with a tool_use), zero hook-derived DB rows —
    /// i.e. a "pure legacy" transcript never seen by any hook.
    @discardableResult
    private func writeSessionFixture(sessionId: String, extraLines: [String] = []) throws -> URL {
        let dir = try projectDir()
        let path = dir.appendingPathComponent("\(sessionId).jsonl")
        var lines = [
            #"{"cwd":"\#(cwd)","slug":"demo","gitBranch":"main","version":"1.2.3","timestamp":"2024-01-01T00:00:00.000Z","type":"user","message":{"role":"user","content":"Hello"}}"#,
            #"{"timestamp":"2024-01-01T00:00:05.000Z","type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"Hi there"}],"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":10,"cache_creation_input_tokens":5}}}"#,
            #"{"timestamp":"2024-01-01T00:00:10.000Z","type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":20,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
        ]
        lines.append(contentsOf: extraLines)
        try lines.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
        // Backdate mtime well past the importer's 10-minute "recently
        // active" freshness window, so fixtures import as `completed`
        // (the common case) rather than `active`/`waiting` unless a test
        // explicitly wants the freshness heuristic.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: path.path)
        return path
    }

    // MARK: - parseSessionFile

    func testParseSessionFileExtractsCoreFields() throws {
        let path = try writeSessionFixture(sessionId: "sess-1")
        let session = try XCTUnwrap(LegacyImporter.parseSessionFile(path.path))

        XCTAssertEqual(session.sessionId, "sess-1")
        XCTAssertEqual(session.cwd, cwd)
        XCTAssertEqual(session.slug, "demo")
        XCTAssertEqual(session.gitBranch, "main")
        XCTAssertEqual(session.version, "1.2.3")
        XCTAssertEqual(session.model, "claude-sonnet-4-5")
        XCTAssertEqual(session.userMessages, 1)
        XCTAssertEqual(session.assistantMessages, 2)
        XCTAssertEqual(session.messageTimestamps, ["2024-01-01T00:00:05.000Z", "2024-01-01T00:00:10.000Z"])
        XCTAssertEqual(session.toolUses.map(\.name), ["Bash"])
        XCTAssertEqual(session.startedAt, "2024-01-01T00:00:00.000Z")
        XCTAssertEqual(session.endedAt, "2024-01-01T00:00:10.000Z")

        let tokens = try XCTUnwrap(session.tokensByModel["claude-sonnet-4-5"])
        XCTAssertEqual(tokens.inputTokens, 120)
        XCTAssertEqual(tokens.outputTokens, 60)
        XCTAssertEqual(tokens.cacheReadTokens, 10)
        XCTAssertEqual(tokens.cacheWriteTokens, 5)
    }

    func testParseSessionFileReturnsNilForUnreadableOrEmptyFile() throws {
        XCTAssertNil(LegacyImporter.parseSessionFile("/does/not/exist.jsonl"))

        let emptyPath = tempHome.appendingPathComponent("empty.jsonl")
        try "".write(to: emptyPath, atomically: true, encoding: .utf8)
        XCTAssertNil(LegacyImporter.parseSessionFile(emptyPath.path))
    }

    // MARK: - importAllSessions: run-twice-count-once + token-0 backfill

    func testImportAllSessionsIsIdempotentAndBackfillsRealTokens() throws {
        try writeSessionFixture(sessionId: "sess-token-zero")

        // Before import: genuinely zero token_usage rows for this session
        // (the whole point of a "pure legacy" JSONL never seen by a hook).
        XCTAssertEqual(try store.sessionTokenTotals(sessionId: "sess-token-zero").totalInput, 0)

        let first = try LegacyImporter.importAllSessions(store: store)
        XCTAssertEqual(first.imported, 1)
        XCTAssertEqual(first.skipped, 0)
        XCTAssertEqual(first.errors, 0)

        let session = try XCTUnwrap(store.getSession(id: "sess-token-zero"))
        XCTAssertEqual(session.status.knownValue, .completed)
        XCTAssertEqual(session.cwd, cwd)

        let agents = try store.listAgentsBySession(sessionId: "sess-token-zero")
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].type.knownValue, .main)

        let events = try store.listEventsBySession(sessionId: "sess-token-zero")
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.contains { $0.eventType == "Stop" })
        XCTAssertTrue(events.contains { $0.eventType == "PostToolUse" && $0.toolName == "Bash" })
        let eventCountAfterFirstImport = events.count

        // The token-0 bug check: a session imported purely from legacy JSONL
        // must get non-zero token_usage from the transcript parse.
        let tokenTotals = try store.sessionTokenTotals(sessionId: "sess-token-zero")
        XCTAssertEqual(tokenTotals.totalInput, 120)
        XCTAssertEqual(tokenTotals.totalOutput, 60)
        XCTAssertEqual(tokenTotals.totalCacheRead, 10)
        XCTAssertEqual(tokenTotals.totalCacheWrite, 5)

        // Re-running the exact same JSONL must not duplicate anything.
        let second = try LegacyImporter.importAllSessions(store: store)
        XCTAssertEqual(second.imported, 0, "re-import of an unchanged session must not count as freshly imported")
        XCTAssertEqual(second.backfilled, 0, "nothing new to backfill on an unchanged JSONL")

        let eventsAfterSecondImport = try store.listEventsBySession(sessionId: "sess-token-zero")
        XCTAssertEqual(eventsAfterSecondImport.count, eventCountAfterFirstImport, "re-import must not duplicate events")

        let tokensAfterSecondImport = try store.sessionTokenTotals(sessionId: "sess-token-zero")
        XCTAssertEqual(tokensAfterSecondImport.totalInput, 120, "re-import must not double-count tokens")
    }

    /// A session imported once, then the JSONL grows with a genuinely new
    /// assistant turn — re-importing must pick up ONLY the new turn (the
    /// per-event-type high-water-mark / `isNewer` check).
    func testImportAllSessionsBackfillsOnlyNewEventsWhenTranscriptGrows() throws {
        let path = try writeSessionFixture(sessionId: "sess-growing")
        try LegacyImporter.importAllSessions(store: store)
        let eventCountBeforeGrowth = try store.listEventsBySession(sessionId: "sess-growing").count

        let newLine = #"{"timestamp":"2024-01-01T00:05:00.000Z","type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"Later reply"}],"usage":{"input_tokens":7,"output_tokens":3,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
        let existing = try String(contentsOf: path, encoding: .utf8)
        try (existing + "\n" + newLine).write(to: path, atomically: true, encoding: .utf8)

        let second = try LegacyImporter.importAllSessions(store: store)
        XCTAssertEqual(second.backfilled, 1)

        let eventsAfter = try store.listEventsBySession(sessionId: "sess-growing")
        XCTAssertEqual(eventsAfter.count, eventCountBeforeGrowth + 1, "only the one new Stop event should have been added")
        XCTAssertTrue(eventsAfter.contains { $0.createdAt == "2024-01-01T00:05:00.000Z" })

        // Node parity quirk, preserved deliberately (see import-history.js's
        // `importSession` backfill branch, lines 1085-1105): the regular
        // backfill path only re-writes token_usage when the session has
        // NON-ZERO SUBAGENT tokens (the fix that shipped was for subagent
        // token undercounting specifically) — a growing session with no
        // subagents keeps its ORIGINAL main-transcript token totals on
        // re-import. Full reconciliation of growing main-session tokens is
        // a separate, CLI-only `reconcileTokens` path Node exposes via
        // `--reconcile-tokens`, out of scope for the regular import/sweep
        // pipeline this task ports.
        let tokens = try store.sessionTokenTotals(sessionId: "sess-growing")
        XCTAssertEqual(tokens.totalInput, 120, "main-session token totals are untouched by backfill without subagents — matches Node")
    }

    // MARK: - Subagent JSONL import

    func testImportFromDirectoryImportsSubagentToolEvents() throws {
        let sessionId = "sess-with-sub"
        let sessionPath = try writeSessionFixture(sessionId: sessionId)
        let subDir = sessionPath.deletingLastPathComponent()
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let subLines = [
            #"{"timestamp":"2024-01-01T00:00:02.000Z","type":"user","message":{"role":"user","content":"Do the subtask"}}"#,
            #"{"timestamp":"2024-01-01T00:00:03.000Z","type":"assistant","message":{"role":"assistant","model":"claude-haiku-4-5","content":[{"type":"tool_use","id":"sub-tu1","name":"Read","input":{"path":"x.txt"}}],"usage":{"input_tokens":5,"output_tokens":2,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
            #"{"timestamp":"2024-01-01T00:00:04.000Z","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"sub-tu1","content":"file contents","is_error":false}]}}"#,
        ]
        try subLines.joined(separator: "\n").write(to: subDir.appendingPathComponent("agent-sub-1.jsonl"), atomically: true, encoding: .utf8)

        let counters = try LegacyImporter.importFromDirectory(store: store, rootDir: tempHome.appendingPathComponent("projects").path)
        XCTAssertEqual(counters.imported, 1)

        let agents = try store.listAgentsBySession(sessionId: sessionId)
        let subAgent = try XCTUnwrap(agents.first { $0.type.knownValue == .subagent })
        XCTAssertEqual(subAgent.id, "\(sessionId)-jsonl-sub-1")
        XCTAssertEqual(subAgent.status.knownValue, .completed)

        let events = try store.listEventsBySession(sessionId: sessionId)
        XCTAssertTrue(events.contains { $0.agentId == subAgent.id && $0.eventType == "PreToolUse" && $0.toolName == "Read" })
        XCTAssertTrue(events.contains { $0.agentId == subAgent.id && $0.eventType == "PostToolUse" && $0.toolName == "Read" })
        XCTAssertTrue(events.contains { $0.agentId == subAgent.sessionId + "-main" && $0.eventType == "PreToolUse" && ($0.data ?? "").contains("subagent_jsonl") })

        // Subagent's own tokens must be merged into the session total.
        let tokens = try store.sessionTokenTotals(sessionId: sessionId)
        XCTAssertEqual(tokens.totalInput, 125) // 120 (main) + 5 (sub)
    }

    /// A live subagent (created via the PreToolUse "Agent" hook, exactly
    /// like the ingest engine would create) matching a JSONL subagent by
    /// `spawn_tool_use_id` must receive the JSONL tool events under ITS OWN
    /// id — no duplicate `-jsonl-` row created.
    func testImportSubagentFromJsonlMergesIntoLiveSubagentByToolUseId() throws {
        let sessionId = "sess-live-match"
        try store.insertSession(id: sessionId, name: "Live", status: .active, cwd: cwd, model: "claude-sonnet-4-5", metadata: nil)
        let mainAgentId = "\(sessionId)-main"
        try store.insertAgent(id: mainAgentId, sessionId: sessionId, name: "Main", type: .main, subagentType: nil, status: .working, task: nil, parentAgentId: nil, metadata: nil)

        let liveSubId = "\(sessionId)-live-sub"
        let liveMetadata = #"{"spawn_tool_use_id":"agent-tool-use-1"}"#
        try store.insertAgent(id: liveSubId, sessionId: sessionId, name: "general-purpose", type: .subagent, subagentType: "general-purpose", status: .working, task: nil, parentAgentId: mainAgentId, metadata: liveMetadata)

        let sub = LegacyImporter.ParsedSubagent(
            agentId: "sub-1", agentType: "general-purpose", description: nil, spawnToolUseId: "agent-tool-use-1", task: "do it",
            model: "claude-haiku-4-5", startedAt: "2024-01-01T00:00:02.000Z", endedAt: "2024-01-01T00:00:04.000Z",
            userMessages: 1, assistantMessages: 1, tokensByModel: [:], toolNames: ["Read"], thinkingBlockCount: 0,
            toolEvents: [.init(toolUseId: "sub-tu1", toolName: "Read", toolInput: nil, preTimestamp: "2024-01-01T00:00:03.000Z", toolResponse: nil, isError: false, postTimestamp: "2024-01-01T00:00:04.000Z")]
        )

        let created = try LegacyImporter.importSubagentFromJsonl(store: store, sessionId: sessionId, mainAgentId: mainAgentId, sub: sub)
        XCTAssertGreaterThan(created, 0)

        // No JSONL-keyed row was created — the live row absorbed the events.
        XCTAssertNil(try store.getAgent(id: "\(sessionId)-jsonl-sub-1"))
        let events = try store.listEventsBySession(sessionId: sessionId)
        XCTAssertTrue(events.contains { $0.agentId == liveSubId && $0.eventType == "PreToolUse" && $0.toolName == "Read" })
        XCTAssertTrue(events.contains { $0.agentId == liveSubId && $0.eventType == "PostToolUse" && $0.toolName == "Read" })
    }

    // MARK: - backfillCompactions

    func testBackfillCompactionsCreatesCompactionAgentAndEvent() throws {
        let compactLine = #"{"timestamp":"2024-01-01T00:10:00.000Z","isCompactSummary":true,"uuid":"compact-uuid-1"}"#
        try writeSessionFixture(sessionId: "sess-compact", extraLines: [compactLine])

        try LegacyImporter.importAllSessions(store: store)
        // The fixture's own JSONL already carries the compaction entry, so
        // the initial import should have created it — assert that, then
        // prove backfillCompactions is idempotent on top.
        let compactAgentId = "sess-compact-compact-compact-uuid-1"
        XCTAssertNotNil(try store.getAgent(id: compactAgentId))

        let backfilled = try LegacyImporter.backfillCompactions(store: store)
        XCTAssertEqual(backfilled, 0, "the compaction was already imported — backfill must not duplicate it")
    }

    func testBackfillCompactionsAddsMissingCompactionForAlreadyImportedSession() throws {
        // Import WITHOUT the compaction line first (simulating a session
        // imported by an older run before /compact happened)…
        let path = try writeSessionFixture(sessionId: "sess-compact-later")
        try LegacyImporter.importAllSessions(store: store)
        XCTAssertNil(try store.getAgent(id: "sess-compact-later-compact-compact-uuid-2"))

        // …then the transcript gains a compaction entry (as if /compact ran).
        let compactLine = #"{"timestamp":"2024-01-01T00:20:00.000Z","isCompactSummary":true,"uuid":"compact-uuid-2"}"#
        let existing = try String(contentsOf: path, encoding: .utf8)
        try (existing + "\n" + compactLine).write(to: path, atomically: true, encoding: .utf8)

        let backfilled = try LegacyImporter.backfillCompactions(store: store)
        XCTAssertEqual(backfilled, 1)
        let compactAgent = try XCTUnwrap(store.getAgent(id: "sess-compact-later-compact-compact-uuid-2"))
        XCTAssertEqual(compactAgent.subagentType, "compaction")
    }

    // MARK: - classifyJsonl / collectJsonlFiles / findSessionSubagents

    func testClassifyJsonlDetectsSubagentLayout() {
        XCTAssertEqual(LegacyImporter.classifyJsonl("/root/proj/sess-1.jsonl"), .session)
        XCTAssertEqual(LegacyImporter.classifyJsonl("/root/proj/sess-1/subagents/agent-a.jsonl"), .subagent)
        XCTAssertEqual(LegacyImporter.classifyJsonl("/root/proj/subagents/sess-1/agent-a.jsonl"), .subagent)
    }

    func testCollectJsonlFilesWalksRecursively() throws {
        let root = tempHome.appendingPathComponent("scan-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested", isDirectory: true), withIntermediateDirectories: true)
        try "{}".write(to: root.appendingPathComponent("top.jsonl"), atomically: true, encoding: .utf8)
        try "{}".write(to: root.appendingPathComponent("nested/deep.jsonl"), atomically: true, encoding: .utf8)
        try "ignore me".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let files = Set(LegacyImporter.collectJsonlFiles(root.path).map { ($0 as NSString).lastPathComponent })
        XCTAssertEqual(files, ["top.jsonl", "deep.jsonl"])
    }
}

/// F1 perf regression: a 50-session corpus, imported+backfilled twice.
/// Kept CI-fast (tens of ms), but shaped like the real-world symptom
/// (`POST /api/settings/reimport` re-scanning the whole corpus on every
/// call) — the SECOND pass must do near-zero parsing work, verified two
/// ways: (1) deterministic counters (`skipped == sessionCount`, nothing
/// re-imported/re-backfilled — not timing-based, so it can't flake on a
/// loaded CI runner), and (2) a generous wall-clock ratio ceiling as a
/// coarse regression guard against the skip-cache silently regressing back
/// into a full rescan.
final class F1ImportSkipCacheRegressionTests: XCTestCase {
    private var tempHome: URL!
    private var tempDataDir: URL!
    private var originalClaudeEnv: [String: String]!
    private var originalPathsEnv: [String: String]!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory.appendingPathComponent("podium-f1-perf-home-\(UUID().uuidString)", isDirectory: true)
        tempDataDir = FileManager.default.temporaryDirectory.appendingPathComponent("podium-f1-perf-data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDataDir, withIntermediateDirectories: true)

        originalClaudeEnv = ClaudeHome.environment
        originalPathsEnv = PodiumPaths.environment
        ClaudeHome.environment = ["CLAUDE_HOME": tempHome.path]
        PodiumPaths.environment = ["DASHBOARD_DATA_DIR": tempDataDir.path]
        ClaudeHome.resetOverrideCacheForTesting()
    }

    override func tearDownWithError() throws {
        ClaudeHome.environment = originalClaudeEnv
        PodiumPaths.environment = originalPathsEnv
        ClaudeHome.resetOverrideCacheForTesting()
        try? FileManager.default.removeItem(at: tempHome)
        try? FileManager.default.removeItem(at: tempDataDir)
    }

    private let sessionCount = 50
    private let turnsPerSession = 60

    /// Writes `sessionCount` session JSONLs (each `turnsPerSession` assistant
    /// turns with a tool_use/tool_result pair every 5th turn, plus one
    /// compaction marker) — big enough that a full rescan is measurably
    /// slower than a cache-hit skip, small enough to stay CI-fast either way.
    private func writeCorpus() throws {
        let projectsDir = tempHome.appendingPathComponent("projects", isDirectory: true)
        for i in 0..<sessionCount {
            let dir = projectsDir.appendingPathComponent("proj-\(i % 5)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent("sess-\(i).jsonl")

            var lines = [
                #"{"cwd":"/Users/test/project\#(i % 5)","slug":"demo","timestamp":"2024-01-01T00:00:00.000Z","type":"user","message":{"role":"user","content":"Hello"}}"#,
            ]
            for t in 0..<turnsPerSession {
                let ts = String(format: "2024-01-01T00:%02d:%02d.000Z", (t * 5) / 60, (t * 5) % 60)
                var content = #"[{"type":"text","text":"response text padded out a fair bit to be realistic"}]"#
                if t % 5 == 0 {
                    content = #"[{"type":"tool_use","id":"tu-\#(i)-\#(t)","name":"Bash","input":{"command":"ls -la"}}]"#
                }
                lines.append(#"{"timestamp":"\#(ts)","type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-5","content":\#(content),"usage":{"input_tokens":50,"output_tokens":20,"cache_read_input_tokens":5,"cache_creation_input_tokens":2}}}"#)
            }
            lines.append(#"{"timestamp":"2024-01-01T00:59:00.000Z","isCompactSummary":true,"uuid":"compact-\#(i)"}"#)
            try lines.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: path.path)
        }
    }

    func testSecondImportBackfillPassDoesNearZeroParsing() throws {
        try writeCorpus()
        let store = try PodiumStore(path: tempDataDir.appendingPathComponent("dashboard.db").path)

        let firstStart = Date()
        let firstImport = try LegacyImporter.importAllSessions(store: store)
        _ = try LegacyImporter.backfillCompactions(store: store)
        let firstElapsed = Date().timeIntervalSince(firstStart)

        XCTAssertEqual(firstImport.imported, sessionCount)

        let secondStart = Date()
        let secondImport = try LegacyImporter.importAllSessions(store: store)
        let secondBackfilled = try LegacyImporter.backfillCompactions(store: store)
        let secondElapsed = Date().timeIntervalSince(secondStart)

        // Deterministic — not timing-based, so this can't flake: an
        // unchanged corpus must be entirely served from the skip cache.
        XCTAssertEqual(secondImport.imported, 0, "no file changed — nothing should be freshly imported")
        XCTAssertEqual(secondImport.backfilled, 0, "no file changed — nothing new to backfill")
        XCTAssertEqual(secondImport.skipped, sessionCount, "every unchanged session file must be served from the import_file_cache skip")
        XCTAssertEqual(secondBackfilled, 0, "backfillCompactions must skip files whose fingerprint is unchanged")

        // Coarse regression guard: a silent revert to full-rescan-on-every-call
        // would make pass 2 roughly as slow as pass 1. Generous margin (4x)
        // so this doesn't flake on a loaded CI runner.
        XCTAssertLessThan(secondElapsed, firstElapsed / 4, "second pass should be dramatically faster than the first — got first=\(firstElapsed)s second=\(secondElapsed)s")
    }
}
