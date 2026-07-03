// TranscriptCacheTokenSource.swift — adapts `TranscriptCache`'s full
// extraction result (superset, matching transcript-cache.js's `extract()`
// shape) down to the `TranscriptTokenSource` seam `IngestEngine` consumes
// (IngestSeams.swift). Deliberately drops `thinkingBlockCount`/`usageExtras`
// — the ingestion path doesn't use them (see IngestSeams.swift's
// `TranscriptExtractResult` doc comment for why that's an accepted, documented
// omission rather than an oversight).
//
// Wired in at Sources/PodiumServer/Routes/HooksRouter.swift, replacing the
// P2.3-era `NoOpTranscriptTokenSource` default.

import Foundation

public struct TranscriptCacheTokenSource: TranscriptTokenSource {
    private let cache: TranscriptCache

    public init(cache: TranscriptCache = .shared) {
        self.cache = cache
    }

    public func extract(path: String) -> TranscriptExtractResult? {
        guard let result = cache.extract(path: path) else { return nil }
        return TranscriptExtractResult(
            tokensByModel: result.tokensByModel,
            compactionEntries: result.compaction?.entries ?? [],
            errors: result.errors,
            turnDurations: result.turnDurations,
            latestModel: result.latestModel
        )
    }

    public func invalidate(path: String) {
        cache.invalidate(path: path)
    }
}
