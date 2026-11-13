import Foundation
import os
import BKBackend

/// 界面和 App Intent 共用同一个数据库与业务服务。
///
/// App Intent 在 App 自己的进程里运行（无 App Group；唯一的扩展是通知上选分类的 `NotificationContent`，它不读写账本），
/// 因此两者拿到的是同一个 `LedgerBackend` 实例、同一个 SQLite 文件。打开演示数据时两者一起换成演示账本（ADR 0025）。
final class AppServices: Sendable {
    static let shared = AppServices()

    static let logger = Logger(subsystem: "com.fy0627.rec", category: "ledger")
    static let signposter = OSSignposter(subsystem: "com.fy0627.rec", category: .pointsOfInterest)

    enum OpenError: LocalizedError {
        /// 设备开机后尚未解锁过：数据文件仍被系统加密，暂时无法读写
        case protectedDataUnavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .protectedDataUnavailable: L("设备自开机后尚未解锁，账本暂时无法读写。解锁一次后会恢复。")
            case .failed(let message): L("无法打开本地账本：\(message)")
            }
        }
    }

    /// 打开的账本和它的文件：打开、关掉演示数据（`DemoMode`）后文件换了，下次取的时候换成新的
    private let state = OSAllocatedUnfairLock<(url: URL, backend: LedgerBackend)?>(initialState: nil)

    private init() {}

    /// 打开（或复用）本地账本。首次调用会创建目录并执行迁移，不要在主线程调用。
    func backend() throws -> LedgerBackend {
        let url = Self.databaseURL
        return try state.withLock { current in
            if let current, current.url == url { return current.backend }
            let opened = try Self.openBackend(at: url)
            current = (url, opened)
            return opened
        }
    }

    /// 账本文件。打开演示数据时是演示账本（ADR 0025），卡面图片、导入前的副本跟着它放在同一个文件夹
    static var databaseURL: URL {
        let folder = DemoMode.isActive
            ? DemoMode.directory
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ledger", isDirectory: true)
        return folder.appendingPathComponent("ledger.sqlite")
    }

    private static func openBackend(at url: URL) throws -> LedgerBackend {
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
