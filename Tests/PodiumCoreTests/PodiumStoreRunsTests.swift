import XCTest
@testable import PodiumCore

final class PodiumStoreRunsTests: XCTestCase {
    private var tempDir: URL!
    private var store: PodiumStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-store-runs-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try PodiumStore(path: tempDir.appendingPathComponent("dashboard.db").path)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRecordAndGetDashboardRunRoundTrips() throws {
        try store.recordDashboardRun(
            id: "run-1", sessionId: nil, mode: .headless, cwd: "/tmp", model: "claude-opus-4-8",
            permissionMode: "acceptEdits", effort: "high", resumeSessionId: nil, promptPreview: "do the thing",
            status: .spawning, exitCode: nil, startedAt: "2024-01-01T00:00:00.000Z", endedAt: nil
        )
        let run = try store.getDashboardRun(id: "run-1")
        XCTAssertEqual(run?.id, "run-1")
        XCTAssertEqual(run?.mode.rawValue, "headless")
        XCTAssertEqual(run?.model, "claude-opus-4-8")
        XCTAssertEqual(run?.status.rawValue, "spawning")
        XCTAssertEqual(run?.promptPreview, "do the thing")
        XCTAssertNil(run?.endedAt)
    }

    func testRecordDashboardRunIsIdempotentOnId() throws {
        try store.recordDashboardRun(
            id: "run-2", sessionId: nil, mode: .conversation, cwd: "/tmp", model: nil,
            permissionMode: nil, effort: nil, resumeSessionId: nil, promptPreview: nil,
            status: .spawning, exitCode: nil, startedAt: "2024-01-01T00:00:00.000Z", endedAt: nil
        )
        try store.recordDashboardRun(
            id: "run-2", sessionId: "sess-1", mode: .conversation, cwd: "/tmp", model: nil,
            permissionMode: nil, effort: nil, resumeSessionId: nil, promptPreview: nil,
            status: .running, exitCode: nil, startedAt: "2024-01-01T00:00:00.000Z", endedAt: nil
        )
        let all = try store.listDashboardRuns(limit: 10)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].status.rawValue, "running")
        XCTAssertEqual(all[0].sessionId, "sess-1")
    }

    func testPatchDashboardRunOnlyUpdatesProvidedFields() throws {
        try store.recordDashboardRun(
            id: "run-3", sessionId: nil, mode: .headless, cwd: "/tmp", model: nil,
            permissionMode: nil, effort: nil, resumeSessionId: nil, promptPreview: "hello",
            status: .spawning, exitCode: nil, startedAt: "2024-01-01T00:00:00.000Z", endedAt: nil
        )
        try store.patchDashboardRun(id: "run-3", status: .running)
        var run = try store.getDashboardRun(id: "run-3")
        XCTAssertEqual(run?.status.rawValue, "running")
        XCTAssertEqual(run?.promptPreview, "hello") // untouched

        try store.patchDashboardRun(id: "run-3", sessionId: "sess-9", status: .completed, exitCode: 0, endedAt: "2024-01-01T00:01:00.000Z")
        run = try store.getDashboardRun(id: "run-3")
        XCTAssertEqual(run?.sessionId, "sess-9")
        XCTAssertEqual(run?.status.rawValue, "completed")
        XCTAssertEqual(run?.exitCode, 0)
        XCTAssertEqual(run?.endedAt, "2024-01-01T00:01:00.000Z")
    }

    func testListDashboardRunsOrdersMostRecentFirstAndClampsLimit() throws {
        try store.recordDashboardRun(id: "old", sessionId: nil, mode: .headless, cwd: "/tmp", model: nil, permissionMode: nil, effort: nil, resumeSessionId: nil, promptPreview: nil, status: .completed, exitCode: 0, startedAt: "2024-01-01T00:00:00.000Z", endedAt: nil)
        try store.recordDashboardRun(id: "new", sessionId: nil, mode: .headless, cwd: "/tmp", model: nil, permissionMode: nil, effort: nil, resumeSessionId: nil, promptPreview: nil, status: .completed, exitCode: 0, startedAt: "2024-01-02T00:00:00.000Z", endedAt: nil)

        let all = try store.listDashboardRuns(limit: 1000)
        XCTAssertEqual(all.map(\.id), ["new", "old"])

        // Node's listRuns clamps the *limit value* itself to [1, 500] before
        // passing it to SQL LIMIT (Math.max(1, Math.min(500, limit))) — a
        // negative limit clamps to 1, not "no limit". LIMIT 1 returns only
        // the most recent row.
        let clamped = try store.listDashboardRuns(limit: -5)
        XCTAssertEqual(clamped.map(\.id), ["new"])
    }

    func testReconcileOrphanRunsAbandonsRunningAndSpawningOnly() throws {
        try store.recordDashboardRun(id: "r-spawning", sessionId: nil, mode: .headless, cwd: "/tmp", model: nil, permissionMode: nil, effort: nil, resumeSessionId: nil, promptPreview: nil, status: .spawning, exitCode: nil, startedAt: "2024-01-01T00:00:00.000Z", endedAt: nil)
        try store.recordDashboardRun(id: "r-running", sessionId: nil, mode: .headless, cwd: "/tmp", model: nil, permissionMode: nil, effort: nil, resumeSessionId: nil, promptPreview: nil, status: .running, exitCode: nil, startedAt: "2024-01-01T00:00:00.000Z", endedAt: nil)
        try store.recordDashboardRun(id: "r-completed", sessionId: nil, mode: .headless, cwd: "/tmp", model: nil, permissionMode: nil, effort: nil, resumeSessionId: nil, promptPreview: nil, status: .completed, exitCode: 0, startedAt: "2024-01-01T00:00:00.000Z", endedAt: "2024-01-01T00:01:00.000Z")

        let changed = try store.reconcileOrphanRuns()
        XCTAssertEqual(changed, 2)

        XCTAssertEqual(try store.getDashboardRun(id: "r-spawning")?.status.rawValue, "abandoned")
        XCTAssertEqual(try store.getDashboardRun(id: "r-running")?.status.rawValue, "abandoned")
        XCTAssertEqual(try store.getDashboardRun(id: "r-completed")?.status.rawValue, "completed")
        XCTAssertNotNil(try store.getDashboardRun(id: "r-spawning")?.endedAt)
    }

    func testRecentSessionCwdsReturnsDistinctCwdsMostRecentFirst() throws {
        try store.insertSession(id: "s1", name: nil, status: .completed, cwd: "/repo/a", model: nil, metadata: nil)
        try store.insertSession(id: "s2", name: nil, status: .completed, cwd: "/repo/b", model: nil, metadata: nil)
        try store.insertSession(id: "s3", name: nil, status: .completed, cwd: "/repo/a", model: nil, metadata: nil)
        try store.db.exec("UPDATE sessions SET started_at = '2024-01-01T00:00:00.000Z' WHERE id = 's1';")
        try store.db.exec("UPDATE sessions SET started_at = '2024-01-02T00:00:00.000Z' WHERE id = 's2';")
        try store.db.exec("UPDATE sessions SET started_at = '2024-01-03T00:00:00.000Z' WHERE id = 's3';")

        let cwds = try store.recentSessionCwds(limit: 10)
        XCTAssertEqual(cwds, ["/repo/a", "/repo/b"]) // /repo/a's most recent session (s3) is newest overall
    }
}
