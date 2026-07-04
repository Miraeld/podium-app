// TranscriptCache.swift — port of dashboard/server/lib/transcript-cache.js:
// extracts per-model token usage, compaction markers, API errors, and
// turn-duration system messages from a Claude Code JSONL transcript, with
// mtime+size-based caching so repeated hook events against the same
// (append-only) transcript re-read only the newly appended bytes.
//
// DEVIATION from the Node source: transcript-cache.js's `_streamRange` reads
// the file in 4 MiB chunks specifically to avoid V8's ~512 MiB max string
// length when parsing huge transcripts. `Data`/`String` in Swift have no such
// ceiling, so this port reads each range directly via `Data(contentsOf:)` +
// `subdata(in:)` rather than re-implementing chunked byte-buffer scanning —
// behaviorally identical (same line-splitting, same trailing-partial-line
// handling at the end of a range), just simpler. The mtime+size cache
// invalidation, incremental-read-on-growth, full-reread-on-shrink-or-rewrite,
// LRU eviction, and per-array trim-to-tail semantics are all ported exactly.

import Foundation

/// Full extraction result for one transcript file — the Swift analogue of
/// transcript-cache.js's `extract()` return object. A superset of
/// `TranscriptExtractResult` (IngestSeams.swift), which is the trimmed-down
/// shape `IngestEngine` actually consumes; `TranscriptCacheTokenSource`
/// adapts one to the other.
public struct TranscriptCacheResult: Equatable, Sendable {
    public var tokensByModel: [String: TranscriptTokens]
    public var compaction: Compaction?
    public var errors: [TranscriptAPIError]
    public var turnDurations: [TranscriptTurnDuration]
    public var thinkingBlockCount: Int
    public var usageExtras: UsageExtras?
    public var latestModel: String?

    public struct Compaction: Equatable, Sendable {
        public var count: Int
        public var entries: [TranscriptCompactionEntry]
    }

    public struct UsageExtras: Equatable, Sendable {
        public var serviceTiers: [String]
        public var speeds: [String]
        public var inferenceGeos: [String]

        var isEmpty: Bool { serviceTiers.isEmpty && speeds.isEmpty && inferenceGeos.isEmpty }
    }

    public var isEmpty: Bool {
        tokensByModel.isEmpty && compaction == nil && errors.isEmpty && turnDurations.isEmpty
            && thinkingBlockCount == 0 && (usageExtras?.isEmpty ?? true) && latestModel == nil
    }
}

/// mtime+size-cached, incrementally-updated JSONL transcript parser. Safe to
/// share across concurrent hook POSTs — all state access is confined to a
/// private serial queue (same convention as `Database`, SQLite.swift).
public final class TranscriptCache: @unchecked Sendable {
    /// Process-wide default instance, used by `TranscriptCacheTokenSource`
    /// and (later) the settings-info `transcriptCache` stats block.
    public static let shared = TranscriptCache()

    /// Hard cap on each per-entry growable array (turnDurations, errors,
    /// compaction.entries, usageExtras lists), configurable via
    /// `TRANSCRIPT_CACHE_MAX_ARRAY_LEN` — parity with transcript-cache.js.
    private let maxArrayLen: Int
    private let parseTrimWatermark: Int
    private let maxEntries: Int

    private let queue = DispatchQueue(label: "com.podium.transcript-cache", qos: .userInitiated)
    private var cache: [String: CacheEntry] = [:]
    private var lruOrder: [String] = []
    private var hits = 0
    private var misses = 0

    /// Test-only counter: bumped every time `trimAtWatermarkIfNeeded` (the
    /// per-line, watermark-gated trim used inside `consumeLine`) actually
    /// performs a shift, as opposed to being a no-op below the watermark.
    /// Lets tests assert the amortized-O(1) behavior directly (how often the
    /// expensive trim runs) rather than only its externally-visible result,
    /// which `finalize`/`merge`'s unconditional trim would otherwise mask.
    var watermarkTrimExecutionCount = 0

