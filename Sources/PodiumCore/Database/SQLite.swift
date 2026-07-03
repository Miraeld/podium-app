// SQLite.swift — minimal ergonomic wrapper over the system CSQLite (sqlite3)
// C API. Confines every access to a private serial DispatchQueue inside
// `Database`, mirroring the effectively-single-threaded execution model of
// the Node server (better-sqlite3 is synchronous). Linux + macOS safe.

import CSQLite
import Foundation

/// A thrown SQLite error, carrying the numeric result code and sqlite's own
/// human-readable message (`sqlite3_errmsg`).
public struct SQLiteError: Error, CustomStringConvertible, Equatable {
    public let code: Int32
    public let message: String

    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "SQLiteError(\(code)): \(message)" }
}

/// A single SQLite value as bound to / read from a prepared statement.
public enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public init(_ value: String?) {
        self = value.map(SQLiteValue.text) ?? .null
    }

    public init(_ value: Int?) {
        self = value.map { .integer(Int64($0)) } ?? .null
    }

    public init(_ value: Int64?) {
        self = value.map(SQLiteValue.integer) ?? .null
    }

    public init(_ value: Double?) {
        self = value.map(SQLiteValue.double) ?? .null
    }

    public init(_ value: Bool?) {
        self = value.map { .integer($0 ? 1 : 0) } ?? .null
    }
}

/// One row of a query result, keyed by column name — mirrors better-sqlite3's
/// plain-object row shape closely enough for the porting task at hand.
public struct SQLiteRow {
    private let columns: [String: Int32]
    private let statement: OpaquePointer

    init(statement: OpaquePointer, columns: [String: Int32]) {
        self.statement = statement
        self.columns = columns
    }

    private func index(for column: String) -> Int32? { columns[column] }

    public func isNull(_ column: String) -> Bool {
        guard let idx = index(for: column) else { return true }
        return sqlite3_column_type(statement, idx) == SQLITE_NULL
    }

    public func string(_ column: String) -> String? {
        guard let idx = index(for: column), sqlite3_column_type(statement, idx) != SQLITE_NULL else { return nil }
        guard let cString = sqlite3_column_text(statement, idx) else { return nil }
        return String(cString: cString)
    }

    public func int(_ column: String) -> Int? {
        guard let idx = index(for: column), sqlite3_column_type(statement, idx) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, idx))
    }

    public func int64(_ column: String) -> Int64? {
        guard let idx = index(for: column), sqlite3_column_type(statement, idx) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, idx)
    }

    public func double(_ column: String) -> Double? {
        guard let idx = index(for: column), sqlite3_column_type(statement, idx) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, idx)
    }

    public func bool(_ column: String) -> Bool? {
        guard let value = int(column) else { return nil }
        return value != 0
    }

    /// Non-optional convenience accessors with sensible zero-values, matching
    /// how the Node layer treats `NOT NULL DEFAULT 0/''` columns.
    public func stringValue(_ column: String) -> String { string(column) ?? "" }
    public func intValue(_ column: String) -> Int { int(column) ?? 0 }
    public func int64Value(_ column: String) -> Int64 { int64(column) ?? 0 }
    public func doubleValue(_ column: String) -> Double { double(column) ?? 0 }
}

/// A prepared statement wrapper. Not thread-safe on its own — always used
/// from within `Database.queue`.
public final class SQLiteStatement {
    fileprivate let handle: OpaquePointer
    private let db: OpaquePointer
    private var columnIndexByName: [String: Int32] = [:]

    fileprivate init(db: OpaquePointer, sql: String) throws {
        self.db = db
        var handle: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &handle, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError(code: rc, message: "prepare failed: \(msg) — SQL: \(sql)")
        }
        self.handle = handle

