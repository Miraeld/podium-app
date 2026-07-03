// HooksRouter.swift — port of dashboard/server/routes/hooks.js's Express
// route (`router.post("/event", ...)`, lines 1014–1055): the thin HTTP shell
// around `IngestEngine.process`. Parses `{hook_type, data}` leniently, runs
// the engine, fans out its broadcasts over the WS hub, and responds fast.
//
// NOT YET MOUNTED: this RouterMount must be added to the `mounts:` array
// PodiumServerCLI's `main.swift` passes to `PodiumServerLifecycle.run` (that
// file is owned by another dev in this checkout per the task's concurrency
// fence — flagged in the task report, not wired here).
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

import Foundation
import Hummingbird
import HummingbirdWebSocket
import PodiumCore

public enum HooksRouterMount: RouterMount {
    public static func mount(on router: PodiumRouter, context: ServerContext) {
        let engine = IngestEngine(store: context.store, transcriptSource: TranscriptCacheTokenSource())
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
                return try JSONResponse(status: .badRequest, ErrorResponse("Invalid request body"))
            }

            guard let (hookType, data) = Self.parsePayload(bodyData) else {
                return try JSONResponse(
                    status: .badRequest,
                    HookErrorResponse(error: HookErrorDetail(code: "INVALID_INPUT", message: "hook_type and data are required"))
                )
            }

            let broadcasts = engine.process(hookType: hookType, data: data)
            guard let last = broadcasts.last, last.type == "new_event" else {
                // Engine no-op'd (e.g. missing session_id in `data`) — mirrors
                // hooks.js's `if (!result) return res.status(400)...`.
                return try JSONResponse(
                    status: .badRequest,
                    HookErrorResponse(error: HookErrorDetail(code: "MISSING_SESSION", message: "session_id is required in data"))
                )
            }

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

/// `{"error": {"code": ..., "message": ...}}` — hooks.js's structured error
/// body shape for this route specifically (distinct from the flat
/// `{"error": "..."}` shape `ErrorResponse` provides for other routers).
struct HookErrorResponse: Encodable {
    let error: HookErrorDetail
}

struct HookErrorDetail: Encodable {
    let code: String
    let message: String
}
