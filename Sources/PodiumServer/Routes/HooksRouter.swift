// HooksRouter.swift — port of dashboard/server/routes/hooks.js's Express
// route (`router.post("/event", ...)`, lines 1014–1055): the thin HTTP shell
// around `IngestEngine.process`. Parses `{hook_type, data}` leniently, runs
// the engine, fans out its broadcasts over the WS hub, and responds fast.
//
// Mounted in both PodiumServerCLI's `main.swift` and PodiumApp's
// `EmbeddedServer.swift` (`HooksRouterMount` in each `mounts:` array).
//
// P3.1: `IngestEngine` is now wired to the real `TranscriptCacheTokenSource`
// (Sources/PodiumCore/Transcripts/) instead of the P2.3-era
// `NoOpTranscriptTokenSource` default — token usage, compaction markers, API
// errors, and turn-duration events are extracted from live transcripts.
//
// P3.2: after a SubagentStop event carrying a transcript_path, fires
// `LegacyImporter.scanAndImportSubagents` in a detached `Task` — port of
// hooks.js lines 1031–1054's fire-and-forget `.then()` chain. A subagent's
// own tool calls never fire hooks on the parent session; this sweep is the
// only path that attributes them to the subagent's own agent_id without
// waiting for the periodic sweep.
//
// P4.2: `IngestEngine`'s `Notifier` seam is wired to a real `PushNotifier`
// (VAPID web-push + native OS notification) instead of the P2.3-era
// `NoOpNotifier` default — session end/error, agent-stuck, and cost-spike
// transitions now actually alert the user. See
// `Sources/PodiumCore/Push/PushNotifier.swift`.
//
// P4.4: instrumented with `DiagnosticsRecorder.shared` — a single additive
// call bracketing `engine.process(...)` on success (`recordHookEvent`) and
// one on each router-level rejection (`recordHookFailure`). This is
// intentionally the ONLY diagnostics touch point in the ingestion path:
// `IngestEngine.swift` itself is untouched (off-limits this task — a
// parallel agent just fixed its notifier-vs-COMMIT ordering). Recording
// happens at the HTTP layer, after the engine has already returned, so it
// can never affect ingestion semantics or transaction ordering.
//
// B7 (pre-1.0 audit): this router previously used a locally-defined
// `HookErrorResponse{error: HookErrorDetail{code, message}}` type for its
// error responses — wire-identical to `CodedErrorResponse` but a separate
// declaration, plus one path (`Data.write` failure) used the flat
// `ErrorResponse("...")` shape instead. Verified neither `Sources/PodiumHook/
// main.swift` nor `Sources/PodiumCore/Hooks/HookClient.swift` parses the hook
// endpoint's response body at all (they only care that the process gets a
// timely response, per this file's fast-fail contract above) — no wire
// dependency on the old shape. All three error paths below now use the
// canonical `CodedErrorResponse` and the local duplicate types were removed.

import Foundation
import Hummingbird
import HummingbirdWebSocket
import PodiumCore

