// ImportRouter.swift — port of dashboard/server/routes/import.js: three
// entry points that all funnel into `LegacyImporter` (PodiumCore/Discovery),
// the exact same pipeline the background sweep and startup backfill use —
// guaranteeing imported tokens/compactions/subagents/tool-events line up
// bit-for-bit with sessions captured live.
//
//   GET  /api/import/guide       — OS-aware instructions + default paths
//   POST /api/import/rescan      — re-scan the default ~/.claude/projects dir
//   POST /api/import/scan-path   — scan an arbitrary absolute directory path
//   POST /api/import/upload      — multipart: raw .jsonl / .meta.json parts
//
// Deviations from Node (see LegacyImporter.swift's file header for the
// import-pipeline deviations):
//   - `/upload` accepts raw `.jsonl`/`.meta.json` multipart parts only — no
//     zip/tar/tar.gz extraction (Node's lib/archive.js + multer). A minimal
//     hand-rolled multipart/form-data parser is used since neither
//     Hummingbird nor hummingbird-websocket ship one, and adding a new
//     dependency mid-checkout (other lanes are mid-edit on Package.swift)
//     was judged too risky for this task's scope.
//   - Progress is broadcast once per operation (`phase: "complete"`) rather
//     than granularly per file/phase.

import Foundation
import Hummingbird
import PodiumCore

public enum ImportRouterMount: RouterMount {
    public static func mount(on router: PodiumRouter, context: ServerContext) {
        let group = router.group("/api/import")

        group.get("/guide") { req, ctx in try await guide(req, ctx, context: context) }
        group.post("/rescan") { req, ctx in try await rescan(req, ctx, context: context) }
        group.post("/scan-path") { req, ctx in try await scanPath(req, ctx, context: context) }
        group.post("/upload") { req, ctx in try await upload(req, ctx, context: context) }
    }

    // MARK: - GET /guide

