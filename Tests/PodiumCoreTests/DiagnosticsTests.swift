import XCTest
@testable import PodiumCore

/// Coverage of P4.4's new Diagnostics pieces: `LogRingBuffer`'s bounded
/// FIFO eviction + ordering, and `DiagnosticsRecorder`'s hook-health
/// bookkeeping (last-event timestamp, latency sample/average, success vs
/// failure counters) and derived status logic.
final class DiagnosticsTests: XCTestCase {

    // MARK: - LogRingBuffer

    func testRingBufferEvictsOldestBeyondCapacity() async {
        let buffer = LogRingBuffer(capacity: 3)
        for i in 0..<5 {
            await buffer.append(level: "info", message: "entry \(i)")
        }
        let snapshot = await buffer.snapshot()
        XCTAssertEqual(snapshot.count, 3)
        // Newest-first: the last three appended (2, 3, 4) survive, most recent first.
        XCTAssertEqual(snapshot.map(\.message), ["entry 4", "entry 3", "entry 2"])
    }

    func testRingBufferSnapshotRespectsLimit() async {
        let buffer = LogRingBuffer(capacity: 10)
        for i in 0..<10 {
            await buffer.append(level: "info", message: "entry \(i)")
        }
        let limited = await buffer.snapshot(limit: 2)
        XCTAssertEqual(limited.map(\.message), ["entry 9", "entry 8"])
    }

    func testRingBufferClearEmptiesAllEntries() async {
        let buffer = LogRingBuffer(capacity: 5)
        await buffer.append(level: "info", message: "hello")
        await buffer.clear()
        let snapshot = await buffer.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testRingBufferSingleEntryCapacityStillWorks() async {
        let buffer = LogRingBuffer(capacity: 1)
        await buffer.append(level: "info", message: "first")
        await buffer.append(level: "info", message: "second")
        let snapshot = await buffer.snapshot()
        XCTAssertEqual(snapshot.map(\.message), ["second"])
    }

    // MARK: - DiagnosticsRecorder

    func testRecorderTracksLastEventAndLatency() async {
        let recorder = DiagnosticsRecorder(log: LogRingBuffer())
        await recorder.recordHookEvent(hookType: "PostToolUse", sessionId: "sess-1", latencySeconds: 0.010)

        let health = await recorder.hookHealth()
        XCTAssertNotNil(health.lastEventAt)
        XCTAssertEqual(health.lastLatencySeconds, 0.010)
        XCTAssertEqual(health.averageLatencySeconds, 0.010)
        XCTAssertEqual(health.totalEventsProcessed, 1)
        XCTAssertEqual(health.totalEventsFailed, 0)
    }

    func testRecorderAveragesOverLatencyWindow() async {
        let recorder = DiagnosticsRecorder(log: LogRingBuffer())
        await recorder.recordHookEvent(hookType: "A", sessionId: "s", latencySeconds: 0.0)
        await recorder.recordHookEvent(hookType: "A", sessionId: "s", latencySeconds: 0.020)

        let health = await recorder.hookHealth()
        XCTAssertEqual(health.lastLatencySeconds, 0.020)
        XCTAssertEqual(health.averageLatencySeconds ?? -1, 0.010, accuracy: 0.0001)
        XCTAssertEqual(health.totalEventsProcessed, 2)
    }

    func testRecorderTracksFailuresSeparatelyFromSuccesses() async {
        let recorder = DiagnosticsRecorder(log: LogRingBuffer())
        await recorder.recordHookFailure(reason: "bad payload")
        await recorder.recordHookFailure(reason: "missing session_id")

        let health = await recorder.hookHealth()
        XCTAssertEqual(health.totalEventsFailed, 2)
        XCTAssertEqual(health.totalEventsProcessed, 0)
        XCTAssertNil(health.lastEventAt)
    }

    func testRecorderFeedsRingBufferOnSuccessAndFailure() async {
        let recorder = DiagnosticsRecorder(log: LogRingBuffer())
        await recorder.recordHookEvent(hookType: "PreToolUse", sessionId: "sess-1", latencySeconds: 0.005)
        await recorder.recordHookFailure(reason: "bad payload")

        let entries = await recorder.recentLog(limit: 10)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.contains { $0.level == "info" && $0.message.contains("PreToolUse") })
        XCTAssertTrue(entries.contains { $0.level == "error" && $0.message.contains("bad payload") })
    }

    func testRecorderResetForTestingClearsState() async {
        let recorder = DiagnosticsRecorder(log: LogRingBuffer())
        await recorder.recordHookEvent(hookType: "A", sessionId: "s", latencySeconds: 0.01)
        await recorder.recordHookFailure(reason: "x")
        await recorder.resetForTesting()

        let health = await recorder.hookHealth()
        XCTAssertNil(health.lastEventAt)
        XCTAssertNil(health.lastLatencySeconds)
        XCTAssertNil(health.averageLatencySeconds)
        XCTAssertEqual(health.totalEventsProcessed, 0)
        XCTAssertEqual(health.totalEventsFailed, 0)
        let entries = await recorder.recentLog()
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - DiagnosticsResponse.HookHealth.deriveStatus

    func testDeriveStatusUnknownWhenNoLastEvent() {
        XCTAssertEqual(DiagnosticsResponse.HookHealth.deriveStatus(lastEventAt: nil), "unknown")
    }

    func testDeriveStatusOkWhenRecent() {
        let now = Date()
        let recent = PodiumDate.format(now.addingTimeInterval(-30))
        XCTAssertEqual(DiagnosticsResponse.HookHealth.deriveStatus(lastEventAt: recent, now: now), "ok")
    }

    func testDeriveStatusStaleWhenOld() {
        let now = Date()
        let old = PodiumDate.format(now.addingTimeInterval(-3600))
        XCTAssertEqual(DiagnosticsResponse.HookHealth.deriveStatus(lastEventAt: old, now: now), "stale")
    }

    func testDeriveStatusUnknownWhenUnparsable() {
        XCTAssertEqual(DiagnosticsResponse.HookHealth.deriveStatus(lastEventAt: "not-a-date"), "unknown")
    }
}