    private struct CacheEntry {
        var mtime: Double
        var size: Int
        var bytesRead: Int
        var result: TranscriptCacheResult?
    }

    public init(maxEntries: Int = 200, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.maxEntries = maxEntries
        if let raw = environment["TRANSCRIPT_CACHE_MAX_ARRAY_LEN"], let parsed = Int(raw), parsed > 0 {
            self.maxArrayLen = parsed
        } else {
            self.maxArrayLen = 1000
        }
        self.parseTrimWatermark = self.maxArrayLen * 2
    }

    // MARK: - Public API

    /// `extract(transcriptPath)`. Returns `nil` if the file is missing,
    /// unreadable, or yields no signal at all.
    public func extract(path: String) -> TranscriptCacheResult? {
        guard !path.isEmpty else { return nil }
        return queue.sync { extractLocked(path: path) }
    }

    /// `extractCompactions(transcriptPath)` — reuses the same cache, no
    /// duplicate reads.
    public func extractCompactions(path: String) -> [TranscriptCompactionEntry] {
        extract(path: path)?.compaction?.entries ?? []
    }

    /// `invalidate(transcriptPath)`.
    public func invalidate(path: String) {
        queue.sync {
            cache.removeValue(forKey: path)
            if let idx = lruOrder.firstIndex(of: path) { lruOrder.remove(at: idx) }
        }
    }

    /// `clear()`.
    public func clear() {
        queue.sync {
            cache.removeAll()
            lruOrder.removeAll()
        }
    }

    /// Number of entries currently cached.
    public var size: Int {
        queue.sync { cache.count }
    }

    public struct Stats: Equatable, Sendable {
        public var size: Int
        public var maxSize: Int
        public var hits: Int
        public var misses: Int
        public var hitRate: Double
        public var keys: [String]
    }

    /// `stats()` — cache diagnostics for the settings-info endpoint.
    public func stats() -> Stats {
        queue.sync {
            let total = hits + misses
            let hitRate = total > 0 ? (Double(hits) / Double(total) * 100 * 10).rounded() / 10 : 0
            return Stats(size: cache.count, maxSize: maxEntries, hits: hits, misses: misses, hitRate: hitRate, keys: lruOrder)
        }
    }

    // MARK: - Core extract logic (transcript-cache.js `extract`)

    private func extractLocked(path: String) -> TranscriptCacheResult? {
        guard let stat = Self.statFile(path) else { return nil }
        let cached = cache[path]

        // Cache hit: file unchanged (same mtime + size).
        if let cached, cached.mtime == stat.mtime, cached.size == stat.size {
            hits += 1
            touch(path)
            return cached.result
        }

        misses += 1

        // File shrunk or first read → full re-read.
        if cached == nil || stat.size < cached!.bytesRead {
            let result = fullRead(path)
            setCache(path, CacheEntry(mtime: stat.mtime, size: stat.size, bytesRead: stat.size, result: result))
            return result
        }

        // File grew → incremental read from last position.
        if stat.size > cached!.bytesRead {
            guard let incremental = streamRange(path, from: cached!.bytesRead, to: stat.size) else {
                // Only whitespace/newlines appended (or file vanished mid-read).
                setCache(path, CacheEntry(mtime: stat.mtime, size: stat.size, bytesRead: stat.size, result: cached!.result))
                return cached!.result
            }
            let merged = merge(cached: cached!.result, incremental: incremental)
            let result: TranscriptCacheResult? = merged.isEmpty ? nil : merged
            setCache(path, CacheEntry(mtime: stat.mtime, size: stat.size, bytesRead: stat.size, result: result))
            return result
        }

        // Same size, different mtime — content may have been rewritten (compaction).
        let result = fullRead(path)
        setCache(path, CacheEntry(mtime: stat.mtime, size: stat.size, bytesRead: stat.size, result: result))
        return result
    }

    private func fullRead(_ path: String) -> TranscriptCacheResult? {
        guard let stat = Self.statFile(path) else { return nil }
        return streamRange(path, from: 0, to: stat.size)
    }

