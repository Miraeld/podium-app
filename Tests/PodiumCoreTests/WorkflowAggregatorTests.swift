import XCTest
@testable import PodiumCore

/// Unit coverage for `WorkflowAggregator`'s pure post-SQL functions (P3.4) —
/// tree building, swimlane/timeline mapping, pattern mining, error-depth
/// folding, and concurrency aggregation. These take plain tuples/rows in and
/// assert exact struct output, independent of SQLite — the HTTP-level tree/
/// duration/swimlane-ordering assertions against a real seeded DB live in
/// `Tests/PodiumServerTests/WorkflowsRouterTests.swift`.
final class WorkflowAggregatorTests: XCTestCase {
    // MARK: - buildAgentTree

    /// 3-level nesting: main -> subagent -> sub-subagent. Mirrors
    /// workflows.js's `map[a.parent_agent_id]` guard — a dangling parent id
    /// (not present in this session's agent list) falls back to root.
    func testBuildAgentTreeNestsThreeLevelsDeep() {
        let main = Agent(
            id: "main", sessionId: "s1", name: "Main", type: .main, subagentType: nil,
            status: .completed, startedAt: "2024-01-01T00:00:00.000Z", endedAt: nil, updatedAt: "2024-01-01T00:00:00.000Z",
            parentAgentId: nil
        )
        let child = Agent(
            id: "child", sessionId: "s1", name: "Child", type: .subagent, subagentType: "worker",
            status: .completed, startedAt: "2024-01-01T00:01:00.000Z", endedAt: nil, updatedAt: "2024-01-01T00:01:00.000Z",
            parentAgentId: "main"
        )
        let grandchild = Agent(
            id: "grandchild", sessionId: "s1", name: "Grandchild", type: .subagent, subagentType: "worker",
            status: .working, startedAt: "2024-01-01T00:02:00.000Z", endedAt: nil, updatedAt: "2024-01-01T00:02:00.000Z",
            parentAgentId: "child"
        )
        let orphan = Agent(
            id: "orphan", sessionId: "s1", name: "Orphan", type: .subagent, subagentType: "worker",
            status: .completed, startedAt: "2024-01-01T00:03:00.000Z", endedAt: nil, updatedAt: "2024-01-01T00:03:00.000Z",
            parentAgentId: "does-not-exist"
        )

        let tree = WorkflowAggregator.buildAgentTree([main, child, grandchild, orphan])

        // main + the dangling-parent orphan are both roots.
        XCTAssertEqual(tree.map(\.id).sorted(), ["main", "orphan"])
        let mainNode = tree.first { $0.id == "main" }!
        XCTAssertEqual(mainNode.children.map(\.id), ["child"])
        XCTAssertEqual(mainNode.children[0].children.map(\.id), ["grandchild"])
        XCTAssertEqual(mainNode.children[0].children[0].children, [])
    }

    // MARK: - toolTimeline

    func testToolTimelineFiltersEventsWithoutToolName() {
        let events = [
            DashboardEvent(id: 1, sessionId: "s1", agentId: "a1", eventType: "PostToolUse", toolName: "Bash", summary: "ran ls", createdAt: "2024-01-01T00:00:01.000Z"),
            DashboardEvent(id: 2, sessionId: "s1", agentId: "a1", eventType: "SessionStart", toolName: nil, summary: nil, createdAt: "2024-01-01T00:00:00.000Z"),
            DashboardEvent(id: 3, sessionId: "s1", agentId: "a1", eventType: "PreToolUse", toolName: "Read", summary: nil, createdAt: "2024-01-01T00:00:02.000Z"),
        ]
        let timeline = WorkflowAggregator.toolTimeline(events: events)
        XCTAssertEqual(timeline.map(\.id), [1, 3])
        XCTAssertEqual(timeline.map(\.toolName), ["Bash", "Read"])
    }

    // MARK: - swimLanes

    func testSwimLanesPreservesInputOrderAndMapsFields() {
        let a = Agent(
            id: "a", sessionId: "s1", name: "A", type: .main, subagentType: nil, status: .working,
            startedAt: "2024-01-01T00:00:00.000Z", endedAt: nil, updatedAt: "2024-01-01T00:00:00.000Z", parentAgentId: nil
        )
        let b = Agent(
            id: "b", sessionId: "s1", name: "B", type: .subagent, subagentType: "worker", status: .completed,
            startedAt: "2024-01-01T00:01:00.000Z", endedAt: "2024-01-01T00:02:00.000Z", updatedAt: "2024-01-01T00:02:00.000Z", parentAgentId: "a"
        )
        // Input order here is [a, b]; swimLanes must preserve it (the router
        // supplies rows already in `listAgentsBySession`'s `started_at DESC`
        // order — swimLanes itself does no re-sorting).
        let lanes = WorkflowAggregator.swimLanes(agents: [a, b])
        XCTAssertEqual(lanes.map(\.id), ["a", "b"])
        XCTAssertEqual(lanes[1].parentAgentId, "a")
        XCTAssertEqual(lanes[1].endedAt, "2024-01-01T00:02:00.000Z")
    }

    // MARK: - patterns

