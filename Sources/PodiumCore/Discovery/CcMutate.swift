// CcMutate.swift — port of dashboard/server/lib/cc-mutate.js: mutation
// helpers for the Claude Config Explorer. Handles create / overwrite /
// delete on the low-risk text-file surfaces only: skills, subagents, slash
// commands, output styles, and CLAUDE.md memory.
//
// Hard constraints (do not relax without a follow-up review — matches the
// Node file's own header):
//   - Plugins, MCP servers, hooks-in-settings, and settings.json files are
//     NEVER touched here. Those have concurrent-write races with the live
//     Claude Code CLI and need different handling.
//   - Every write/delete creates a timestamped backup BEFORE the mutation.
//     Backups land under <root>/cc-config-backups/<type>/, well outside the
//     directories Claude Code scans, so a deleted skill cannot reappear as
//     a backup-named skill.
//   - Writes are atomic via temp file + rename. Tmp is removed on any
//     failure path.
//   - Names are validated against a strict allowlist regex; resolved paths
//     are double-checked to live under the expected root before any I/O.

import Foundation

/// Mirrors cc-mutate.js's `err.code` values, mapped to HTTP status by
/// `CcConfigRouter` exactly like cc-config.js's `ERR_TO_STATUS` table.
public enum CcMutateErrorCode: String, Sendable {
    case badType = "EBADTYPE"
    case badScope = "EBADSCOPE"
    case badName = "EBADNAME"
    case badContent = "EBADCONTENT"
    case tooLarge = "ETOOLARGE"
    case outOfRoot = "EOUTOFROOT"
    case notFound = "ENOTFOUND"
    case internalError = "EINTERNAL"
}

public struct CcMutateError: Error, Sendable {
    public let code: CcMutateErrorCode
    public let message: String