public enum HooksRouterMount: RouterMount {
    public static func mount(on router: PodiumRouter, context: ServerContext) {
        let engine = IngestEngine(
            store: context.store,
            transcriptSource: TranscriptCacheTokenSource(),
            notifier: PushNotifier(service: context.pushService)
        )
        let group = router.group("/api/hooks")

        group.post("/event") { request, requestContext -> JSONResponse in
            // Never 500 on garbage — the hook must never break Claude Code
            // (hooks.js's implicit contract: it always gets *some* HTTP
            // response back within its 1s per-request timeout). Any failure
            // to even parse the body still returns 400 with a small JSON
            // error body (matching hooks.js's explicit 400s), never a 5xx.
            let bodyData: Data
            do {
                bodyData = try await request.body.collect(upTo: 1024 * 1024)
                    .readableBytesView
                    .withUnsafeBytes { Data($0) }
            } catch {
                await DiagnosticsRecorder.shared.recordHookFailure(reason: "unreadable request body")
                return try JSONResponse(
                    status: .badRequest,
                    CodedErrorResponse(code: "INVALID_INPUT", message: "Invalid request body")
                )
            }

            guard let (hookType, data) = Self.parsePayload(bodyData) else {
                await DiagnosticsRecorder.shared.recordHookFailure(reason: "invalid payload (hook_type/data missing)")
                return try JSONResponse(
                    status: .badRequest,
                    CodedErrorResponse(code: "INVALID_INPUT", message: "hook_type and data are required")
                )
            }

            // P4.4: bracket the engine call to measure hook processing
            // latency from the router's point of view — see
            // DiagnosticsRecorder.swift's doc comment for why this is the
            // chosen latency definition (and why it's measured here, not
            // inside IngestEngine).
            let processingStart = Date()
            let broadcasts = engine.process(hookType: hookType, data: data)
            let latencySeconds = Date().timeIntervalSince(processingStart)

            guard let last = broadcasts.last, last.type == "new_event" else {
                // Engine no-op'd (e.g. missing session_id in `data`) — mirrors
                // hooks.js's `if (!result) return res.status(400)...`.
                await DiagnosticsRecorder.shared.recordHookFailure(reason: "session_id missing from hook data (\(hookType))")
                return try JSONResponse(
                    status: .badRequest,
                    CodedErrorResponse(code: "MISSING_SESSION", message: "session_id is required in data")
                )
            }

            let recordedSessionId = data.nonEmptyString("session_id") ?? "unknown"
            await DiagnosticsRecorder.shared.recordHookEvent(hookType: hookType, sessionId: recordedSessionId, latencySeconds: latencySeconds)

            // Fan broadcasts out over the WS hub AFTER we've decided the
            // response — mirrors hooks.js calling `res.json(...)` before the
            // (unrelated) async subagent-import kick-off, i.e. broadcasting
            // doesn't block the response being formed. We still await it
            // here since Hummingbird handlers are async end-to-end and
            // there's no meaningful "respond then continue working" split
            // without spawning a detached Task — which would risk the
              // process exiting (tests, short-lived CLI runs) before the
            // broadcast flushes. The added latency is microseconds (in-memory
            // fan-out to a handful of local WS connections).
            for broadcast in broadcasts {
                await context.broadcaster.broadcast(type: broadcast.type, data: broadcast.data)
            }

            // Fire-and-forget: scan the subagent's own JSONL for tool calls
            // that never fired a hook, and ingest whatever's missing. Never
            // blocks the response, never affects it on failure (parity with
            // hooks.js's detached `.then().catch(() => {})`).
            if hookType == "SubagentStop",
               let sessionId = data.nonEmptyString("session_id"),
               let transcriptPath = data.nonEmptyString("transcript_path") {
                let store = context.store
                let broadcaster = context.broadcaster
                Task.detached {
                    guard let result = try? LegacyImporter.scanAndImportSubagents(store: store, sessionId: sessionId, transcriptPath: transcriptPath),
                          result.created > 0 else { return }
                    await broadcaster.broadcast(type: "new_event", data: JSONValue.object([
                        "session_id": .string(sessionId), "agent_id": .null, "event_type": .string("SubagentJsonlImported"),
                        "tool_name": .null, "summary": .string("Imported \(result.created) subagent record(s) from JSONL"),
                        "created_at": .string(PodiumDate.now()),
                    ]))
                }
            }

            return try JSONResponse(HookEventOkResponse(ok: true, event: last.data))
        }
    }

    /// Lenient `{hook_type, data}` parse — accepts any valid JSON object with
    /// those two top-level keys; `data` may itself be any JSON shape (hooks.js
    /// does zero validation on `data`'s internal structure before handing it
    /// to `processEvent`). Returns `nil` for anything that isn't at least
    /// `{"hook_type": <non-empty string>, "data": <object>}` — mirrors
    /// hooks.js's `if (!hook_type || !data) return res.status(400)`.
    static func parsePayload(_ body: Data) -> (hookType: String, data: JSONValue)? {
        guard !body.isEmpty, let decoded = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            return nil
        }
        guard case .object(let root) = decoded else { return nil }
        guard case .string(let hookType)? = root["hook_type"], !hookType.isEmpty else { return nil }
        guard let dataValue = root["data"], dataValue.objectValue != nil else { return nil }
        return (hookType, dataValue)
    }
}

/// `{"ok": true, "event": {...}}` — hooks.js's success response shape
/// (`res.json({ ok: true, event: result })`).
struct HookEventOkResponse: Encodable {
    let ok: Bool
    let event: JSONValue
}