    func testPatternsDedupesRequiresCountAtLeastTwoAndComputesPercentage() {
        // 3 sessions with the same 2-step sequence. workflows.js counts a
        // full sequence AND its sliding sub-windows separately (lines
        // 389–407) — for an exactly-2-step sequence, the full-sequence pass
        // and the 2-step-window pass hit the *same* key, so the count is
        // doubled: 3 sessions -> patternCounts["review→build"] == 6 (a real
        // quirk of the Node code, preserved for 1:1 parity, not a bug here).
        // 1 session with a distinct single-occurrence 3-step sequence.
        // Same collision happens here: the 3-step full sequence and its
        // lone 3-step sliding window are the same key, so its count is 2
        // (survives the filter); its two 2-step sub-windows ("plan→ship",
        // "ship→deploy") only occur once each and are dropped.
        let sequences: [(sessionId: String, sequence: String)] = [
            ("s1", "review→build"),
            ("s2", "review→build"),
            ("s3", "review→build"),
            ("s4", "plan→ship→deploy"),
        ]
        let result = WorkflowAggregator.patterns(sequences: sequences, totalSessions: 4, soloCount: 0)

        XCTAssertTrue(result.patterns.contains { $0.steps == ["review", "build"] && $0.count == 6 })
        XCTAssertTrue(result.patterns.contains { $0.steps == ["plan", "ship", "deploy"] && $0.count == 2 })
        XCTAssertFalse(result.patterns.contains { $0.steps == ["plan", "ship"] })
        XCTAssertFalse(result.patterns.contains { $0.steps == ["ship", "deploy"] })
        XCTAssertFalse(result.patterns.contains { $0.count == 1 })
        let reviewBuild = result.patterns.first { $0.steps == ["review", "build"] }!
        XCTAssertEqual(reviewBuild.percentage, 150.0) // 6/4 * 100
        XCTAssertEqual(result.soloSessionCount, 0)
        XCTAssertEqual(result.soloPercentage, 0)
    }

    // MARK: - errorPropagation depth-0 fold

    func testErrorPropagationFoldsSessionLevelErrorsIntoExistingDepthZero() {
        let result = WorkflowAggregator.errorPropagation(
            byDepthRaw: [(depth: 0, count: 2), (depth: 1, count: 5)],
            sessionErrorsNotInAgents: 3,
            byType: [], eventErrors: [], sessionsWithErrors: 4, totalSessions: 8
        )
        XCTAssertEqual(result.byDepth.first { $0.depth == 0 }?.count, 5) // 2 + 3
        XCTAssertEqual(result.byDepth.first { $0.depth == 1 }?.count, 5)
        XCTAssertEqual(result.errorRate, 50.0) // 4/8 * 100
    }

    func testErrorPropagationPrependsDepthZeroWhenAbsent() {
        let result = WorkflowAggregator.errorPropagation(
            byDepthRaw: [(depth: 1, count: 5)],
            sessionErrorsNotInAgents: 2,
            byType: [], eventErrors: [], sessionsWithErrors: 0, totalSessions: 0
        )
        XCTAssertEqual(result.byDepth.first?.depth, 0)
        XCTAssertEqual(result.byDepth.first?.count, 2)
        XCTAssertEqual(result.errorRate, 0) // totalSessions == 0 guard
    }

    // MARK: - concurrency

    /// Rows whose session has zero/negative duration (`sessDur <= 0`) are
    /// skipped entirely — workflows.js line 591.
    func testConcurrencySkipsZeroDurationSessions() {
        let lanes: [(type: String, subagentType: String?, name: String, status: String, startedAt: String?, endedAt: String?, sessionStart: String?, sessionEnd: String?)] = [
            (type: "main", subagentType: nil, name: "Main", status: "completed",
             startedAt: "2024-01-01T00:00:00.000Z", endedAt: "2024-01-01T00:00:00.000Z",
             sessionStart: "2024-01-01T00:00:00.000Z", sessionEnd: "2024-01-01T00:00:00.000Z"), // zero-duration session, skipped
            (type: "subagent", subagentType: "worker", name: "Worker", status: "completed",
             startedAt: "2024-01-01T00:00:30.000Z", endedAt: "2024-01-01T00:01:00.000Z",
             sessionStart: "2024-01-01T00:00:00.000Z", sessionEnd: "2024-01-01T00:02:00.000Z"),
        ]
        let result = WorkflowAggregator.concurrency(lanes: lanes)
        XCTAssertEqual(result.aggregateLanes.count, 1)
        XCTAssertEqual(result.aggregateLanes[0].name, "worker")
        XCTAssertEqual(result.aggregateLanes[0].avgStart, 0.25, accuracy: 0.001) // 30s / 120s
        XCTAssertEqual(result.aggregateLanes[0].avgEnd, 0.5, accuracy: 0.001) // 60s / 120s
    }

    // MARK: - round1 boundary values

    func testRound1RoundsHalfAwayFromZero() {
        XCTAssertEqual(WorkflowAggregator.round1(2.25), 2.3, accuracy: 0.0001)
        XCTAssertEqual(WorkflowAggregator.round1(2.24), 2.2, accuracy: 0.0001)
        XCTAssertEqual(WorkflowAggregator.round1(0), 0, accuracy: 0.0001)
    }
}
