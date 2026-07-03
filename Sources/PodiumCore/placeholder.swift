// PodiumCore
//
// Cross-platform (macOS + Linux) core library: models, SQLite store, pricing,
// hook-event ingestion, transcript parsing, analytics, ~/.claude discovery,
// hook installer. No UI, no Apple-only APIs.
//
// This file is a placeholder so the target builds before P1.1/P1.2 land real
// implementations. Safe to delete once real sources exist.

import CSQLite

/// Sanity check that CSQLite links correctly on both platforms.
public func podiumCoreSQLiteVersion() -> String {
    String(cString: sqlite3_libversion())
}
