import Foundation
import os
import BKBackend

/// 界面和 App Intent 共用同一个数据库与业务服务。
///
/// App Intent 在 App 自己的进程里运行（单 target，无扩展、无 App Group），
/// 因此两者拿到的是同一个 `LedgerBackend` 实例、同一个 SQLite 文件。
final class AppServices: Sendable {
    static let shared = AppServices()

    static let logger = Logger(subsystem: "com.example.bookkeepingApp.swift", category: "ledger")
    static let signposter = OSSignposter(subsystem: "com.example.bookkeepingApp.swift", category: .pointsOfInterest)

    enum OpenError: LocalizedError {
        /// 设备开机后尚未解锁过：数据文件仍被系统加密，暂时无法读写
        case protectedDataUnavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .protectedDataUnavailable: "设备自开机后尚未解锁，账本暂时无法读写。解锁一次后会恢复。"
            case .failed(let message): "无法打开本地账本：\(message)"
            }
        }
    }

    private let state = OSAllocatedUnfairLock<LedgerBackend?>(initialState: nil)

    private init() {}

    /// 打开（或复用）本地账本。首次调用会创建目录并执行迁移，不要在主线程调用。
    func backend() throws -> LedgerBackend {
        try state.withLock { current in
            if let current { return current }
            let opened = try Self.openBackend()
            current = opened
            return opened
        }
    }

    static var databaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Ledger", isDirectory: true).appendingPathComponent("ledger.sqlite")
    }

    private static func openBackend() throws -> LedgerBackend {
        let url = databaseURL
        let directory = url.deletingLastPathComponent()
        // 数据保护：首次解锁后可访问。锁屏状态下（首次解锁之后）自动化仍可写入；
        // 开机后从未解锁时文件不可读写，入账会明确失败而不是静默丢失。
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        do {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protection)
            }
            let backend = try LedgerBackend.open(at: url)
            try? FileManager.default.setAttributes(protection, ofItemAtPath: url.path)
            return backend
        } catch {
            logger.error("open ledger failed: \(String(describing: type(of: error)), privacy: .public)")
            if !ProtectedDataProbe.isAvailable { throw OpenError.protectedDataUnavailable }
            throw OpenError.failed(String(describing: error))
        }
    }
}

/// 不依赖 UIKit 主线程 API 的「受保护数据是否可用」检查：尝试打开账本文件读取。
enum ProtectedDataProbe {
    static var isAvailable: Bool {
        let path = AppServices.databaseURL.path
        guard FileManager.default.fileExists(atPath: path) else { return true }
        return FileManager.default.isReadableFile(atPath: path) && (try? FileHandle(forReadingFrom: AppServices.databaseURL).close()) != nil
    }
}