    private static func guide(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        #if os(macOS)
        let platform = "darwin"
        #else
        let platform = "linux"
        #endif

        let claudeHome = ClaudeHome.current()
        let projectsDir = ClaudeHome.projectsDir()
        let homePath = PodiumPaths.homeDirectory().path
        let claudeHomeDisplay = claudeHome.hasPrefix(homePath) ? "~" + claudeHome.dropFirst(homePath.count) : claudeHome
        let projectsDisplay = claudeHomeDisplay + "/projects"
        let archiveCommand = "tar -czf claude-history.tar.gz -C \(claudeHomeDisplay) projects"

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: projectsDir, isDirectory: &isDir) && isDir.boolValue
        var projectCount = 0
        var fileCount = 0
        if exists, let entries = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) {
            for entry in entries {
                let full = (projectsDir as NSString).appendingPathComponent(entry)
                var entryIsDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: full, isDirectory: &entryIsDir), entryIsDir.boolValue else { continue }
                projectCount += 1
                if let files = try? FileManager.default.contentsOfDirectory(atPath: full) {
                    fileCount += files.filter { $0.hasSuffix(".jsonl") }.count
                }
            }
        }

        let response = ImportGuideResponse(
            platform: platform,
            defaultProjectsDir: projectsDir,
            defaultProjectsDirDisplay: projectsDisplay,
            defaultProjectsDirExists: exists,
            defaultProjectsDirStats: .init(projects: projectCount, jsonlFiles: fileCount),
            archiveCommand: archiveCommand,
            supportedExtensions: [".jsonl", ".meta.json"],
            maxUploadBytes: uploadBodyLimit,
            maxUploadFiles: maxUploadFiles,
            steps: [
                .init(id: "locate", title: "Locate your Claude Code history",
                      body: "Claude Code stores every session as a JSONL transcript under \(projectsDisplay). Each subdirectory is named after the working directory where the session started (with slashes replaced by dashes)."),
                .init(id: "archive", title: "Bundle it for transfer (optional)",
                      body: "If you're importing from another machine, archive the whole projects folder first:\n\n    \(archiveCommand)\n\nMove claude-history.tar.gz to this machine, extract it, then use \"From folder\" below."),
                .init(id: "choose", title: "Pick an import mode",
                      body: "Rescan default: re-read ~/.claude/projects on this machine and import anything new. From folder: point the dashboard at any directory you've extracted history into. Upload: drag-drop .jsonl files directly into the browser."),
                .init(id: "verify", title: "Verify tokens and cost",
                      body: "Imports are idempotent: re-running is always safe. Token counts are deduplicated per session ID, with compaction baselines preserved so cost never double-counts."),
            ]
        )
        return try JSONResponse(response)
    }

    // MARK: - POST /rescan

    private static func rescan(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        let importId = "rescan-\(Int(Date().timeIntervalSince1970 * 1000))"
        do {
            let counters = try LegacyImporter.importAllSessions(store: context.store)
            await broadcastProgress(context: context, importId: importId, source: "default", path: nil, counters: counters)
            return try JSONResponse(ImportResultResponse(ok: true, source: "default", path: nil, counters: counters))
        } catch {
            await broadcastProgressError(context: context, importId: importId, message: "\(error)")
            return try JSONResponse(status: .internalServerError, CodedErrorResponse(code: "IMPORT_FAILED", message: "\(error)"))
        }
    }

    // MARK: - POST /scan-path

    private static func scanPath(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        var mutableRequest = req
        let body = try await mutableRequest.decodeJSONBody(as: ScanPathRequest.self)
        guard let rawPath = body.path, !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "INVALID_INPUT", message: "`path` is required"))
        }

        let expanded = expandTilde(rawPath)
        guard expanded.hasPrefix("/") else {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "INVALID_INPUT", message: "`path` must be an absolute path"))
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "PATH_NOT_FOUND", message: "Path does not exist: \(expanded)"))
        }
        guard isDir.boolValue else {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "NOT_A_DIRECTORY", message: "Path is not a directory: \(expanded)"))
        }

        let importId = "scan-\(Int(Date().timeIntervalSince1970 * 1000))"
        do {
            let counters = try LegacyImporter.importFromDirectory(store: context.store, rootDir: expanded)
            await broadcastProgress(context: context, importId: importId, source: "path", path: expanded, counters: counters)
            return try JSONResponse(ImportResultResponse(ok: true, source: "path", path: expanded, counters: counters))
        } catch {
            await broadcastProgressError(context: context, importId: importId, message: "\(error)")
            return try JSONResponse(status: .internalServerError, CodedErrorResponse(code: "IMPORT_FAILED", message: "\(error)"))
        }
    }

    // MARK: - POST /upload

    private static func upload(_ req: Request, _ ctx: ServerRequestContext, context: ServerContext) async throws -> JSONResponse {
        guard let contentType = req.headers[.contentType], contentType.lowercased().contains("multipart/form-data") else {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "INVALID_INPUT", message: "expected multipart/form-data"))
        }

        var mutableRequest = req
        let buffer = try await mutableRequest.collectBody(upTo: uploadBodyLimit)
        let bodyData = Data(buffer.readableBytesView)

        guard let files = MultipartParser.parse(body: bodyData, contentType: contentType) else {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "INVALID_INPUT", message: "could not parse multipart body"))
        }
        guard !files.isEmpty else {
            return try JSONResponse(status: .badRequest, CodedErrorResponse(code: "NO_FILES", message: "No files received"))
        }

        let importableFiles = files.filter { $0.filename.hasSuffix(".jsonl") || $0.filename.hasSuffix(".meta.json") }
        let jsonlCount = importableFiles.filter { $0.filename.hasSuffix(".jsonl") }.count
        guard jsonlCount > 0 else {
            return try JSONResponse(
                status: .badRequest,
                CodedErrorResponse(code: "NO_JSONL", message: "No .jsonl files were found in the uploaded content. Supported inputs: .jsonl, .meta.json.")
            )
        }

        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("podium-import-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        for file in importableFiles {
            let dest = workDir.appendingPathComponent((file.filename as NSString).lastPathComponent)
            try? file.data.write(to: dest)
        }

        let importId = "upload-\(Int(Date().timeIntervalSince1970 * 1000))"
        do {
            let counters = try LegacyImporter.importFromDirectory(store: context.store, rootDir: workDir.path)
            await broadcastProgress(context: context, importId: importId, source: "upload", path: nil, counters: counters)
            return try JSONResponse(UploadResultResponse(
                ok: true, source: "upload", filesReceived: files.count, counters: counters
            ))
        } catch {
            await broadcastProgressError(context: context, importId: importId, message: "\(error)")
            return try JSONResponse(status: .internalServerError, CodedErrorResponse(code: "IMPORT_FAILED", message: "\(error)"))
        }
    }

    // MARK: - Helpers

    private static func expandTilde(_ path: String) -> String {
        let home = PodiumPaths.homeDirectory().path
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    private static func broadcastProgress(context: ServerContext, importId: String, source: String, path: String?, counters: LegacyImporter.ImportCounters) async {
        var data: [String: JSONValue] = [
            "import_id": .string(importId), "phase": .string("complete"), "source": .string(source),
            "counters": .object([
                "imported": .number(Double(counters.imported)), "skipped": .number(Double(counters.skipped)),
                "backfilled": .number(Double(counters.backfilled)), "errors": .number(Double(counters.errors)),
                "sessions_seen": .number(Double(counters.sessionsSeen)), "files_scanned": .number(Double(counters.filesScanned)),
            ]),
        ]
        if let path { data["path"] = .string(path) }
        await context.broadcaster.broadcast(type: "import.progress", data: JSONValue.object(data))
    }

    private static func broadcastProgressError(context: ServerContext, importId: String, message: String) async {
        await context.broadcaster.broadcast(type: "import.progress", data: JSONValue.object([
            "import_id": .string(importId), "phase": .string("error"), "error": .string(message),
        ]))
    }
}

