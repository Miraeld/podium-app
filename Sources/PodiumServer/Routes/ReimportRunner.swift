// ReimportRunner.swift — dependency-injection seam for `POST
// /api/settings/reimport` (routes/settings.js lines 139–151: `const {
// importAllSessions } = require("../../scripts/import-history"); ... const
// result = await importAllSessions(dbModule); res.json({ ok: true, ...result
// });`).
//
// P3.3 (this router) does NOT implement legacy-history import — that's
// `Discovery/LegacyImporter.swift`, owned by the parallel P3.2 agent. This
// protocol is the seam the orchestrator wires a concrete `LegacyImporter`
// adapter into after both land: construct a small conformance (e.g. in
// PodiumServerCLI/main.swift or wherever `ServerContext` is assembled) that
// calls into `LegacyImporter` and maps its result to `ReimportResult`, then
// pass it as `ServerContext(..., reimportRunner: thatAdapter)`.
//
// Until wired, `ServerContext.reimportRunner` defaults to `nil` and
// `SettingsRouterMount` responds `503 { error: { code: "NOT_IMPLEMENTED" } }`
// instead of guessing at import semantics.

import Foundation

/// Minimal seam over "re-import legacy Claude Code sessions from disk into
/// the store" — one method, no assumptions about *how* that happens.
public protocol ReimportRunner: Sendable {
    /// Runs a full legacy-history import pass and returns its tally.
    /// Mirrors `import-history.js`'s `importAllSessions(dbModule)` return
    /// shape (`{ imported, skipped, errors }`) so the HTTP response stays
    /// wire-compatible with the Node dashboard's `res.json({ ok: true,
    /// ...result })`.
    func run() async throws -> ReimportResult
}

/// Port of `importAllSessions`'s return value (import-history.js line 1358
/// early-return `{ imported: 0, skipped: 0, errors: 0 }`, and the same three
/// counters accumulated through the full run).
public struct ReimportResult: Codable, Equatable, Sendable {
    public var imported: Int
    public var skipped: Int
    public var errors: Int

    public init(imported: Int, skipped: Int, errors: Int) {
        self.imported = imported
        self.skipped = skipped
        self.errors = errors
    }
}