    /// Reads `[start, end)` of `path`, splits on `\n`, parses each complete
    /// line as JSON, and folds it into a fresh `ParseState`. Returns `nil`
    /// when the range yields zero complete/parseable lines with any signal
    /// (transcript-cache.js's "only whitespace appended" case), matching
    /// `_streamRange` returning an empty-but-non-nil state that callers then
    /// treat as "nothing new".
    private func streamRange(_ path: String, from start: Int, to end: Int) -> TranscriptCacheResult? {
        guard end > start else { return finalize(ParseState()) }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let data: Data
        do {
            try handle.seek(toOffset: UInt64(start))
            data = try handle.read(upToCount: end - start) ?? Data()
        } catch {
            return nil
        }

        var state = ParseState()
        var lineStart = data.startIndex
        for index in data.indices where data[index] == 0x0A {
            if index > lineStart {
                consumeLine(data.subdata(in: lineStart..<index), into: &state)
            }
            lineStart = data.index(after: index)
        }
        if lineStart < data.endIndex {
            consumeLine(data.subdata(in: lineStart..<data.endIndex), into: &state)
        }

        return finalize(state)
    }

    // MARK: - Line parsing (transcript-cache.js `_consumeLine`)

    private struct ParseState {
        var tokensByModel: [String: TranscriptTokens] = [:]
        var compaction: TranscriptCacheResult.Compaction?
        var errors: [TranscriptAPIError] = []
        var turnDurations: [TranscriptTurnDuration] = []
        var thinkingBlockCount = 0
        var serviceTiers: [String] = []
        var speeds: [String] = []
        var inferenceGeos: [String] = []
        var latestModel: String?
    }

    private func consumeLine(_ lineData: Data, into state: inout ParseState) {
        // Strip a trailing CR (CRLF line endings).
        var bytes = lineData
        if bytes.last == 0x0D { bytes.removeLast() }
        guard !bytes.isEmpty else { return }
        guard let entry = try? JSONDecoder().decode(JSONValue.self, from: bytes) else { return }

        if entry["isCompactSummary"]?.asBool == true {
            var compaction = state.compaction ?? .init(count: 0, entries: [])
            compaction.count += 1
            compaction.entries.append(TranscriptCompactionEntry(uuid: entry.nonEmptyString("uuid"), timestamp: entry.string("timestamp")))
            trimAtWatermarkIfNeeded(&compaction.entries)
            state.compaction = compaction
        }

        if entry.string("type") == "system", entry.string("subtype") == "turn_duration",
           let durationMs = entry["durationMs"]?.asInt, durationMs != 0 {
            state.turnDurations.append(TranscriptTurnDuration(timestamp: coerceTimestamp(entry["timestamp"]), durationMs: durationMs))
            trimAtWatermarkIfNeeded(&state.turnDurations)
        }

        // `const msg = entry.message || entry;`
        let msg = entry["message"] ?? entry

        if msg.string("type") == "error", let error = msg["error"] {
            let type = error.nonEmptyString("type") ?? "unknown_error"
            let message = error.nonEmptyString("message") ?? "Unknown API error"
            state.errors.append(TranscriptAPIError(
                type: type, message: message, timestamp: entry.string("timestamp"),
                raw: .object(["type": .string(type), "message": .string(message), "timestamp": entry["timestamp"] ?? .null])
            ))
            trimAtWatermarkIfNeeded(&state.errors)
            return
        }

        if entry["isApiErrorMessage"]?.asBool == true {
            let content = entry["message"]?["content"]?.asArray ?? []
            let rawText = content.first?["text"]?.asString
            let errText = rawText.map { String($0.prefix(500)) } ?? "Unknown error"
            let type = entry.nonEmptyString("error") ?? "unknown_error"
            state.errors.append(TranscriptAPIError(
                type: type, message: errText, timestamp: entry.string("timestamp"),
                raw: .object(["type": .string(type), "message": .string(errText), "timestamp": entry["timestamp"] ?? .null])
            ))
            trimAtWatermarkIfNeeded(&state.errors)
            return
        }

        guard let model = msg.nonEmptyString("model"), model != "<synthetic>", let usage = msg["usage"] else { return }
        state.latestModel = model
        var tokens = state.tokensByModel[model] ?? TranscriptTokens(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
        tokens.inputTokens += usage["input_tokens"]?.asInt ?? 0
        tokens.outputTokens += usage["output_tokens"]?.asInt ?? 0
        tokens.cacheReadTokens += usage["cache_read_input_tokens"]?.asInt ?? 0
        tokens.cacheWriteTokens += usage["cache_creation_input_tokens"]?.asInt ?? 0
        state.tokensByModel[model] = tokens

        if let tier = usage.nonEmptyString("service_tier"), !state.serviceTiers.contains(tier) {
            state.serviceTiers.append(tier)
        }
        if let speed = usage.nonEmptyString("speed"), !state.speeds.contains(speed) {
            state.speeds.append(speed)
        }
        if let geo = usage.nonEmptyString("inference_geo"), geo != "not_available", !state.inferenceGeos.contains(geo) {
            state.inferenceGeos.append(geo)
        }

        if let content = msg["content"]?.asArray {
            for block in content where block.string("type") == "thinking" {
                state.thinkingBlockCount += 1
            }
        }
    }

    /// `entry.timestamp` where `turn_duration` messages may carry a numeric
    /// epoch-ms timestamp instead of an ISO string (transcript-cache.js lines
    /// 300–304).
    private func coerceTimestamp(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .number(let ms):
            return PodiumDate.format(Date(timeIntervalSince1970: ms / 1000))
        case .string(let string):
            return string
        default:
            return nil
        }
    }