// MARK: - Wire types

private let maxUploadFiles = Int(ProcessInfo.processInfo.environment["CCAM_IMPORT_MAX_FILES"] ?? "") ?? 2000

/// Upload body size cap — parity with Node's `CCAM_IMPORT_MAX_BYTES` (default
/// 1 GB; transcripts can be large).
let uploadBodyLimit = Int(ProcessInfo.processInfo.environment["CCAM_IMPORT_MAX_BYTES"] ?? "") ?? (1024 * 1024 * 1024)

struct ScanPathRequest: Decodable {
    let path: String?
}

struct ImportGuideResponse: Encodable {
    let platform: String
    let defaultProjectsDir: String
    let defaultProjectsDirDisplay: String
    let defaultProjectsDirExists: Bool
    let defaultProjectsDirStats: Stats
    let archiveCommand: String
    let supportedExtensions: [String]
    let maxUploadBytes: Int
    let maxUploadFiles: Int
    let steps: [Step]

    struct Stats: Encodable {
        let projects: Int
        let jsonlFiles: Int
    }

    struct Step: Encodable {
        let id: String
        let title: String
        let body: String
    }
}

/// Shared response shape for `/rescan` and `/scan-path` — a superset of
/// Node's per-endpoint shapes (see LegacyImporter.swift's file header for
/// the "why unify" rationale); additive fields are harmless for consumers
/// that only read `imported`/`skipped`/`errors`.
struct ImportResultResponse: Encodable {
    let ok: Bool
    let source: String
    let path: String?
    let imported: Int
    let skipped: Int
    let backfilled: Int
    let errors: Int
    let sessionsSeen: Int
    let filesScanned: Int

    init(ok: Bool, source: String, path: String?, counters: LegacyImporter.ImportCounters) {
        self.ok = ok
        self.source = source
        self.path = path
        self.imported = counters.imported
        self.skipped = counters.skipped
        self.backfilled = counters.backfilled
        self.errors = counters.errors
        self.sessionsSeen = counters.sessionsSeen
        self.filesScanned = counters.filesScanned
    }
}

