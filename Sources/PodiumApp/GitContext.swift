#if os(macOS)
import Foundation

// MARK: - GitInfo

/// Snapshot of the git state for a session's working directory.
struct GitInfo: Equatable {
    /// Current branch name, e.g. "enhancement/1107-imagify-mcp".
    let branch: String?
    /// Short hash + subject of the latest commit, e.g. "a1b2c3d fix: correct array syntax".
    let lastCommit: String?
    /// Raw remote URL as reported by git (SSH or HTTPS form).
    let remoteURL: String?
    /// True when the working tree has uncommitted changes.
    let isDirty: Bool

    /// The remote URL normalised to a browsable HTTPS URL.
    /// Converts `git@github.com:org/repo.git` → `https://github.com/org/repo`.
    var remoteWebURL: URL? {
        guard let remoteURL, !remoteURL.isEmpty else { return nil }
        return GitContextReader.httpsURL(from: remoteURL)
    }
}

// MARK: - GitContextReader

/// Reads local git state by shelling out to the `git` binary.
///
/// Security: every invocation uses a fixed argument array — no shell, no string
/// interpolation of user-controlled text into a command line. The only dynamic
/// value is the directory path, which is passed as a discrete `-C <path>`
/// argument and never interpreted by a shell.
actor GitContextReader {

    /// Load git context for `cwd`. Returns `nil` when the directory does not
    /// exist or is not inside a git working tree. Runs off the main thread
    /// (this is an actor, isolated from `@MainActor`).
    static func load(cwd: String) async -> GitInfo? {
        let reader = GitContextReader()
        return await reader.read(cwd: cwd)
    }

    func read(cwd: String) async -> GitInfo? {
        // Validate the directory exists and is a directory.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }

        // Confirm it's a git work tree before gathering anything else.
        let insideTree = run(args: ["-C", cwd, "rev-parse", "--is-inside-work-tree"])
        guard insideTree?.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return nil
        }

        let branch = run(args: ["-C", cwd, "branch", "--show-current"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = run(args: ["-C", cwd, "log", "-1", "--pretty=format:%h %s"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = run(args: ["-C", cwd, "remote", "get-url", "origin"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let porcelain = run(args: ["-C", cwd, "status", "--porcelain"]) ?? ""

        return GitInfo(
            branch: branch?.isEmpty == false ? branch : nil,
            lastCommit: commit?.isEmpty == false ? commit : nil,
            remoteURL: remote?.isEmpty == false ? remote : nil,
            isDirty: !porcelain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    /// Run `git` with a fixed argument array. Returns stdout, or `nil` on
    /// non-zero exit / launch failure. Never goes through a shell.
    private func run(args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // Using /usr/bin/env git resolves the user's git without a shell.
        process.arguments = ["git"] + args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - URL conversion

    /// Convert a git remote URL (SSH or HTTPS) into a browsable HTTPS URL.
    static func httpsURL(from remoteURL: String) -> URL? {
        var url = remoteURL
        if url.hasSuffix(".git") {
            url = String(url.dropLast(4))
        }
        // SSH form: git@github.com:org/repo  →  https://github.com/org/repo
        if url.hasPrefix("git@") {
            let cleaned = url
                .replacingOccurrences(of: "git@", with: "")
                .replacingOccurrences(of: ":", with: "/")
            return URL(string: "https://" + cleaned)
        }
        // ssh:// form: ssh://git@github.com/org/repo
        if url.hasPrefix("ssh://") {
            let cleaned = url
                .replacingOccurrences(of: "ssh://", with: "")
                .replacingOccurrences(of: "git@", with: "")
            return URL(string: "https://" + cleaned)
        }
        return URL(string: url)
    }
}

#endif
