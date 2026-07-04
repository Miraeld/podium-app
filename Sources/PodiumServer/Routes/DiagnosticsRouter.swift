// DiagnosticsRouter — P4.4: GET /api/diagnostics.
//
// New endpoint (no Node reference — this is standalone-only). Answers "is
// the hook→server pipeline actually working?" at a glance: server runtime
// info (reusing `ServerRuntimeInfo`, P3.3), hook ingestion health (last
// event timestamp + latency, tracked by `DiagnosticsRecorder` — see that
// file's doc comment for the latency definition and why it's instrumented
// at the router layer rather than inside `IngestEngine`), and a bounded
// rolling log of recent hook activity.
//
// NOT YET MOUNTED: this RouterMount must be added to the `mounts:` array
// PodiumServerCLI's `main.swift` / `PodiumApp/EmbeddedServer.swift` pass —
// both files are owned by the orchestrator this task, per the fence. Mount
// type name: `DiagnosticsRouterMount`.

import Foundation
import Hummingbird
import PodiumCore

public enum DiagnosticsRouterMount: RouterMount {
    public static func mount(on router: PodiumRouter, context: ServerContext) {
        router.get("/api/diagnostics") { req, ctx in try await get(req, ctx, context: context) }
    }

    private static func get(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let recorder = DiagnosticsRecorder.shared
        let health = await recorder.hookHealth()
        let logEntries = await recorder.recentLog(limit: req.uri.queryInt("log_limit", fallback: 100))

        let server = DiagnosticsResponse.ServerInfo(
            uptimeSeconds: ServerRuntimeInfo.uptimeSeconds,
            platform: ServerRuntimeInfo.platform,
            arch: ServerRuntimeInfo.arch,
            cpuCount: ServerRuntimeInfo.cpuCount,
            loadAverages: ServerRuntimeInfo.loadAverages,
            residentMemoryBytes: ServerRuntimeInfo.residentMemoryBytes,
            totalMemoryBytes: ServerRuntimeInfo.totalMemoryBytes
        )

        let hookHealth = DiagnosticsResponse.HookHealth(
            status: DiagnosticsResponse.HookHealth.deriveStatus(lastEventAt: health.lastEventAt),
            lastEventAt: health.lastEventAt,
            lastLatencySeconds: health.lastLatencySeconds,
            averageLatencySeconds: health.averageLatencySeconds,
            totalEventsProcessed: health.totalEventsProcessed,
            totalEventsFailed: health.totalEventsFailed
        )

        let response = DiagnosticsResponse(server: server, hooks: hookHealth, log: logEntries)
        return try JSONResponse(response)
    }
}