struct UploadResultResponse: Encodable {
    let ok: Bool
    let source: String
    let filesReceived: Int
    let imported: Int
    let skipped: Int
    let backfilled: Int
    let errors: Int
    let sessionsSeen: Int
    let filesScanned: Int

    init(ok: Bool, source: String, filesReceived: Int, counters: LegacyImporter.ImportCounters) {
        self.ok = ok
        self.source = source
        self.filesReceived = filesReceived
        self.imported = counters.imported
        self.skipped = counters.skipped
        self.backfilled = counters.backfilled
        self.errors = counters.errors
        self.sessionsSeen = counters.sessionsSeen
        self.filesScanned = counters.filesScanned
    }
}

// MARK: - Minimal multipart/form-data parser

/// A hand-rolled, minimal `multipart/form-data` parser — just enough to
/// extract `filename="..."` parts and their raw bytes from a well-formed
/// browser-generated upload. Neither Hummingbird nor hummingbird-websocket
/// ship multipart support, and this task avoided adding a new dependency
/// while other lanes were mid-edit on Package.swift (see file header).
enum MultipartParser {
    struct File {
        let filename: String
        let data: Data
    }

    static func parse(body: Data, contentType: String) -> [File]? {
        guard let boundaryRange = contentType.range(of: "boundary=") else { return nil }
        var boundary = String(contentType[boundaryRange.upperBound...])
        if let semiIndex = boundary.firstIndex(of: ";") { boundary = String(boundary[..<semiIndex]) }
        boundary = boundary.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        guard !boundary.isEmpty else { return nil }

        guard let delimiter = "--\(boundary)".data(using: .utf8) else { return nil }
        let crlfcrlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
        let crlf = Data([0x0D, 0x0A])

        var parts: [Data] = []
        var cursor = body.startIndex
        var first = true
        while let delimiterRange = findSubrange(delimiter, in: body, from: cursor) {
            if !first {
                parts.append(body.subdata(in: cursor..<delimiterRange.lowerBound))
            }
            first = false
            cursor = delimiterRange.upperBound
        }

        var files: [File] = []
        for rawPart in parts {
            var part = rawPart
            if part.starts(with: crlf) { part.removeFirst(2) }
            guard let headerBodySeparator = findSubrange(crlfcrlf, in: part, from: part.startIndex) else { continue }
            let headerData = part.subdata(in: part.startIndex..<headerBodySeparator.lowerBound)
            var content = part.subdata(in: headerBodySeparator.upperBound..<part.endIndex)
            if content.count >= 2, content.suffix(2).elementsEqual(crlf) { content.removeLast(2) }
            guard let headerString = String(data: headerData, encoding: .utf8) else { continue }
            guard let filename = extractFilename(fromHeaders: headerString) else { continue }
            files.append(File(filename: filename, data: content))
        }
        return files
    }

    /// Manual byte-subsequence search — used instead of `Data.range(of:)`
    /// (an NSData-bridged API whose Linux/corelibs-Foundation behavior this
    /// task didn't want to depend on for a target that must build on Linux).
    /// Naive O(n·m) scan; fine for multipart bodies at the sizes this router
    /// handles (transcripts, not video).
    private static func findSubrange(_ needle: Data, in haystack: Data, from start: Data.Index) -> Range<Data.Index>? {
        guard !needle.isEmpty else { return nil }
        let needleBytes = Array(needle)
        var index = start
        while index < haystack.endIndex {
            guard let matchEnd = haystack.index(index, offsetBy: needleBytes.count, limitedBy: haystack.endIndex) else { return nil }
            if haystack[index..<matchEnd].elementsEqual(needleBytes) {
                return index..<matchEnd
            }
            index = haystack.index(after: index)
        }
        return nil
    }

    private static func extractFilename(fromHeaders headers: String) -> String? {
        for line in headers.split(separator: "\r\n") {
            guard line.lowercased().hasPrefix("content-disposition:") else { continue }
            guard let range = line.range(of: "filename=\"") else { return nil }
            let rest = line[range.upperBound...]
            guard let endIndex = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<endIndex])
        }
        return nil
    }
}
