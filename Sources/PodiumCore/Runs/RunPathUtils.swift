// RunPathUtils.swift — port of routes/run.js's `sanitiseCwd` and the
// `GET /files` directory walk (the `@`-reference autocomplete for the
// prompt editor).
//
// `sanitiseCwd` throws `RunSpawnerError.badCwd` (the same error type/code —
// "EBADCWD" — Node's `sanitiseCwd` throws) so both `POST /api/run` and
// `GET /api/run/files` share one error path in the router.

import Foundation

public enum RunPathUtils {
    /// Resolves and validates a `cwd` request parameter: must be an
    /// absolute, existing directory. An empty/missing input defaults to the
    /// server process's own working directory (matches Node's
    /// `process.cwd()` fallback).
    public static func sanitiseCwd(_ input: String?) throws -> String {
        guard let input, !input.isEmpty else {
            return FileManager.default.currentDirectoryPath
        }
        guard input.hasPrefix("/") else {
            throw RunSpawnerError.badCwd("cwd must be an absolute path")
        }
        let resolved = (input as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
            throw RunSpawnerError.badCwd("cwd does not exist: \(resolved)")
        }
        return resolved
    }

    private static let skipDirs: Set<String> = [
        "node_modules", ".git", "dist", "build", "out", ".next", ".cache",
        ".vite", "coverage", ".turbo", "target", ".venv", "__pycache__",
    ]

    /// Walks `cwd` (already sanitised by the caller) collecting up to
    /// `maxResults` relative file paths matching `query` (case-insensitive
    /// substring), skipping dotfiles (except `.env`/`.gitignore`) and the
    /// usual build/dependency directories. Mirrors routes/run.js's `walk`.
    public static func browseFiles(cwd: String, query: String?, maxResults: Int = 40, maxVisited: Int = 5000) -> [String] {
        let q = query?.lowercased()
        var results: [String] = []
        var visited = 0

        func walk(_ dir: String, _ rel: String) {
            guard results.count < maxResults, visited < maxVisited else { return }
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for name in entries.sorted() {
                guard results.count < maxResults, visited < maxVisited else { return }
                visited += 1
                if name.hasPrefix(".") && name != ".env" && name != ".gitignore" { continue }
                let full = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                let relPath = rel.isEmpty ? name : "\(rel)/\(name)"
                if isDir.boolValue {
                    guard !skipDirs.contains(name) else { continue }
                    walk(full, relPath)
                } else if q == nil || q!.isEmpty || relPath.lowercased().contains(q!) {
                    results.append(relPath)
                }
            }
        }
        walk(cwd, "")
        results.sort { a, b in a.count != b.count ? a.count < b.count : a < b }
        return Array(results.prefix(maxResults))
    }
}
