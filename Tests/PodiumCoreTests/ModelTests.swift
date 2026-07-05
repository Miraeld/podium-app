import XCTest
@testable import PodiumCore

/// Fixture round-trip tests for every PodiumCore wire model. Fixtures are
/// hand-written JSON literals derived from
/// dashboard/client/src/lib/types.ts (the React client's type catalog) —
/// NOT captured by running the Node server, per the task instructions.
///
/// Each test decodes a literal snake_case JSON fixture, asserts the parsed
/// Swift values, then re-encodes and asserts the JSON round-trips back to
/// (at minimum) the same key/value pairs.
final class ModelTests: XCTestCase {
    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try PodiumJSON.decoder.decode(type, from: Data(json.utf8))
    }

    private func encodeToObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try PodiumJSON.encoder.encode(value)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj ?? [:]
    }

    // MARK: - PodiumDate

    func testPodiumDateFormatsWithMilliseconds() {
        let date = PodiumDate.parse("2024-01-01T00:00:00.000Z")
        XCTAssertNotNil(date)
        XCTAssertEqual(PodiumDate.format(date!), "2024-01-01T00:00:00.000Z")
    }

    func testPodiumDateAcceptsNonFractionalOnDecode() {
        let date = PodiumDate.parse("2024-01-01T00:00:00Z")
        XCTAssertNotNil(date)
    }

    // MARK: - LenientRawValue

    func testLenientRawValueDecodesKnownStatus() throws {
        let value = try decode(LenientRawValue<SessionStatus>.self, "\"active\"")
        XCTAssertEqual(value.knownValue, .active)
        XCTAssertEqual(value.rawValue, "active")
    }

    func testLenientRawValueDecodesUnknownStatusWithoutThrowing() throws {
        // Simulates an old/foreign dashboard.db with a status value this
        // build doesn't know about — must decode, not throw.
        let value = try decode(LenientRawValue<SessionStatus>.self, "\"idle\"")
        XCTAssertNil(value.knownValue)
        XCTAssertEqual(value.rawValue, "idle")

        let obj = try encodeToObject(["status": value])
        XCTAssertEqual(obj["status"] as? String, "idle")
    }

    // MARK: - Session

    func testSessionRoundTrip() throws {
        let json = """
        {
          "id": "sess_1",
          "name": "Test Session",
          "status": "active",
          "cwd": "/Users/gael/project",
          "model": "claude-sonnet-4-6",
          "started_at": "2024-01-01T00:00:00.000Z",
          "ended_at": null,
          "metadata": null,
          "agent_count": 3,
          "last_activity": "2024-01-01T00:05:00.000Z",
          "cost": 0.42,
          "awaiting_input_since": null
        }
        """
        let session = try decode(Session.self, json)
        XCTAssertEqual(session.id, "sess_1")
        XCTAssertEqual(session.name, "Test Session")
        XCTAssertEqual(session.status.knownValue, .active)
        XCTAssertEqual(session.cwd, "/Users/gael/project")
        XCTAssertEqual(session.startedAt, "2024-01-01T00:00:00.000Z")
        XCTAssertEqual(session.startedAtDate, PodiumDate.parse("2024-01-01T00:00:00.000Z"))
        XCTAssertEqual(session.agentCount, 3)
        XCTAssertEqual(session.cost, 0.42)
        XCTAssertNil(session.awaitingInputSince)
        XCTAssertFalse(session.isAwaitingInput)

        let obj = try encodeToObject(session)
        XCTAssertEqual(obj["id"] as? String, "sess_1")
        XCTAssertEqual(obj["status"] as? String, "active")
        XCTAssertEqual(obj["started_at"] as? String, "2024-01-01T00:00:00.000Z")
        XCTAssertEqual(obj["agent_count"] as? Int, 3)
    }

    func testSessionAwaitingInputDerivedFlag() throws {
        let json = """
        {
          "id": "sess_2",
          "name": null,
          "status": "active",
          "cwd": null,
          "model": null,
          "started_at": "2024-01-01T00:00:00.000Z",
          "ended_at": null,
          "metadata": null,
          "awaiting_input_since": "2024-01-01T00:01:00.000Z"
        }
        """
        let session = try decode(Session.self, json)
        XCTAssertTrue(session.isAwaitingInput)
    }

    func testSessionUnknownStatusDoesNotThrow() throws {
        let json = """
        {
          "id": "sess_legacy",
          "name": null,
          "status": "idle",
          "cwd": null,
          "model": null,
          "started_at": "2024-01-01T00:00:00.000Z",
          "ended_at": null,
          "metadata": null
        }
        """
        let session = try decode(Session.self, json)
        XCTAssertNil(session.status.knownValue)
        XCTAssertEqual(session.status.rawValue, "idle")
    }

    // MARK: - Agent

    func testAgentRoundTrip() throws {
        let json = """
        {
          "id": "agent_1",
          "session_id": "sess_1",
          "name": "main",
          "type": "main",
          "subagent_type": null,
          "status": "working",
          "task": null,
          "current_tool": "Bash",
          "started_at": "2024-01-01T00:00:00.000Z",
          "ended_at": null,
          "updated_at": "2024-01-01T00:00:05.000Z",
          "parent_agent_id": null,
          "metadata": null,
          "awaiting_input_since": null
        }
        """
        let agent = try decode(Agent.self, json)
        XCTAssertEqual(agent.id, "agent_1")
        XCTAssertEqual(agent.sessionId, "sess_1")
        XCTAssertEqual(agent.type.knownValue, .main)
        XCTAssertEqual(agent.status.knownValue, .working)
        XCTAssertEqual(agent.currentTool, "Bash")
        XCTAssertFalse(agent.isAwaitingInput)

        let obj = try encodeToObject(agent)
        XCTAssertEqual(obj["session_id"] as? String, "sess_1")
        XCTAssertEqual(obj["current_tool"] as? String, "Bash")
        XCTAssertEqual(obj["type"] as? String, "main")
    }

    func testAgentAwaitingInputIgnoredWhenCompleted() throws {
        let json = """
        {
          "id": "agent_2",
          "session_id": "sess_1",
          "name": "main",
          "type": "main",
          "subagent_type": null,
          "status": "completed",
          "task": null,
          "current_tool": null,
          "started_at": "2024-01-01T00:00:00.000Z",
          "ended_at": "2024-01-01T00:10:00.000Z",
          "updated_at": "2024-01-01T00:10:00.000Z",
          "parent_agent_id": null,
          "metadata": null,
          "awaiting_input_since": "2024-01-01T00:05:00.000Z"
        }
        """
        let agent = try decode(Agent.self, json)
        // Stale awaiting flag on a completed agent must not report as waiting.
        XCTAssertFalse(agent.isAwaitingInput)
    }

    func testAgentSubagentWithParent() throws {
        let json = """
        {
          "id": "agent_3",
          "session_id": "sess_1",
          "name": "code-reviewer",
          "type": "subagent",
          "subagent_type": "code-reviewer",
          "status": "waiting",
          "task": "Review the diff",
          "current_tool": null,
          "started_at": "2024-01-01T00:01:00.000Z",
          "ended_at": null,
          "updated_at": "2024-01-01T00:01:00.000Z",
          "parent_agent_id": "agent_1",
          "metadata": null
        }
        """
        let agent = try decode(Agent.self, json)
        XCTAssertEqual(agent.type.knownValue, .subagent)
        XCTAssertEqual(agent.subagentType, "code-reviewer")
        XCTAssertEqual(agent.parentAgentId, "agent_1")
    }

    // MARK: - DashboardEvent / EventFull

    func testDashboardEventRoundTrip() throws {
        let json = """
        {
          "id": 42,
          "session_id": "sess_1",
          "agent_id": "agent_1",
          "event_type": "PostToolUse",
          "tool_name": "Bash",
          "summary": "Ran tests",
          "data": "{\\"exit_code\\":0}",
          "created_at": "2024-01-01T00:00:10.000Z"
        }
        """
        let event = try decode(DashboardEvent.self, json)
        XCTAssertEqual(event.id, 42)
        XCTAssertEqual(event.eventType, "PostToolUse")
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertEqual(event.data, "{\"exit_code\":0}")

        let obj = try encodeToObject(event)
        XCTAssertEqual(obj["event_type"] as? String, "PostToolUse")
        XCTAssertEqual(obj["tool_name"] as? String, "Bash")
        XCTAssertEqual(obj["id"] as? Int, 42)
    }

    func testEventFullRoundTrip() throws {
        let json = """
        {
          "id": 42,
          "session_id": "sess_1",
          "agent_id": null,
          "event_type": "SessionStart",
          "tool_name": null,
          "summary": null,
          "data": "{\\"cwd\\":\\"/tmp\\"}",
          "created_at": "2024-01-01T00:00:00.000Z"
        }
        """
        let full = try decode(EventFull.self, json)
        XCTAssertEqual(full.id, 42)
        XCTAssertEqual(full.data, "{\"cwd\":\"/tmp\"}")
    }

    // MARK: - TokenUsage / ModelPricing / Cost

    func testTokenUsageRoundTripWithBaselines() throws {
        let json = """
        {
          "session_id": "sess_1",
          "model": "claude-sonnet-4-6",
          "input_tokens": 100,
          "output_tokens": 50,
          "cache_read_tokens": 20,
          "cache_write_tokens": 10,
          "baseline_input": 500,
          "baseline_output": 200,
          "baseline_cache_read": 0,
          "baseline_cache_write": 0
        }
        """
        let usage = try decode(TokenUsage.self, json)
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.baselineInput, 500)
        // Effective totals must sum current + baseline (post-compaction semantics).
        XCTAssertEqual(usage.effectiveInputTokens, 600)
        XCTAssertEqual(usage.effectiveOutputTokens, 250)

        let obj = try encodeToObject(usage)
        XCTAssertEqual(obj["cache_read_tokens"] as? Int, 20)
        XCTAssertEqual(obj["baseline_cache_write"] as? Int, 0)
    }

    func testModelPricingRoundTrip() throws {
        let json = """
        {
          "model_pattern": "claude-sonnet-4-6%",
          "display_name": "Claude Sonnet 4.6",
          "input_per_mtok": 3,
          "output_per_mtok": 15,
          "cache_read_per_mtok": 0.3,
          "cache_write_per_mtok": 3.75,
          "updated_at": "2024-01-01T00:00:00.000Z"
        }
        """
        let pricing = try decode(ModelPricing.self, json)
        XCTAssertEqual(pricing.id, "claude-sonnet-4-6%")
        XCTAssertEqual(pricing.inputPerMtok, 3)
        XCTAssertEqual(pricing.cacheWritePerMtok, 3.75)

        let obj = try encodeToObject(pricing)
        XCTAssertEqual(obj["model_pattern"] as? String, "claude-sonnet-4-6%")
        XCTAssertEqual(obj["cache_read_per_mtok"] as? Double, 0.3)
    }

    func testCostResultRoundTrip() throws {
        let json = """
        {
          "total_cost": 1.23,
          "breakdown": [
            {
              "model": "claude-sonnet-4-6",
              "input_tokens": 1000,
              "output_tokens": 500,
              "cache_read_tokens": 100,
              "cache_write_tokens": 50,
              "cost": 1.23,
              "matched_rule": "claude-sonnet-4-6%"
            }
          ],
          "daily_costs": [
            { "date": "2024-01-01", "cost": 1.23 }
          ]
        }
        """
        let result = try decode(CostResult.self, json)
        XCTAssertEqual(result.totalCost, 1.23)
        XCTAssertEqual(result.breakdown.count, 1)
        XCTAssertEqual(result.breakdown[0].matchedRule, "claude-sonnet-4-6%")
        XCTAssertEqual(result.dailyCosts[0].date, "2024-01-01")

        let obj = try encodeToObject(result)
        XCTAssertEqual(obj["total_cost"] as? Double, 1.23)
    }

    // MARK: - Stats / SessionStats / Analytics

    func testStatsRoundTrip() throws {
        let json = """
        {
          "total_sessions": 10,
          "active_sessions": 2,
          "active_agents": 3,
          "total_agents": 25,
          "total_events": 500,
          "events_today": 12,
          "ws_connections": 1,
          "agents_by_status": { "working": 2, "completed": 20 },
          "sessions_by_status": { "active": 2, "completed": 8 }
        }
        """
        let stats = try decode(Stats.self, json)
        XCTAssertEqual(stats.totalSessions, 10)
        XCTAssertEqual(stats.agentsByStatus["working"], 2)

        let obj = try encodeToObject(stats)
        XCTAssertEqual(obj["ws_connections"] as? Int, 1)
        XCTAssertEqual(obj["events_today"] as? Int, 12)
    }

    func testSessionStatsRoundTrip() throws {
        let json = """
        {
          "session_id": "sess_1",
          "total_events": 42,
          "events_by_type": [{ "event_type": "PostToolUse", "count": 10 }],
          "tools_used": [{ "tool_name": "Bash", "count": 5 }],
          "error_count": 0,
          "first_event_at": "2024-01-01T00:00:00.000Z",
          "last_event_at": "2024-01-01T00:10:00.000Z",
          "agents": {
            "total": 3, "main": 1, "subagent": 2, "compaction": 0,
            "by_status": { "completed": 3 }
          },
          "subagent_types": [{ "subagent_type": "code-reviewer", "count": 1 }],
          "tokens": {
            "input_tokens": 100, "output_tokens": 50,
            "cache_read_tokens": 10, "cache_write_tokens": 5
          }
        }
        """
        let stats = try decode(SessionStats.self, json)
        XCTAssertEqual(stats.sessionId, "sess_1")
        XCTAssertEqual(stats.agents.total, 3)
        XCTAssertEqual(stats.tokens.cacheReadTokens, 10)
        XCTAssertEqual(stats.subagentTypes.first?.subagentType, "code-reviewer")

        let obj = try encodeToObject(stats)
        XCTAssertEqual(obj["session_id"] as? String, "sess_1")
        let agentsObj = obj["agents"] as? [String: Any]
        XCTAssertEqual(agentsObj?["by_status"] as? [String: Int], ["completed": 3])
    }

    func testAnalyticsRoundTrip() throws {
        let json = """
        {
          "tokens": {
            "total_input": 1000, "total_output": 500,
            "total_cache_read": 100, "total_cache_write": 50
          },
          "tool_usage": [{ "tool_name": "Bash", "count": 20 }],
          "daily_events": [{ "date": "2024-01-01", "count": 30 }],
          "daily_sessions": [{ "date": "2024-01-01", "count": 3 }],
          "agent_types": [{ "subagent_type": "code-reviewer", "count": 5 }],
          "event_types": [{ "event_type": "PostToolUse", "count": 100 }],
          "avg_events_per_session": 12.5,
          "total_subagents": 8,
          "overview": {
            "total_sessions": 10, "active_sessions": 2, "active_agents": 3,
            "total_agents": 25, "total_events": 500
          },
          "agents_by_status": { "working": 3 },
          "sessions_by_status": { "active": 2 }
        }
        """
        let analytics = try decode(Analytics.self, json)
        XCTAssertEqual(analytics.tokens.totalCacheRead, 100)
        XCTAssertEqual(analytics.avgEventsPerSession, 12.5)
        XCTAssertEqual(analytics.overview.totalSessions, 10)

        let obj = try encodeToObject(analytics)
        let tokensObj = obj["tokens"] as? [String: Any]
        XCTAssertEqual(tokensObj?["total_cache_write"] as? Int, 50)
        XCTAssertEqual(obj["avg_events_per_session"] as? Double, 12.5)
    }

    // MARK: - Workflows

    func testWorkflowDetailRoundTrip() throws {
        let json = """
        {
          "session": {
            "id": "sess_1", "name": "Test", "status": "active", "cwd": null,
            "model": null, "started_at": "2024-01-01T00:00:00.000Z",
            "ended_at": null, "metadata": null
          },
          "tree": [
            {
              "id": "agent_1", "name": "main", "type": "main",
              "subagent_type": null, "status": "completed", "task": null,
              "started_at": "2024-01-01T00:00:00.000Z",
              "ended_at": "2024-01-01T00:05:00.000Z",
              "children": [
                {
                  "id": "agent_2", "name": "code-reviewer", "type": "subagent",
                  "subagent_type": "code-reviewer", "status": "completed",
                  "task": "Review", "started_at": "2024-01-01T00:01:00.000Z",
                  "ended_at": "2024-01-01T00:02:00.000Z", "children": []
                }
              ]
            }
          ],
          "tool_timeline": [
            {
              "id": 1, "tool_name": "Bash", "event_type": "PostToolUse",
              "agent_id": "agent_1", "created_at": "2024-01-01T00:00:10.000Z",
              "summary": "ran tests"
            }
          ],
          "swim_lanes": [
            {
              "id": "agent_1", "name": "main", "type": "main",
              "subagent_type": null, "status": "completed",
              "started_at": "2024-01-01T00:00:00.000Z",
              "ended_at": "2024-01-01T00:05:00.000Z", "parent_agent_id": null
            }
          ],
          "events": []
        }
        """
        let detail = try decode(WorkflowDetail.self, json)
        XCTAssertEqual(detail.tree.count, 1)
        XCTAssertEqual(detail.tree[0].children.count, 1)
        XCTAssertEqual(detail.tree[0].children[0].subagentType, "code-reviewer")
        XCTAssertEqual(detail.swimLanes[0].id, "agent_1")
        XCTAssertEqual(detail.toolTimeline[0].toolName, "Bash")

        let obj = try encodeToObject(detail)
        XCTAssertNotNil(obj["swim_lanes"])
        XCTAssertNotNil(obj["tool_timeline"])
    }

    func testWorkflowSummaryDecodesNestedAggregates() throws {
        let json = """
        {
          "stats": {
            "total_sessions": 5, "total_agents": 20, "total_subagents": 15,
            "avg_subagents": 3, "success_rate": 0.9, "avg_depth": 2,
            "avg_duration_sec": 120, "total_compactions": 1,
            "avg_compactions": 0.2,
            "top_flow": { "source": "main", "target": "code-reviewer", "count": 4 }
          },
          "orchestration": {
            "session_count": 5, "main_count": 5,
            "subagent_types": [{ "subagent_type": "code-reviewer", "count": 4, "completed": 4, "errors": 0 }],
            "edges": [{ "source": "main", "target": "code-reviewer", "weight": 4 }],
            "outcomes": [{ "status": "completed", "count": 4 }],
            "compactions": { "total": 1, "sessions": 1 }
          },
          "tool_flow": {
            "transitions": [{ "source": "Bash", "target": "Read", "value": 3 }],
            "tool_counts": [{ "tool_name": "Bash", "count": 10 }]
          },
          "effectiveness": [
            {
              "subagent_type": "code-reviewer", "total": 4, "completed": 4,
              "errors": 0, "sessions": 3, "success_rate": 1.0,
              "avg_duration": 60, "trend": [1, 1, 1]
            }
          ],
          "patterns": {
            "patterns": [{ "steps": ["main", "code-reviewer"], "count": 3, "percentage": 60 }],
            "solo_session_count": 2, "solo_percentage": 40
          },
          "model_delegation": {
            "main_models": [{ "model": "claude-sonnet-4-6", "agent_count": 5, "session_count": 5 }],
            "subagent_models": [{ "model": "claude-sonnet-4-6", "agent_count": 4 }],
            "tokens_by_model": [
              { "model": "claude-sonnet-4-6", "input_tokens": 100, "output_tokens": 50, "cache_read_tokens": 10, "cache_write_tokens": 5 }
            ]
          },
          "error_propagation": {
            "by_depth": [{ "depth": 0, "count": 1 }],
            "by_type": [{ "subagent_type": "code-reviewer", "count": 0 }],
            "event_errors": [],
            "sessions_with_errors": 0, "total_sessions": 5, "error_rate": 0
          },
          "concurrency": {
            "aggregate_lanes": [{ "name": "main", "avg_start": 0, "avg_end": 100, "count": 5 }]
          },
          "complexity": [
            { "id": "sess_1", "name": "Test", "status": "completed", "duration": 120, "agent_count": 4, "subagent_count": 3, "total_tokens": 200, "model": "claude-sonnet-4-6" }
          ],
          "compaction": {
            "total_compactions": 1, "tokens_recovered": 500,
            "per_session": [{ "session_id": "sess_1", "compactions": 1 }],
            "sessions_with_compactions": 1, "total_sessions": 5
          },
          "cooccurrence": [{ "source": "Bash", "target": "Read", "weight": 3 }]
        }
        """
        let summary = try decode(WorkflowSummary.self, json)
        XCTAssertEqual(summary.stats.totalSessions, 5)
        XCTAssertEqual(summary.stats.topFlow?.target, "code-reviewer")
        XCTAssertEqual(summary.orchestration.edges.first?.weight, 4)
        XCTAssertEqual(summary.toolFlow.transitions.first?.value, 3)
        XCTAssertEqual(summary.effectiveness.first?.trend, [1, 1, 1])
        XCTAssertEqual(summary.patterns.patterns.first?.steps, ["main", "code-reviewer"])
        XCTAssertEqual(summary.modelDelegation.tokensByModel.first?.cacheReadTokens, 10)
        XCTAssertEqual(summary.compaction.tokensRecovered, 500)
        XCTAssertEqual(summary.cooccurrence.first?.weight, 3)
    }

    // MARK: - Push (p256dh must round-trip exactly)

    func testPushSubscriptionPreservesP256dhKeyExactly() throws {
        let json = """
        {
          "endpoint": "https://fcm.googleapis.com/fcm/send/abc123",
          "p256dh": "BEl62iUYgUivxIkv69yViEuiBIa1HI0DUnE2SCkxUsX1n8ycZ5m3fY4",
          "auth": "tBHItJI5svbpez7KI4CCXg==",
          "created_at": "2024-01-01T00:00:00.000Z"
        }
        """
        let sub = try decode(PushSubscription.self, json)
        XCTAssertEqual(sub.p256dh, "BEl62iUYgUivxIkv69yViEuiBIa1HI0DUnE2SCkxUsX1n8ycZ5m3fY4")
        XCTAssertEqual(sub.auth, "tBHItJI5svbpez7KI4CCXg==")
        // Regression: created_at (an underscore-boundary key) must decode
        // through PodiumJSON's .convertFromSnakeCase, not silently become
        // nil — see the CodingKeys pitfall documented on PushSubscription.
        XCTAssertEqual(sub.createdAt, "2024-01-01T00:00:00.000Z")

        let obj = try encodeToObject(sub)
        // Must NOT become "p_256_dh" or similar under convertToSnakeCase.
        XCTAssertEqual(obj["p256dh"] as? String, sub.p256dh)
        XCTAssertNil(obj["p_256_dh"])
    }

    func testPushSubscribeRequestNestedKeys() throws {
        let json = """
        {
          "endpoint": "https://fcm.googleapis.com/fcm/send/xyz",
          "keys": {
            "p256dh": "BEl62iUYgUivxIkv69yViEuiBIa1HI0DUnE2SCkxUsX1n8ycZ5m3fY4",
            "auth": "tBHItJI5svbpez7KI4CCXg=="
          }
        }
        """
        let req = try decode(PushSubscribeRequest.self, json)
        XCTAssertEqual(req.keys.p256dh, "BEl62iUYgUivxIkv69yViEuiBIa1HI0DUnE2SCkxUsX1n8ycZ5m3fY4")

        let obj = try encodeToObject(req)
        let keysObj = obj["keys"] as? [String: Any]
        XCTAssertEqual(keysObj?["p256dh"] as? String, req.keys.p256dh)
    }

    func testVapidPublicKeyResponseRoundTrip() throws {
        let json = "{\"publicKey\":\"BN4GvZtEZiZuqFxSgV_c...\"}"
        let resp = try decode(VapidPublicKeyResponse.self, json)
        XCTAssertTrue(resp.publicKey.hasPrefix("BN4GvZtEZiZuqFxSgV_c"))
    }

    // MARK: - Run

    func testDashboardRunRoundTrip() throws {
        let json = """
        {
          "id": "run_1",
          "session_id": "sess_1",
          "mode": "conversation",
          "cwd": "/Users/gael/project",
          "model": "claude-sonnet-4-6",
          "permission_mode": "acceptEdits",
          "effort": null,
          "resume_session_id": null,
          "prompt_preview": "Fix the bug",
          "status": "completed",
          "exit_code": 0,
          "started_at": "2024-01-01T00:00:00.000Z",
          "ended_at": "2024-01-01T00:05:00.000Z"
        }
        """
        let run = try decode(DashboardRun.self, json)
        XCTAssertEqual(run.mode.knownValue, .conversation)
        XCTAssertEqual(run.status.knownValue, .completed)
        XCTAssertEqual(run.exitCode, 0)

        let obj = try encodeToObject(run)
        XCTAssertEqual(obj["session_id"] as? String, "sess_1")
        XCTAssertEqual(obj["permission_mode"] as? String, "acceptEdits")
    }

    func testRunHandleUsesEpochMillisecondsNotWireStrings() throws {
        let json = """
        {
          "id": "run_1",
          "pid": 1234,
          "mode": "headless",
          "cwd": "/tmp",
          "model": null,
          "permissionMode": "acceptEdits",
          "effort": null,
          "prompt": "echo hi",
          "argv": ["-p", "echo hi"],
          "resumeSessionId": null,
          "status": "running",
          "startedAt": 1704067200000,
          "endedAt": null,
          "exitCode": null,
          "signal": null,
          "error": null,
          "sessionId": null,
          "envelopeCount": 3,
          "stdoutTail": "hi\\n",
          "stderrTail": ""
        }
        """
        let handle = try decode(RunHandle.self, json)
        XCTAssertEqual(handle.startedAt, 1704067200000)
        XCTAssertNil(handle.endedAt)
        XCTAssertEqual(handle.argv, ["-p", "echo hi"])

        let obj = try encodeToObject(handle)
        XCTAssertEqual(obj["startedAt"] as? Double, 1704067200000)
    }

    func testRunCreateRequestRoundTrip() throws {
        let json = """
        {
          "prompt": "Implement feature X",
          "mode": "conversation",
          "cwd": "/Users/gael/project",
          "model": null,
          "resume_session_id": null,
          "effort": null,
          "permission_mode": "acceptEdits"
        }
        """
        let req = try decode(RunCreateRequest.self, json)
        XCTAssertEqual(req.mode, .conversation)
        XCTAssertEqual(req.permissionMode, .acceptEdits)
    }

    // MARK: - Search

    func testSearchResultRoundTrip() throws {
        // Matches the ACTUAL Node search.js response shape: a single flat
        // `results` array mixing session and event hits (not a
        // `{sessions, events}` split) — see routes/search.js lines 106–171.
        let json = """
        {
          "results": [
            { "type": "session", "session_id": "sess_1", "session_name": "Test", "cwd": "/tmp", "status": "active", "cost": 0.42, "started_at": "2024-01-01T00:00:00.000Z", "highlight": "<mark>Test</mark>" },
            { "type": "event", "session_id": "sess_1", "session_name": "Test", "event_id": 1, "event_type": "PostToolUse", "tool_name": "Bash", "summary": "ran ls", "created_at": "2024-01-01T00:00:01.000Z", "highlight": null }
          ],
          "total": 2
        }
        """
        let result = try decode(SearchResponse.self, json)
        XCTAssertEqual(result.total, 2)
        XCTAssertEqual(result.results.first?.type, "session")
        XCTAssertEqual(result.results.first?.highlight, "<mark>Test</mark>")
        XCTAssertEqual(result.results.last?.type, "event")
        XCTAssertEqual(result.results.last?.sessionId, "sess_1")
        XCTAssertEqual(result.results.last?.eventId, 1)
    }

    // MARK: - Transcript

    func testTranscriptMessageWithUsageRoundTrip() throws {
        let json = """
        {
          "type": "assistant",
          "timestamp": "2024-01-01T00:00:00.000Z",
          "content": [
            { "type": "text", "text": "Hello" },
            { "type": "tool_use", "name": "Bash", "id": "tu_1", "input": { "command": "ls" } }
          ],
          "model": "claude-sonnet-4-6",
          "usage": {
            "input_tokens": 100,
            "output_tokens": 50,
            "cache_read_input_tokens": 10,
            "cache_creation_input_tokens": 5
          }
        }
        """
        let message = try decode(TranscriptMessage.self, json)
        XCTAssertEqual(message.type, "assistant")
        XCTAssertEqual(message.content.count, 2)
        XCTAssertEqual(message.content[1].name, "Bash")
        XCTAssertEqual(message.usage?.cacheReadInputTokens, 10)
        XCTAssertEqual(message.usage?.cacheCreationInputTokens, 5)
    }

    func testTranscriptContentTruncatedInputPreview() throws {
        let json = """
        { "type": "tool_use", "name": "Write", "input": { "_truncated": "file_text: <2000 chars omitted>" } }
        """
        let content = try decode(TranscriptContent.self, json)
        XCTAssertEqual(content.truncatedPreview, "file_text: <2000 chars omitted>")
    }

    func testTranscriptResultRoundTrip() throws {
        let json = """
        {
          "messages": [],
          "total": 100,
          "has_more": true,
          "last_line": 50,
          "first_line": 1
        }
        """
        let result = try decode(TranscriptResult.self, json)
        XCTAssertTrue(result.hasMore)
        XCTAssertEqual(result.total, 100)
    }

    func testTranscriptInfoRoundTrip() throws {
        let json = """
        {
          "id": "main",
          "name": "Main conversation",
          "type": "main",
          "subagent_type": null,
          "has_transcript": true,
          "db_agent_id": "agent_1"
        }
        """
        let info = try decode(TranscriptInfo.self, json)
        XCTAssertTrue(info.hasTranscript)
        XCTAssertEqual(info.dbAgentId, "agent_1")
    }

    // MARK: - WebSocket envelope

    func testWSMessageEnvelopeRoundTrip() throws {
        let json = """
        {
          "type": "session_created",
          "data": { "id": "sess_1", "status": "active" },
          "timestamp": "2024-01-01T00:00:00.000Z"
        }
        """
        let message = try decode(WSMessage.self, json)
        XCTAssertEqual(message.type, "session_created")
        XCTAssertEqual(message.data.objectValue?["id"]?.stringValue, "sess_1")

        let obj = try encodeToObject(message)
        XCTAssertEqual(obj["type"] as? String, "session_created")
    }

    func testHealthResponseRoundTrip() throws {
        let json = "{\"status\":\"ok\",\"timestamp\":\"2024-01-01T00:00:00.000Z\"}"
        let health = try decode(HealthResponse.self, json)
        XCTAssertEqual(health.status, "ok")
        XCTAssertNotNil(health.timestampDate)
    }

    // MARK: - ServerInfo (multi-server discovery file)

    func testServerInfoRoundTrip() throws {
        let json = """
        {
          "port": 4820,
          "pid": 1234,
          "startedAt": "2024-01-01T00:00:00.000Z",
          "servers": [
            { "port": 4820, "pid": 1234, "startedAt": "2024-01-01T00:00:00.000Z" },
            { "port": 4821, "pid": 5678, "startedAt": "2024-01-01T00:01:00.000Z" }
          ]
        }
        """
        // NOTE: server-info.json is NOT snake_case (it's an internal file,
        // not an HTTP wire payload) — decode with plain JSONDecoder since
        // its keys (startedAt) are already camelCase.
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.port, 4820)
        XCTAssertEqual(info.servers.count, 2)
        XCTAssertEqual(info.servers[1].port, 4821)
    }

    // MARK: - Updates / Import progress / cc-config-changed

    func testUpdateStatusPayloadRoundTrip() throws {
        let json = """
        {
          "git_repo": true,
          "update_available": false,
          "repo_root": "/Users/gael/podium",
          "current_branch": "main",
          "tracks_canonical": true,
          "situation": "tracking_canonical",
          "commits_behind": 0
        }
        """
        let payload = try decode(UpdateStatusPayload.self, json)
        XCTAssertTrue(payload.gitRepo)
        XCTAssertEqual(payload.situation, .trackingCanonical)
        XCTAssertEqual(payload.commitsBehind, 0)
    }

    func testImportProgressMessageRoundTrip() throws {
        let json = """
        {
          "import_id": "imp_1",
          "phase": "extract_error",
          "source": "upload",
          "processed": 3,
          "total": 10,
          "counters": { "sessions": 3 }
        }
        """
        let progress = try decode(ImportProgressMessage.self, json)
        XCTAssertEqual(progress.phase, .extractError)
        XCTAssertEqual(progress.source, .upload)
        XCTAssertEqual(progress.counters?["sessions"], 3)
    }

    func testCcConfigChangedPayloadRoundTrip() throws {
        let json = """
        {
          "source": "fs",
          "action": "write",
          "scope": "user",
          "type": "skill",
          "name": "my-skill",
          "paths": ["/Users/gael/.claude/skills/my-skill.md"]
        }
        """
        let payload = try decode(CcConfigChangedPayload.self, json)
        XCTAssertEqual(payload.source, .fs)
        XCTAssertEqual(payload.action, .write)
        XCTAssertEqual(payload.paths?.first, "/Users/gael/.claude/skills/my-skill.md")
    }

    // MARK: - Settings info

    func testSettingsInfoResponseRoundTrip() throws {
        let json = """
        {
          "db": {
            "path": "/Users/gael/Library/Application Support/Podium/dashboard.db",
            "size": 102400,
            "counts": { "sessions": 10, "agents": 25 },
            "pragmas": {
              "journal_mode": "wal", "synchronous": 1, "auto_vacuum": 0,
              "encoding": "UTF-8", "foreign_keys": 1, "busy_timeout": 5000
            },
            "load_stats": { "m5": 1, "m15": 2, "h1": 5 }
          },
          "hooks": {
            "installed": true,
            "path": "/Users/gael/.claude/settings.json",
            "hooks": { "SessionStart": true, "SessionEnd": true }
          },
          "server": {
            "uptime": 1234.5,
            "node_version": "v20.0.0",
            "platform": "darwin",
            "ws_connections": 2,
            "memory": { "rss": 1000, "heapTotal": 500, "heapUsed": 300, "external": 50 },
            "cpu_load": [0.5, 0.4, 0.3],
            "arch": "arm64",
            "total_mem": 17179869184,
            "free_mem": 8589934592,
            "cpus": 8
          },
          "transcript_cache": { "size": 5, "maxSize": 100, "hits": 7, "misses": 3, "keys": ["a", "b"] }
        }
        """
        let info = try decode(SettingsInfoResponse.self, json)
        XCTAssertEqual(info.db.counts["sessions"], 10)
        XCTAssertEqual(info.db.pragmas.journalMode, "wal")
        XCTAssertTrue(info.hooks.installed)
        XCTAssertEqual(info.server.arch, "arm64")
        XCTAssertEqual(info.transcriptCache.size, 5)
        XCTAssertEqual(info.transcriptCache.maxSize, 100)
        XCTAssertEqual(info.server.memory.heapTotal, 500)
    }

    // MARK: - Export

    func testExportResponseRoundTrip() throws {
        let json = """
        {
          "exported_at": "2024-01-01T00:00:00.000Z",
          "sessions": [],
          "agents": [],
          "events": [],
          "token_usage": [],
          "model_pricing": []
        }
        """
        let export = try decode(ExportResponse.self, json)
        XCTAssertEqual(export.exportedAt, "2024-01-01T00:00:00.000Z")
        XCTAssertTrue(export.sessions.isEmpty)
    }

    // MARK: - Request bodies

    func testSessionCreateAndPatchRequests() throws {
        let createJSON = """
        { "id": "sess_new", "name": "New", "status": "active", "cwd": "/tmp", "model": null, "metadata": null }
        """
        let create = try decode(SessionCreateRequest.self, createJSON)
        XCTAssertEqual(create.status, .active)

        let patchJSON = "{\"name\":\"Renamed\",\"status\":\"completed\"}"
        let patch = try decode(SessionPatchRequest.self, patchJSON)
        XCTAssertEqual(patch.name, "Renamed")
        XCTAssertEqual(patch.status, .completed)
    }

    func testAgentCreateAndPatchRequests() throws {
        let createJSON = """
        { "session_id": "sess_1", "name": "reviewer", "type": "subagent", "subagent_type": "code-reviewer", "status": "working", "task": "Review PR", "parent_agent_id": "agent_1", "metadata": null }
        """
        let create = try decode(AgentCreateRequest.self, createJSON)
        XCTAssertEqual(create.type, .subagent)
        XCTAssertEqual(create.parentAgentId, "agent_1")

        let patchJSON = "{\"status\":\"completed\",\"ended_at\":\"2024-01-01T00:10:00.000Z\"}"
        let patch = try decode(AgentPatchRequest.self, patchJSON)
        XCTAssertEqual(patch.status, .completed)
        XCTAssertEqual(patch.endedAt, "2024-01-01T00:10:00.000Z")
    }

    func testPricingPutRequestRoundTrip() throws {
        let json = """
        {
          "model_pattern": "claude-opus-4-8%",
          "display_name": "Claude Opus 4.8",
          "input_per_mtok": 5,
          "output_per_mtok": 25,
          "cache_read_per_mtok": 0.5,
          "cache_write_per_mtok": 6.25
        }
        """
        let req = try decode(PricingPutRequest.self, json)
        XCTAssertEqual(req.modelPattern, "claude-opus-4-8%")
        XCTAssertEqual(req.outputPerMtok, 25)
    }
}
