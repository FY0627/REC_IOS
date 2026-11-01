import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public var code: Int32
    public var message: String
    public var sql: String?

    public var description: String { "SQLite error \(code): \(message)" + (sql.map { " [\($0.prefix(80))]" } ?? "") }

    /// 违反 UNIQUE / PRIMARY KEY 约束
    public var isConstraintViolation: Bool { (code & 0xff) == SQLITE_CONSTRAINT }
    /// 数据库文件暂时无法访问（例如设备开机后尚未解锁导致的权限错误）
    public var isAccessDenied: Bool { [SQLITE_CANTOPEN, SQLITE_PERM, SQLITE_AUTH, SQLITE_IOERR, SQLITE_READONLY].contains(code & 0xff) }
}

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLValue: Sendable, Hashable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
}

public protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .real(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
/// 时间以 Unix 秒（Double）保存；不参与账务运算。
extension Date: SQLBindable { public var sqlValue: SQLValue { .real(timeIntervalSince1970) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

/// 单个 SQLite 连接。不是线程安全的：只能在 `Database` 的串行队列里使用
/// （标记为 @unchecked Sendable 仅为了能被该队列的闭包捕获）。
public final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer
    private var statementCache: [String: OpaquePointer] = [:]

    public init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(code: rc, message: message, sql: nil)
        }
        handle = db
        sqlite3_busy_timeout(handle, 5_000)
        sqlite3_extended_result_codes(handle, 1)
    }

    deinit {
        for statement in statementCache.values { sqlite3_finalize(statement) }
        sqlite3_close_v2(handle)
    }

    private func error(_ code: Int32, sql: String?) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }

    public func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if rc != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errorPointer)
            throw SQLiteError(code: rc, message: message, sql: sql)
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let cached = statementCache[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw error(rc, sql: sql) }
        statementCache[sql] = statement
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ values: [SQLValue], sql: String) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(statement, index)
            case .int(let v): rc = sqlite3_bind_int64(statement, index, v)
            case .real(let v): rc = sqlite3_bind_double(statement, index, v)
            case .text(let v): rc = sqlite3_bind_text(statement, index, v, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }
            if rc != SQLITE_OK { throw error(rc, sql: sql) }
        }
    }

    /// 执行不返回行的语句，返回受影响行数。
    @discardableResult
    public func run(_ sql: String, _ values: [SQLBindable] = []) throws -> Int {
        let statement = try prepared(sql)
        defer { sqlite3_reset(statement) }
        try bind(statement, values.map(\.sqlValue), sql: sql)
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc, sql: sql) }
        return Int(sqlite3_changes(handle))
    }

    public func query<T>(_ sql: String, _ values: [SQLBindable] = [], _ map: (Row) throws -> T) throws -> [T] {
        let statement = try prepared(sql)
        defer { sqlite3_reset(statement) }
        try bind(statement, values.map(\.sqlValue), sql: sql)
        var results: [T] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc, sql: sql) }
            results.append(try map(Row(statement: statement)))
        }
        return results
    }

    public func queryOne<T>(_ sql: String, _ values: [SQLBindable] = [], _ map: (Row) throws -> T) throws -> T? {
        try query(sql, values, map).first
    }

    public func scalarInt(_ sql: String, _ values: [SQLBindable] = []) throws -> Int64 {
        try queryOne(sql, values) { $0.int(0) } ?? 0
    }

    /// `BEGIN IMMEDIATE`：开始时就拿写锁，避免两个写事务先读后写造成的去重竞争。
    /// 闭包抛错时整体回滚，不会留下半条记录。
    public func immediateTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var userVersion: Int {
        get { Int((try? scalarInt("PRAGMA user_version")) ?? 0) }
    }

    public func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    public struct Row {
        let statement: OpaquePointer

        public func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }
        public func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
        public func optionalInt(_ index: Int32) -> Int64? { isNull(index) ? nil : int(index) }
        public func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
        public func string(_ index: Int32) -> String {
            guard let text = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: text)
        }
        public func optionalString(_ index: Int32) -> String? { isNull(index) ? nil : string(index) }
        public func date(_ index: Int32) -> Date { Date(timeIntervalSince1970: double(index)) }
        public func optionalDate(_ index: Int32) -> Date? { isNull(index) ? nil : date(index) }
        public func bool(_ index: Int32) -> Bool { int(index) != 0 }
    }
}
