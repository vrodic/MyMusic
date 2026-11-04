import Foundation
import SQLite3

enum SQLValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

protocol SQLConvertible { var sqlValue: SQLValue { get } }
extension Int: SQLConvertible { var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLConvertible { var sqlValue: SQLValue { .int(self) } }
extension Double: SQLConvertible { var sqlValue: SQLValue { .double(self) } }
extension String: SQLConvertible { var sqlValue: SQLValue { .text(self) } }
extension Bool: SQLConvertible { var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Data: SQLConvertible { var sqlValue: SQLValue { .blob(self) } }
extension Optional: SQLConvertible where Wrapped: SQLConvertible {
    var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

struct SQLRow {
    let columns: [String: SQLValue]
    subscript(_ key: String) -> SQLValue { columns[key] ?? .null }
    func string(_ k: String) -> String? { if case .text(let s) = self[k] { return s }; return nil }
    func int(_ k: String) -> Int? {
        switch self[k] {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        default: return nil
        }
    }
    func double(_ k: String) -> Double? {
        switch self[k] {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    func bool(_ k: String) -> Bool { (int(k) ?? 0) != 0 }
}

struct SQLiteError: Error, CustomStringConvertible {
    let message: String
    var description: String { "SQLite: \(message)" }
}

/// Minimal thread-safe SQLite wrapper. All calls are serialized with a recursive lock
/// so `transaction {}` can call `execute` from inside.
final class SQLiteDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw SQLiteError(message: "cannot open \(path)")
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit { sqlite3_close(db) }

    private var errorMessage: String { String(cString: sqlite3_errmsg(db)) }

    private func prepare(_ sql: String, _ params: [SQLConvertible]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError(message: "\(errorMessage) in \(sql)")
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p.sqlValue {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case .blob(let v):
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), Self.transient) }
            }
        }
        return stmt
    }

    func execute(_ sql: String, _ params: [SQLConvertible] = []) throws {
        lock.lock(); defer { lock.unlock() }
        if params.isEmpty && sql.contains(";") {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw SQLiteError(message: "\(errorMessage) in \(sql)")
            }
            return
        }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
        guard rc == SQLITE_DONE else { throw SQLiteError(message: "\(errorMessage) in \(sql)") }
    }

    func query(_ sql: String, _ params: [SQLConvertible] = []) throws -> [SQLRow] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [SQLRow] = []
        let count = sqlite3_column_count(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(message: "\(errorMessage) in \(sql)") }
            var cols: [String: SQLValue] = [:]
            for c in 0..<count {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: cols[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: cols[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: cols[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    if let p = sqlite3_column_blob(stmt, c) { cols[name] = .blob(Data(bytes: p, count: n)) }
                default: cols[name] = .null
                }
            }
            rows.append(SQLRow(columns: cols))
        }
        return rows
    }

    /// Rows changed by the last INSERT/UPDATE/DELETE.
    var changes: Int { lock.lock(); defer { lock.unlock() }; return Int(sqlite3_changes(db)) }

    func scalarInt(_ sql: String, _ params: [SQLConvertible] = []) -> Int {
        guard let row = try? query(sql, params).first, let first = row.columns.values.first else { return 0 }
        switch first {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        default: return 0
        }
    }

    func transaction(_ block: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            try block()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Consistent copy of the whole database to `path` (safe while the app is using it).
    func snapshot(to path: String) throws {
        try? FileManager.default.removeItem(atPath: path)
        try execute("VACUUM INTO '\(path.replacingOccurrences(of: "'", with: "''"))'")
    }

    /// Replace this database's contents with the database file at `path` (SQLite online backup).
    func restore(from path: String) throws {
        lock.lock(); defer { lock.unlock() }
        var src: OpaquePointer?
        guard sqlite3_open_v2(path, &src, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(src)
            throw SQLiteError(message: "cannot open backup \(path)")
        }
        defer { sqlite3_close(src) }
        guard let b = sqlite3_backup_init(db, "main", src, "main") else { throw SQLiteError(message: errorMessage) }
        let rc = sqlite3_backup_step(b, -1)
        sqlite3_backup_finish(b)
        guard rc == SQLITE_DONE else { throw SQLiteError(message: "restore failed: \(errorMessage)") }
    }

    /// Lightweight migrations keyed by PRAGMA user_version.
    func migrate(_ steps: [String]) throws {
        let current = scalarInt("PRAGMA user_version")
        for (i, sql) in steps.enumerated() where i >= current {
            try transaction {
                try execute(sql)
                try execute("PRAGMA user_version = \(i + 1)")
            }
        }
    }
}
