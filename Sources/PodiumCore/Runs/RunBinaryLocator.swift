// RunBinaryLocator.swift — port of routes/run.js's `GET /binary` handler:
// surfaces whether `claude` is on PATH (via `which`) so the UI can show a
// helpful error before the user clicks Run, plus a few common install
// locations as a fallback for shells whose PATH isn't inherited by the
// server process (e.g. launched from Finder/systemd rather than a login
// shell).

import Foundation

public enum RunBinaryLocator {
    public static func locate(binaryName: String = "claude") -> RunBinaryResponse {
        if let found = which(binaryName) {
            return RunBinaryResponse(found: true, path: found)
        }
        for candidate in commonPaths(binaryName: binaryName) where FileManager.default.isExecutableFile(atPath: candidate) {
            return RunBinaryResponse(found: true, path: candidate)
        }
        return RunBinaryResponse(found: false, path: nil)
    }

    private static func commonPaths(binaryName: String) -> [String] {
        let home = NSHomeDirectory()
        return [
            "/usr/local/bin/\(binaryName)",
            "/opt/homebrew/bin/\(binaryName)",
            "\(home)/.claude/local/\(binaryName)",
            "\(home)/.local/bin/\(binaryName)",
            "\(home)/.npm-global/bin/\(binaryName)",
        ]
    }

    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else {
            return nil
        }
        return out
    }
}