    public init(_ code: CcMutateErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

public enum CcMutate {
    /// `NAME_RE` — strict allowlist for artifact names.
    private static let namePattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")

    public static func isValidName(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        return namePattern.firstMatch(in: name, options: [], range: range) != nil
    }

    /// `TYPES` — the mutable artifact kinds.
    enum ArtifactKind {
        case dir(subdir: String, filename: String)
        case file(subdir: String, ext: String)
        case memory
    }

    static let types: [String: ArtifactKind] = [
        "skills": .dir(subdir: "skills", filename: "SKILL.md"),
        "agents": .file(subdir: "agents", ext: ".md"),
        "commands": .file(subdir: "commands", ext: ".md"),
        "output-styles": .file(subdir: "output-styles", ext: ".md"),
        "memory": .memory,
    ]

    public static let mutableTypes: [String] = Array(types.keys).sorted()

    static func rootForScope(_ scope: String, cwd: String?) throws -> String {
        switch scope {
        case "user": return ClaudeHome.current()
        case "project": return CcConfig.projectClaudeDir(cwd: cwd)
        default: throw CcMutateError(.badScope, "unknown scope: \(scope)")
        }
    }

    static func memoryPath(forScope scope: String, cwd: String?) throws -> String {
        switch scope {
        case "user": return (ClaudeHome.current() as NSString).appendingPathComponent("CLAUDE.md")
        case "project": return (CcConfig.projectRoot(cwd: cwd) as NSString).appendingPathComponent("CLAUDE.md")
        default: throw CcMutateError(.badScope, "unknown scope: \(scope)")
        }
    }

    struct ResolvedTarget {
        enum Kind: Equatable { case file, dir, memoryFile }
        let kind: Kind
        let target: String
        let filePath: String
        let containmentRoot: String
    }

    /// Resolve the on-disk target for a (scope, type, name) tuple AND the
    /// containment root used for path-traversal checks — port of
    /// `resolveTarget`.
    static func resolveTarget(scope: String, type: String, name: String?, cwd: String?) throws -> ResolvedTarget {
        guard let spec = types[type] else { throw CcMutateError(.badType, "unknown type: \(type)") }

        if case .memory = spec {
            let filePath = try memoryPath(forScope: scope, cwd: cwd)
            return ResolvedTarget(kind: .memoryFile, target: filePath, filePath: filePath, containmentRoot: (filePath as NSString).deletingLastPathComponent)
        }

        guard let name, isValidName(name) else {
            throw CcMutateError(.badName, "name must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
        }

        let root = try rootForScope(scope, cwd: cwd)

        switch spec {
        case .dir(let subdir, let filename):
            let subdirAbs = (root as NSString).appendingPathComponent(subdir)
            let target = (subdirAbs as NSString).appendingPathComponent(name)
            return ResolvedTarget(kind: .dir, target: target, filePath: (target as NSString).appendingPathComponent(filename), containmentRoot: subdirAbs)
        case .file(let subdir, let ext):
            let subdirAbs = (root as NSString).appendingPathComponent(subdir)
            let target = (subdirAbs as NSString).appendingPathComponent(name + ext)
            return ResolvedTarget(kind: .file, target: target, filePath: target, containmentRoot: subdirAbs)
        case .memory:
            fatalError("unreachable — handled above")
        }
    }

    static func backupRootPath(scope: String, type: String, cwd: String?) throws -> String {
        (((try rootForScope(scope, cwd: cwd)) as NSString).appendingPathComponent("cc-config-backups") as NSString).appendingPathComponent(type)
    }

    static func memoryBackupRoot(scope: String, cwd: String?) throws -> String {
        let dir = ((try memoryPath(forScope: scope, cwd: cwd)) as NSString).deletingLastPathComponent
        return ((dir as NSString).appendingPathComponent(".cc-config-backups") as NSString).appendingPathComponent("memory")
    }

    static func timestamp() -> String {
        PodiumDate.now().replacingOccurrences(of: ":", with: "-")
    }

    static func copyDir(_ src: String, _ dst: String) throws {
        try FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
        for entry in CcConfig.listDir(src) {
            let s = (src as NSString).appendingPathComponent(entry.name)
            let d = (dst as NSString).appendingPathComponent(entry.name)
            if entry.isDirectory {
                try copyDir(s, d)
            } else {
                try? FileManager.default.copyItem(atPath: s, toPath: d)
            }
        }
    }

    static func removeTree(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Always-on backup: for files, copies to `<backupRoot>/<name>.<ts>.bak`;
    /// for dirs (skills), copies the whole tree. Returns the backup path, or
    /// `nil` if there was nothing to back up (brand-new file).
    static func createBackup(scope: String, type: String, target: String, kind: ResolvedTarget.Kind, cwd: String?) throws -> String? {
        guard FileManager.default.fileExists(atPath: target) else { return nil }
        let root = type == "memory" ? try memoryBackupRoot(scope: scope, cwd: cwd) : try backupRootPath(scope: scope, type: type, cwd: cwd)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let base = (target as NSString).lastPathComponent
        let stamp = timestamp()
        let dst = (root as NSString).appendingPathComponent("\(base).\(stamp).bak")
        if kind == .dir {
            try copyDir(target, dst)
        } else {
            try FileManager.default.copyItem(atPath: target, toPath: dst)
        }
        return dst
    }

    /// Atomic write: tmp file → rename. Tmp is removed on any failure path.
    static func atomicWriteFile(_ filePath: String, content: String) throws {
        let dir = (filePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmp = (dir as NSString).appendingPathComponent(".\((filePath as NSString).lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(Int(Date().timeIntervalSince1970 * 1000)).tmp")
        do {
            guard FileManager.default.createFile(atPath: tmp, contents: content.data(using: .utf8)) else {
                throw CcMutateError(.internalError, "failed to create temp file at \(tmp)")
            }
            _ = try? FileManager.default.removeItem(atPath: filePath)
            try FileManager.default.moveItem(atPath: tmp, toPath: filePath)
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
            throw error
        }
    }

    // MARK: - Public API

    public struct WriteResult: Codable, Equatable, Sendable {
        public var ok: Bool
        public var file: String
        public var target: String
        public var backupPath: String?
        public var created: Bool

        // `backupPath` must stay literal camelCase (client's
        // `CcMutationResult.backupPath`) — see `PodiumJSON.AnyEncodable`'s
        // doc comment for why `CodingKeys` alone can't survive
        // `PodiumJSON.encoder`'s `.convertToSnakeCase`.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode([
                "ok": AnyEncodable(ok),
                "file": AnyEncodable(file),
                "target": AnyEncodable(target),
                "backupPath": AnyEncodable(backupPath),
                "created": AnyEncodable(created),
            ])
        }
    }

    /// Create or overwrite a single text artifact. Port of `writeArtifact`.
    public static func writeArtifact(scope: String, type: String, name: String?, content: String, cwd: String?) throws -> WriteResult {
        guard content.utf8.count <= CcConfig.maxFileBytes else {
            throw CcMutateError(.tooLarge, "content exceeds \(CcConfig.maxFileBytes) bytes")
        }
        let r = try resolveTarget(scope: scope, type: type, name: name, cwd: cwd)

        guard CcConfig.isUnder(r.containmentRoot, r.target) else {
            throw CcMutateError(.outOfRoot, "resolved path is outside containment root")
        }

        let existedBefore = FileManager.default.fileExists(atPath: r.filePath)
        let backupPath: String?
        if existedBefore {
            let kind: ResolvedTarget.Kind = r.kind == .dir ? .dir : .file
            backupPath = try createBackup(scope: scope, type: type, target: r.kind == .dir ? r.target : r.filePath, kind: kind, cwd: cwd)
        } else {
            backupPath = nil
        }

        if r.kind == .dir {
            try FileManager.default.createDirectory(atPath: r.target, withIntermediateDirectories: true)
        }
        try atomicWriteFile(r.filePath, content: content)

        return WriteResult(ok: true, file: r.filePath, target: r.target, backupPath: backupPath, created: !existedBefore)
    }

    public struct DeleteResult: Codable, Equatable, Sendable {
        public var ok: Bool
        public var file: String
        public var target: String
        public var backupPath: String?

        // `backupPath` must stay literal camelCase — see `WriteResult`'s
        // `encode(to:)` above / `PodiumJSON.AnyEncodable`'s doc comment.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode([
                "ok": AnyEncodable(ok),
                "file": AnyEncodable(file),
                "target": AnyEncodable(target),
                "backupPath": AnyEncodable(backupPath),
            ])
        }
    }

    /// Delete a single text artifact. Backup is mandatory and runs first;
    /// if the backup fails, the original is left intact (the throw
    /// propagates before any removal happens).
    public static func deleteArtifact(scope: String, type: String, name: String?, cwd: String?) throws -> DeleteResult {
        let r = try resolveTarget(scope: scope, type: type, name: name, cwd: cwd)

        guard CcConfig.isUnder(r.containmentRoot, r.target) else {
            throw CcMutateError(.outOfRoot, "resolved path is outside containment root")
        }

        guard FileManager.default.fileExists(atPath: r.target) else {
            throw CcMutateError(.notFound, "\(type)/\(name ?? "CLAUDE.md") does not exist")
        }

        let backupKind: ResolvedTarget.Kind = r.kind == .memoryFile ? .file : r.kind
        let backupPath = try createBackup(scope: scope, type: type, target: r.target, kind: backupKind, cwd: cwd)

        if r.kind == .dir {
            removeTree(r.target)
        } else {
            try FileManager.default.removeItem(atPath: r.target)
        }

        return DeleteResult(ok: true, file: r.filePath, target: r.target, backupPath: backupPath)
    }

    public struct BackupEntry: Codable, Equatable, Sendable {
        public var scope: String
        public var type: String
        public var name: String
        public var backupPath: String
        public var isDir: Bool
        public var mtime: Double
        public var size: Int?

        // backupPath/isDir must stay literal camelCase (client's
        // `CcBackup`) — see `PodiumJSON.AnyEncodable`'s doc comment.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode([
                "scope": AnyEncodable(scope),
                "type": AnyEncodable(type),
                "name": AnyEncodable(name),
                "backupPath": AnyEncodable(backupPath),
                "isDir": AnyEncodable(isDir),
                "mtime": AnyEncodable(mtime),
                "size": AnyEncodable(size),
            ])
        }
    }

    /// List backups for either all types or a specific (scope, type)
    /// bucket. Port of `listBackups`.
    public static func listBackups(scope: String?, type: String?, cwd: String?) -> [BackupEntry] {
        var out: [BackupEntry] = []
        let scopes = scope.map { [$0] } ?? ["user", "project"]
        let allTypes = type.map { [$0] } ?? mutableTypes
        for s in scopes {
            for t in allTypes {
                guard let root = try? (t == "memory" ? memoryBackupRoot(scope: s, cwd: cwd) : backupRootPath(scope: s, type: t, cwd: cwd)) else { continue }
                let fm = FileManager.default
                guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
                for name in entries {
                    let full = (root as NSString).appendingPathComponent(name)
                    guard let attrs = try? fm.attributesOfItem(atPath: full) else { continue }
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: full, isDirectory: &isDir)
                    let mtime = ((attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 * 1000
                    let size = isDir.boolValue ? nil : (attrs[.size] as? Int)
                    out.append(BackupEntry(scope: s, type: t, name: name, backupPath: full, isDir: isDir.boolValue, mtime: mtime, size: size))
                }
            }
        }
        return out.sorted { $0.mtime > $1.mtime }
    }
}