    private func finalize(_ state: ParseState) -> TranscriptCacheResult? {
        var errors = state.errors
        var turnDurations = state.turnDurations
        var compaction = state.compaction
        trimIfNeeded(&errors)
        trimIfNeeded(&turnDurations)
        if compaction != nil { trimIfNeeded(&compaction!.entries) }

        let usageExtras: TranscriptCacheResult.UsageExtras?
        if !state.serviceTiers.isEmpty || !state.speeds.isEmpty || !state.inferenceGeos.isEmpty {
            var serviceTiers = state.serviceTiers, speeds = state.speeds, inferenceGeos = state.inferenceGeos
            trimIfNeeded(&serviceTiers)
            trimIfNeeded(&speeds)
            trimIfNeeded(&inferenceGeos)
            usageExtras = .init(serviceTiers: serviceTiers, speeds: speeds, inferenceGeos: inferenceGeos)
        } else {
            usageExtras = nil
        }

        let result = TranscriptCacheResult(
            tokensByModel: state.tokensByModel,
            compaction: compaction,
            errors: errors,
            turnDurations: turnDurations,
            thinkingBlockCount: state.thinkingBlockCount,
            usageExtras: usageExtras,
            latestModel: state.latestModel
        )
        return result.isEmpty ? nil : result
    }

    /// `_trimArray` — unconditional trim to `maxArrayLen` whenever the array
    /// is over cap. Used at `finalize`/`merge` time (transcript-cache.js
    /// calls `_trimArray` directly, not gated by the watermark, once per
    /// extract/merge call — not once per line).
    private func trimIfNeeded<T>(_ array: inout [T]) {
        guard array.count > maxArrayLen else { return }
        array.removeFirst(array.count - maxArrayLen)
    }

    /// Amortized O(1) trim for the per-line hot path, matching
    /// transcript-cache.js's `_consumeLine` (`PARSE_TRIM_WATERMARK` usage):
    /// only actually shift the array back down to `maxArrayLen` once it has
    /// grown to the 2x watermark, not on every single append past
    /// `maxArrayLen`. Trimming unconditionally at cap would make every
    /// subsequent line on a long transcript pay an O(maxArrayLen)
    /// `removeFirst` shift; gating on the watermark means that cost is paid
    /// once per `maxArrayLen` new entries instead.
    private func trimAtWatermarkIfNeeded<T>(_ array: inout [T]) {
        guard array.count >= parseTrimWatermark else { return }
        array.removeFirst(array.count - maxArrayLen)
        watermarkTrimExecutionCount += 1
    }

