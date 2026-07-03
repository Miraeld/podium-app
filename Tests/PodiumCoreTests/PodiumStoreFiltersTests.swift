import XCTest
@testable import PodiumCore

/// Covers the dynamic-WHERE / filter helpers added in PodiumStore+Filters.swift
/// for the P2.2 read routers: session list filters (incl. the
/// error-but-running-counts-as-active rule), facets, event filters, and
/// search queries. HTTP-level behavior (status codes, envelopes, broadcasts)
/// is covered separately in Tests/PodiumServerTests/ReadRoutersTests.swift.
final class PodiumStoreFiltersTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-filters-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func openStore() throws -> PodiumStore {
        try PodiumStore(path: tempDir.appendingPathComponent("dashboard.db").path)
    }

    // MARK: - Session filters

    func testStatusActiveFilterIncludesErrorSessionsStillRunning() throws {
        let store = try openStore()
        try store.insertSession(id: "s-active", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.insertSession(id: "s-error-running", name: nil, status: .error, cwd: nil, model: nil, metadata: nil)
        try store.insertSession(id: "s-error-ended", name: nil, status: .error, cwd: nil, model: nil, metadata: nil)
        try store.updateSession(id: "s-error-ended", endedAt: PodiumDate.now())
        try store.insertSession(id: "s-completed", name: nil, status: .completed, cwd: nil, model: nil, metadata: nil)

        let filter = PodiumStore.SessionFilter(status: "active")
        let rows = try store.listSessionsFiltered(matching: filter, limit: 50, offset: 0)
        let ids = Set(rows.map(\.id))

        XCTAssertTrue(ids.contains("s-active"))
        XCTAssertTrue(ids.contains("s-error-running"), "error session with no ended_at must count as active")
        XCTAssertFalse(ids.contains("s-error-ended"), "error session that already ended must NOT count as active")
        XCTAssertFalse(ids.contains("s-completed"))

        XCTAssertEqual(try store.countSessions(matching: filter), 2)
    }

    func testNonActiveStatusFilterIsExact() throws {
        let store = try openStore()
        try store.insertSession(id: "s1", name: nil, status: .completed, cwd: nil, model: nil, metadata: nil)
        try store.insertSession(id: "s2", name: nil, status: .error, cwd: nil, model: nil, metadata: nil)

        let filter = PodiumStore.SessionFilter(status: "completed")
        let rows = try store.listSessionsFiltered(matching: filter, limit: 50, offset: 0)
        XCTAssertEqual(rows.map(\.id), ["s1"])
    }

    func testSearchQueryFilterMatchesIdNameOrCwd() throws {
        let store = try openStore()
        try store.insertSession(id: "abc-123", name: "My Session", status: .active, cwd: "/home/gael/proj", model: nil, metadata: nil)
        try store.insertSession(id: "def-456", name: "Other", status: .active, cwd: "/tmp", model: nil, metadata: nil)

        let filter = PodiumStore.SessionFilter(q: "gael")
        let rows = try store.listSessionsFiltered(matching: filter, limit: 50, offset: 0)
        XCTAssertEqual(rows.map(\.id), ["abc-123"])
    }

    func testCwdFacetsReturnsDistinctNonEmptySortedValues() throws {
        let store = try openStore()
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: "/b", model: nil, metadata: nil)
        try store.insertSession(id: "s2", name: nil, status: .active, cwd: "/a", model: nil, metadata: nil)
        try store.insertSession(id: "s3", name: nil, status: .active, cwd: "/a", model: nil, metadata: nil)
        try store.insertSession(id: "s4", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.insertSession(id: "s5", name: nil, status: .active, cwd: "", model: nil, metadata: nil)

        let facets = try store.sessionCwdFacets()
        XCTAssertEqual(facets, ["/a", "/b"])
    }

    func testSortByPriceOrdersByComputedCostDescending() throws {
        let store = try openStore()
        try store.insertSession(id: "cheap", name: nil, status: .active, cwd: nil, model: "claude-haiku", metadata: nil)
        try store.insertSession(id: "expensive", name: nil, status: .active, cwd: nil, model: "claude-opus-4-5", metadata: nil)
        try store.upsertTokenUsage(sessionId: "cheap", model: "claude-haiku", inputTokens: 1000, outputTokens: 1000, cacheReadTokens: 0, cacheWriteTokens: 0)
        try store.upsertTokenUsage(sessionId: "expensive", model: "claude-opus-4-5", inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 0, cacheWriteTokens: 0)
        try store.upsertPricing(PricingPutRequest(modelPattern: "claude-haiku%", displayName: "Haiku", inputPerMtok: 1, outputPerMtok: 1, cacheReadPerMtok: 0, cacheWritePerMtok: 0))
        try store.upsertPricing(PricingPutRequest(modelPattern: "claude-opus-4-5%", displayName: "Opus", inputPerMtok: 15, outputPerMtok: 75, cacheReadPerMtok: 0, cacheWritePerMtok: 0))

        let filter = PodiumStore.SessionFilter(sortBy: "price", sortDesc: true)
        let rows = try store.listSessionsFiltered(matching: filter, limit: 50, offset: 0)
        XCTAssertEqual(rows.map(\.id), ["expensive", "cheap"])
        XCTAssertGreaterThan(rows[0].cost ?? 0, rows[1].cost ?? 0)
    }

    // MARK: - Event filters

    func testEventFilterByTypeAndToolNameCSV() throws {
        let store = try openStore()
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.insertEvent(sessionId: "s1", agentId: nil, eventType: "PostToolUse", toolName: "Bash", summary: nil, data: nil)
        try store.insertEvent(sessionId: "s1", agentId: nil, eventType: "PostToolUse", toolName: "Read", summary: nil, data: nil)
        try store.insertEvent(sessionId: "s1", agentId: nil, eventType: "PreToolUse", toolName: "Bash", summary: nil, data: nil)

        let filter = PodiumStore.EventFilter(eventType: ["PostToolUse"], toolName: ["Bash"])
        let rows = try store.listEventsFiltered(matching: filter, limit: 50, offset: 0)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.toolName, "Bash")
        XCTAssertEqual(try store.countEventsFiltered(matching: filter), 1)
    }

    func testEventFacetsReturnsDistinctSortedValues() throws {
        let store = try openStore()
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.insertEvent(sessionId: "s1", agentId: nil, eventType: "PostToolUse", toolName: "Bash", summary: nil, data: nil)
        try store.insertEvent(sessionId: "s1", agentId: nil, eventType: "PreToolUse", toolName: "Bash", summary: nil, data: nil)
        try store.insertEvent(sessionId: "s1", agentId: nil, eventType: "PostToolUse", toolName: "Read", summary: nil, data: nil)

        let (eventTypes, toolNames) = try store.eventFacets()
        XCTAssertEqual(eventTypes, ["PostToolUse", "PreToolUse"])
        XCTAssertEqual(toolNames, ["Bash", "Read"])
    }

    // MARK: - Search

    func testSearchSessionsAndEventsReturnEachEntityKind() throws {
        let store = try openStore()
        try store.insertSession(id: "s1", name: "Refactor auth module", status: .active, cwd: "/tmp", model: nil, metadata: nil)
        try store.insertEvent(sessionId: "s1", agentId: nil, eventType: "PostToolUse", toolName: "Bash", summary: "ran auth tests", data: nil)

        let (sessionRows, sessionTotal) = try store.searchSessions(query: "auth", limit: 20, offset: 0)
        XCTAssertEqual(sessionTotal, 1)
        XCTAssertEqual(sessionRows.first?.id, "s1")

        let (eventRows, eventTotal) = try store.searchEvents(query: "auth", limit: 20, offset: 0)
        XCTAssertEqual(eventTotal, 1)
        XCTAssertEqual(eventRows.first?.summary, "ran auth tests")
    }

    // MARK: - countEventsToday two-modifier parity

    func testCountEventsTodayUsesDistinctLocalAndUTCModifiers() throws {
        let store = try openStore()
        try store.insertSession(id: "s1", name: nil, status: .active, cwd: nil, model: nil, metadata: nil)
        try store.insertEvent(sessionId: "s1", agentId: nil, eventType: "PostToolUse", toolName: nil, summary: nil, data: nil)

        // UTC "now" — with a zero offset, toLocal == toUTC == "0 minutes"
        // (well, "-0 minutes"/"0 minutes" — both are no-ops), so today's
        // event must be counted regardless.
        let countUTC = try store.countEventsToday(toLocal: "-0 minutes", toUTC: "0 minutes")
        XCTAssertEqual(countUTC, 1)

        // A large positive offset (e.g. UTC+14) shifts "start of local day"
        // forward; this must not crash and must still return a sane
        // non-negative count using the two-argument signature.
        let countShifted = try store.countEventsToday(toLocal: "-840 minutes", toUTC: "840 minutes")
        XCTAssertGreaterThanOrEqual(countShifted, 0)
    }
}
