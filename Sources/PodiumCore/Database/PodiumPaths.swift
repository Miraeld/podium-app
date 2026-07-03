// PodiumPaths.swift — DB path + data dir resolution, parity with db.js
// lines 33–41.
//
// Node resolution order:
//   DASHBOARD_DB_PATH || path.join(DASHBOARD_DATA_DIR || <repo>/data, "dashboard.db")
//
// Standalone-app resolution order (this task's spec):
//   env DASHBOARD_DB_PATH > DASHBOARD_DATA_DIR/dashboard.db > <default data dir>/dashboard.db
//
// Default data dir:
//   macOS:  ~/Library/Application Support/Podium
//   Linux:  $XDG_DATA_HOME/podium, else ~/.local/share/podium

import Foundation

public enum PodiumPaths {
    /// Environment lookup indirection so tests can inject a fake environment
    /// without mutating the real process environment.
    public static var environment: [String: String] = ProcessInfo.processInfo.environment

    public static func homeDirectory() -> URL {
        if let home = environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The default per-platform data directory for Podium's writable state
    /// (database, vapid keys, marker files, …), created if missing.
    public static func defaultDataDir() -> URL {
        #if os(macOS)
        let dir = homeDirectory()
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Podium", isDirectory: true)
        #else
        let dir: URL
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            dir = URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("podium", isDirectory: true)
        } else {
            dir = homeDirectory()
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
                .appendingPathComponent("podium", isDirectory: true)
        }
        #endif
        return dir
    }

    /// Resolves and creates (recursively) the data directory to use: an
    /// explicit `DASHBOARD_DATA_DIR` override, or the platform default.
    @discardableResult
    public static func dataDir() -> URL {
        let dir: URL
        if let override = environment["DASHBOARD_DATA_DIR"], !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dir = defaultDataDir()
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Resolves the dashboard.db path: `DASHBOARD_DB_PATH` env override wins
    /// outright; otherwise `<dataDir()>/dashboard.db`. Ensures the parent
    /// directory exists either way.
    public static func databasePath() -> String {
        if let override = environment["DASHBOARD_DB_PATH"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return override
        }
        return dataDir().appendingPathComponent("dashboard.db", isDirectory: false).path
    }
}
