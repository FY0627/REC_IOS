import Foundation
import Dispatch

/// 数据库入口：一个连接 + 一个串行队列。
///
/// - 所有 SQL 都在私有串行队列上执行，调用方无论在 MainActor 还是后台都不会阻塞主线程；
///   这里不依赖「async 函数会自动离开 MainActor」的假设，而是显式切换到队列。
/// - 写操作统一使用 `BEGIN IMMEDIATE` 事务；多个连接（例如 App 与另一个进程）并发写入时，
///   由 SQLite 文件锁 + `busy_timeout` 串行化，再由 UNIQUE 约束保证去重。
public final class Database: @unchecked Sendable {
    private let queue: DispatchQueue
    private let connection: SQLiteConnection
    public let path: String

    public init(path: String) throws {
        self.path = path
        queue = DispatchQueue(label: "bk.database", qos: .userInitiated)
        connection = try SQLiteConnection(path: path)
        try queue.sync {
            if path != ":memory:" {
                try connection.execute("PRAGMA journal_mode = WAL")
            }
            try connection.execute("PRAGMA synchronous = NORMAL")
            try connection.execute("PRAGMA foreign_keys = ON")
            try Migrations.migrate(connection)
        }
    }

    public static func inMemory() throws -> Database {
        try Database(path: ":memory:")
    }

    /// 在数据库队列上执行只读操作。
    public func read<T: Sendable>(_ body: @escaping @Sendable (SQLiteConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [connection] in
                continuation.resume(with: Result { try body(connection) })
            }
        }
    }

    /// 在数据库队列上执行写事务（BEGIN IMMEDIATE ... COMMIT，失败回滚）。
    public func write<T: Sendable>(_ body: @escaping @Sendable (SQLiteConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [connection] in
                continuation.resume(with: Result { try connection.immediateTransaction { try body(connection) } })
            }
        }
    }

    /// 同步版本，只用于测试和迁移检查。不能在主线程调用。
    public func writeSync<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        try queue.sync { try connection.immediateTransaction { try body(connection) } }
    }

    public func readSync<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        try queue.sync { try body(connection) }
    }
}