    // MARK: - Merge (transcript-cache.js `_merge`)

    private func merge(cached: TranscriptCacheResult?, incremental: TranscriptCacheResult?) -> TranscriptCacheResult {
        var tokensByModel = cached?.tokensByModel ?? [:]
        if let incTokens = incremental?.tokensByModel {
            for (model, tokens) in incTokens {
                var existing = tokensByModel[model] ?? TranscriptTokens(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
                existing.inputTokens += tokens.inputTokens
                existing.outputTokens += tokens.outputTokens
                existing.cacheReadTokens += tokens.cacheReadTokens
                existing.cacheWriteTokens += tokens.cacheWriteTokens
                tokensByModel[model] = existing
            }
        }

        var compaction = cached?.compaction
        if let incCompaction = incremental?.compaction {
            if compaction == nil { compaction = .init(count: 0, entries: []) }
            compaction!.count += incCompaction.count
            compaction!.entries.append(contentsOf: incCompaction.entries)
            trimIfNeeded(&compaction!.entries)
        }

        var errors = cached?.errors ?? []
        if let incErrors = incremental?.errors, !incErrors.isEmpty {
            errors.append(contentsOf: incErrors)
            trimIfNeeded(&errors)
        }

        var turnDurations = cached?.turnDurations ?? []
        if let incTurns = incremental?.turnDurations, !incTurns.isEmpty {
            turnDurations.append(contentsOf: incTurns)
            trimIfNeeded(&turnDurations)
        }

        let thinkingBlockCount = (cached?.thinkingBlockCount ?? 0) + (incremental?.thinkingBlockCount ?? 0)

        var usageExtras = cached?.usageExtras
        if let incExtras = incremental?.usageExtras {
            var serviceTiers = usageExtras?.serviceTiers ?? []
            var speeds = usageExtras?.speeds ?? []
            var inferenceGeos = usageExtras?.inferenceGeos ?? []
            for tier in incExtras.serviceTiers where !serviceTiers.contains(tier) { serviceTiers.append(tier) }
            for speed in incExtras.speeds where !speeds.contains(speed) { speeds.append(speed) }
            for geo in incExtras.inferenceGeos where !inferenceGeos.contains(geo) { inferenceGeos.append(geo) }
            trimIfNeeded(&serviceTiers)
            trimIfNeeded(&speeds)
            trimIfNeeded(&inferenceGeos)
            usageExtras = .init(serviceTiers: serviceTiers, speeds: speeds, inferenceGeos: inferenceGeos)
        }

        // JSONL is append-only and parsed in order, so the incremental
        // block's latestModel (when present) is the newest reading.
        let latestModel = incremental?.latestModel ?? cached?.latestModel

        return TranscriptCacheResult(
            tokensByModel: tokensByModel, compaction: compaction, errors: errors, turnDurations: turnDurations,
            thinkingBlockCount: thinkingBlockCount, usageExtras: usageExtras, latestModel: latestModel
        )
    }

    // MARK: - Cache bookkeeping

    private func setCache(_ key: String, _ entry: CacheEntry) {
        if let idx = lruOrder.firstIndex(of: key) { lruOrder.remove(at: idx) }
        lruOrder.append(key)
        cache[key] = entry
        while lruOrder.count > maxEntries {
            let oldest = lruOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func touch(_ key: String) {
        if let idx = lruOrder.firstIndex(of: key) {
            lruOrder.remove(at: idx)
            lruOrder.append(key)
        }
    }

    private struct FileStat {
        var mtime: Double
        var size: Int
    }

    private static func statFile(_ path: String) -> FileStat? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        guard let size = attrs[.size] as? Int else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return FileStat(mtime: mtime, size: size)
    }
}