        let count = sqlite3_column_count(handle)
        for i in 0..<count {
            if let name = sqlite3_column_name(handle, i) {
                columnIndexByName[String(cString: name)] = i
            }
        }
    }

    deinit {
        sqlite3_finalize(handle)
    }

    /// Binds a positional parameter list (1-indexed internally).
    public func bind(_ values: [SQLiteValue]) throws {
        reset()
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(handle, idx)
            case .integer(let v):
                rc = sqlite3_bind_int64(handle, idx, v)
            case .double(let v):
                rc = sqlite3_bind_double(handle, idx, v)
            case .text(let v):
                rc = sqlite3_bind_text(handle, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                rc = v.withUnsafeBytes { ptr -> Int32 in
                    sqlite3_bind_blob(handle, idx, ptr.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
                }
            }
            guard rc == SQLITE_OK else {
                throw SQLiteError(code: rc, message: "bind failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    /// Advances to the next row. Returns `false` when the statement is
    /// exhausted (SQLITE_DONE).
    @discardableResult
    public func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        switch rc {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw SQLiteError(code: rc, message: "step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    public func currentRow() -> SQLiteRow {
        SQLiteRow(statement: handle, columns: columnIndexByName)
    }

    public func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thread-confined SQLite database handle. All operations run synchronously
/// on a private serial `DispatchQueue`, so callers on any thread get
/// consistent, non-overlapping access — matching better-sqlite3's synchronous,
/// effectively single-threaded semantics in the Node server.
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "com.podium.sqlite", qos: .userInitiated)
    public let path: String

    public init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let rc = sqlite3_open(path, &handle)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown open error"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError(code: rc, message: "open failed: \(msg)")
        }
        self.handle = handle

        // Pragmas — parity with db.js lines 45–47.
        try execSync(handle, "PRAGMA journal_mode = WAL;")
        try execSync(handle, "PRAGMA foreign_keys = ON;")
        try execSync(handle, "PRAGMA busy_timeout = 5000;")
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    /// Runs `body` synchronously on the database's serial queue, returning
    /// its result (or rethrowing its error). Safe to call reentrantly from
    /// the same physical thread is NOT guaranteed — do not call `sync` from
    /// inside another `sync` block on this same instance.
    @discardableResult
    public func sync<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
        try queue.sync {
            try body(handle!)
        }
    }

    /// Executes one or more semicolon-separated statements with no bound
    /// parameters and no returned rows (DDL, pragmas, batches).
    public func exec(_ sql: String) throws {
        try sync { handle in
            try execSync(handle, sql)
        }
    }

    /// Prepares a statement. The returned `SQLiteStatement` must only be
    /// used from within a subsequent `sync` block (or via the `prepared`
    /// convenience helpers below) to stay confined to the serial queue.
    public func prepare(_ sql: String) throws -> SQLiteStatement {
        try sync { handle in
            try SQLiteStatement(db: handle, sql: sql)
        }
    }

    /// Runs a write statement (INSERT/UPDATE/DELETE) with bound parameters,
    /// stepping it to completion. Returns the number of rows changed.
    @discardableResult
    public func run(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int {
        try sync { handle in
            let stmt = try SQLiteStatement(db: handle, sql: sql)
            try stmt.bind(params)
            _ = try stmt.step()
            return Int(sqlite3_changes(handle))
        }
    }

    /// Runs a query and returns all rows, mapped by `transform`.
    public func query<T>(_ sql: String, _ params: [SQLiteValue] = [], _ transform: (SQLiteRow) -> T) throws -> [T] {
        try sync { handle in
            let stmt = try SQLiteStatement(db: handle, sql: sql)
            try stmt.bind(params)
            var results: [T] = []
            while try stmt.step() {
                results.append(transform(stmt.currentRow()))
            }
            return results
        }
    }

    /// Runs a query and returns the first row only (or `nil`), mapped by
    /// `transform`.
    public func queryOne<T>(_ sql: String, _ params: [SQLiteValue] = [], _ transform: (SQLiteRow) -> T) throws -> T? {
        try sync { handle in
            let stmt = try SQLiteStatement(db: handle, sql: sql)
            try stmt.bind(params)
            guard try stmt.step() else { return nil }
            return transform(stmt.currentRow())
        }
    }

    /// The last inserted row's ROWID (for `INTEGER PRIMARY KEY AUTOINCREMENT`
    /// tables like `events`). Must be called within the same `sync` scope as
    /// the insert to be meaningful under concurrent callers, but since all
    /// access is already queue-confined this is always safe immediately
    /// after `run(...)`.
    public var lastInsertRowID: Int64 {
        sync { handle in sqlite3_last_insert_rowid(handle) }
    }

    /// Wraps `body` in `BEGIN ... COMMIT`, rolling back on any thrown error.
    /// `body` receives the raw handle so it can prepare/run further
    /// statements without re-entering `sync` (which would deadlock).
    public func transaction<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try sync { handle in
            try execSync(handle, "BEGIN;")
            do {
                let result = try body(handle)
                try execSync(handle, "COMMIT;")
                return result
            } catch {
                // Best-effort rollback; ignore secondary errors so the
                // original failure propagates.
                try? execSync(handle, "ROLLBACK;")
                throw error
            }
        }
    }

    public func close() {
        sync { handle in
            sqlite3_close(handle)
        }
        handle = nil
    }
}

/// Runs a semicolon-batch of DDL/DML with no parameters directly against a
/// raw handle — used both by `Database.exec` (already queue-confined) and
/// during `init` (before `self` fully exists).
@discardableResult
private func execSync(_ handle: OpaquePointer, _ sql: String) throws -> Int32 {
    var errMsg: UnsafeMutablePointer<Int8>?
    let rc = sqlite3_exec(handle, sql, nil, nil, &errMsg)
    if rc != SQLITE_OK {
        let message = errMsg.map { String(cString: $0) } ?? "unknown exec error"
        sqlite3_free(errMsg)
        throw SQLiteError(code: rc, message: "exec failed: \(message) — SQL: \(sql)")
    }
    return rc
}
