import XCTest
@testable import PodiumCore

/// Coverage of `TranscriptCache` (port of dashboard/server/lib/transcript-
/// cache.js): token/compaction/error/turn-duration extraction from
/// hand-written JSONL fixtures, plus mtime+size cache invalidation
/// (incremental growth, shrink, same-size rewrite).
final class TranscriptCacheTests: XCTestCase {
    private var tempDir: URL!
    private var cache: TranscriptCache!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-transcript-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        cache = TranscriptCache()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ lines: [String], to name: String = "transcript.jsonl") throws -> String {
        let path = tempDir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    private func assistantLine(model: String, input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0) -> String {
        """
        {"type":"assistant","timestamp":"2026-07-03T10:00:00.000Z","message":{"model":"\(model)","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheWrite)}}}
        """
    }

    // MARK: - Basics

    func testExtractReturnsNilForMissingFile() {
        XCTAssertNil(cache.extract(path: tempDir.appendingPathComponent("nope.jsonl").path))
    }

    func testExtractReturnsNilForEmptyPath() {
        XCTAssertNil(cache.extract(path: ""))
    }

    func testExtractParsesSingleModelTokenUsageAndLatestModel() throws {
        let path = try write([
            assistantLine(model: "claude-sonnet-4-5", input: 100, output: 50),
            assistantLine(model: "claude-sonnet-4-5", input: 20, output: 10),
        ])

        let result = try XCTUnwrap(cache.extract(path: path))
        let tokens = try XCTUnwrap(result.tokensByModel["claude-sonnet-4-5"])
        XCTAssertEqual(tokens.inputTokens, 120)
        XCTAssertEqual(tokens.outputTokens, 60)
        XCTAssertEqual(result.latestModel, "claude-sonnet-4-5")
    }

    func testExtractMultiModelUsageAggregatesSeparatelyPerModel() throws {
        let path = try write([
            assistantLine(model: "claude-sonnet-4-5", input: 100, output: 50),
            assistantLine(model: "claude-opus-4-8", input: 10, output: 5),
            assistantLine(model: "claude-sonnet-4-5", input: 30, output: 15),
        ])

        let result = try XCTUnwrap(cache.extract(path: path))
        XCTAssertEqual(result.tokensByModel.count, 2)
        XCTAssertEqual(result.tokensByModel["claude-sonnet-4-5"]?.inputTokens, 130)
        XCTAssertEqual(result.tokensByModel["claude-opus-4-8"]?.inputTokens, 10)
        // JSONL is append-only/in-order — the LAST assistant entry's model wins.
        XCTAssertEqual(result.latestModel, "claude-sonnet-4-5")
    }

    func testExtractIgnoresSyntheticModelAndMissingUsage() throws {
        let path = try write([
            #"{"type":"assistant","message":{"model":"<synthetic>","content":[],"usage":{"input_tokens":999,"output_tokens":999}}}"#,
            #"{"type":"assistant","message":{"model":"claude-sonnet-4-5","content":[]}}"#,
        ])
        XCTAssertNil(cache.extract(path: path))
    }

    // MARK: - Compaction

    func testExtractCompactionEntriesAndExtractCompactionsHelper() throws {
        let path = try write([
            assistantLine(model: "claude-sonnet-4-5", input: 100, output: 50),
            #"{"isCompactSummary":true,"uuid":"compact-uuid-1","timestamp":"2026-07-03T11:00:00.000Z"}"#,
            assistantLine(model: "claude-sonnet-4-5", input: 10, output: 5),
        ])

        let result = try XCTUnwrap(cache.extract(path: path))
        XCTAssertEqual(result.compaction?.count, 1)
        XCTAssertEqual(result.compaction?.entries.first?.uuid, "compact-uuid-1")
        XCTAssertEqual(result.compaction?.entries.first?.timestamp, "2026-07-03T11:00:00.000Z")

        let compactions = cache.extractCompactions(path: path)
        XCTAssertEqual(compactions.count, 1)
        XCTAssertEqual(compactions.first?.uuid, "compact-uuid-1")
    }

    // MARK: - API errors

    func testExtractDetectsMessageTypeErrorEntries() throws {
        let path = try write([
            #"{"type":"user","timestamp":"2026-07-03T09:00:00.000Z","message":{"type":"error","error":{"type":"overloaded_error","message":"Service overloaded"}}}"#,
        ])
        let result = try XCTUnwrap(cache.extract(path: path))
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertEqual(result.errors.first?.type, "overloaded_error")
        XCTAssertEqual(result.errors.first?.message, "Service overloaded")
    }

    func testExtractDetectsIsApiErrorMessageEntries() throws {
        let path = try write([
            #"{"isApiErrorMessage":true,"error":"rate_limit_error","timestamp":"2026-07-03T09:05:00.000Z","message":{"content":[{"text":"Rate limited, please retry"}]}}"#,
        ])
        let result = try XCTUnwrap(cache.extract(path: path))
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertEqual(result.errors.first?.type, "rate_limit_error")
        XCTAssertEqual(result.errors.first?.message, "Rate limited, please retry")
    }

    // MARK: - Turn durations

    func testExtractCollectsTurnDurationSystemMessages() throws {
        let path = try write([
            #"{"type":"system","subtype":"turn_duration","durationMs":4200,"timestamp":"2026-07-03T09:10:00.000Z"}"#,
        ])
        let result = try XCTUnwrap(cache.extract(path: path))
        XCTAssertEqual(result.turnDurations.first?.durationMs, 4200)
        XCTAssertEqual(result.turnDurations.first?.timestamp, "2026-07-03T09:10:00.000Z")
    }

    // MARK: - Cache invalidation

    func testCacheHitReturnsSameResultWithoutReparsingWhenUnchanged() throws {
        let path = try write([assistantLine(model: "claude-sonnet-4-5", input: 100, output: 50)])
        _ = cache.extract(path: path)
        let before = cache.stats()
        _ = cache.extract(path: path)
        let after = cache.stats()
        XCTAssertEqual(after.hits, before.hits + 1)
        XCTAssertEqual(after.misses, before.misses)
    }

    func testCacheIncrementalReadMergesGrowthAcrossCalls() throws {
        let path = try write([assistantLine(model: "claude-sonnet-4-5", input: 100, output: 50)])
        let first = try XCTUnwrap(cache.extract(path: path))
        XCTAssertEqual(first.tokensByModel["claude-sonnet-4-5"]?.inputTokens, 100)

        // Append more lines — mtime+size grow, triggering an incremental
        // (not full) re-read that merges into the cached totals.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        handle.seekToEndOfFile()
        handle.write(Data((assistantLine(model: "claude-sonnet-4-5", input: 20, output: 10) + "\n").utf8))
        try handle.close()

        let second = try XCTUnwrap(cache.extract(path: path))
        XCTAssertEqual(second.tokensByModel["claude-sonnet-4-5"]?.inputTokens, 120)
        XCTAssertEqual(second.tokensByModel["claude-sonnet-4-5"]?.outputTokens, 60)
    }

    func testCacheShrinkTriggersFullReread() throws {
        let path = try write([
            assistantLine(model: "claude-sonnet-4-5", input: 100, output: 50),
            assistantLine(model: "claude-sonnet-4-5", input: 20, output: 10),
        ])
        let first = try XCTUnwrap(cache.extract(path: path))
        XCTAssertEqual(first.tokensByModel["claude-sonnet-4-5"]?.inputTokens, 120)

        // Truncate to a single line — file shrinks, forcing a full re-read
        // rather than treating the new bytes as an "incremental" delta.
        try (assistantLine(model: "claude-sonnet-4-5", input: 100, output: 50) + "\n")
            .write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)

        let second = try XCTUnwrap(cache.extract(path: path))
        XCTAssertEqual(second.tokensByModel["claude-sonnet-4-5"]?.inputTokens, 100)
    }

    func testInvalidateForcesReReadOnNextExtract() throws {
        let path = try write([assistantLine(model: "claude-sonnet-4-5", input: 100, output: 50)])
        _ = cache.extract(path: path)
        cache.invalidate(path: path)

        let before = cache.stats()
        _ = cache.extract(path: path)
        let after = cache.stats()
        // Invalidated entries can't cache-hit even though the file is
        // byte-for-byte unchanged — this shows up as a miss, not a hit.
        XCTAssertEqual(after.misses, before.misses + 1)
    }

    func testClearRemovesAllEntries() throws {
        let path = try write([assistantLine(model: "claude-sonnet-4-5", input: 100, output: 50)])
        _ = cache.extract(path: path)
        XCTAssertEqual(cache.size, 1)
        cache.clear()
        XCTAssertEqual(cache.size, 0)
    }

    // MARK: - TranscriptCacheTokenSource adapter

    func testTokenSourceAdapterMapsCacheResultToSeamShape() throws {
        let path = try write([
            assistantLine(model: "claude-sonnet-4-5", input: 100, output: 50),
            #"{"isCompactSummary":true,"uuid":"u1","timestamp":"2026-07-03T11:00:00.000Z"}"#,
        ])
        let source = TranscriptCacheTokenSource(cache: cache)
        let result = try XCTUnwrap(source.extract(path: path))
        XCTAssertEqual(result.tokensByModel["claude-sonnet-4-5"]?.inputTokens, 100)
        XCTAssertEqual(result.compactionEntries.first?.uuid, "u1")

        source.invalidate(path: path)
        XCTAssertEqual(cache.size, 0)
    }
}
