import Foundation
import ImageIO
import UIKit
import BKBackend
import BKModel

/// 认不出的截图先留着（ADR 0028）：截图记账没有认出付款、或者进了待处理时，截图存在 App 里（不放进相册），
/// 在「待处理」里点出金额、卡号做成截图模板，做完就删；也可以自己删。
/// 和通知原文一样按保留期限清掉（「我的 › 数据」里的天数）。
///
/// 只在这台手机上：不跟别的设备同步，不进导出和备份。每张存两个文件：截图原样（`.img`）和识别出的文字、位置（`.json`）。
/// 文件在 App 的数据目录里，开机解锁过一次以后后台也能写（快捷指令在锁屏时也会跑）
enum ScreenshotInbox {
    struct Entry: Identifiable, Hashable, Codable, Sendable {
        var id: String
        var savedAt: Date
        var capturedAt: Date?
        var iconApp: String?
        var lines: [ScreenTextLine]
        /// 进了待处理的：那条输入的标识。没有认出付款的是 nil
        var ingestID: String?

        var text: String { ScreenLayout.text(lines) }
    }

    /// 读写文件放在自己的串行队列上，不占主线程
    private static let queue = DispatchQueue(label: "rec.screenshot-inbox", qos: .utility)

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ScreenshotInbox", isDirectory: true)
    }

    static func imageURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).img") }
    private static func infoURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    /// 这次的结果要不要留着截图：一笔也没认出（不是点过「不记」的），或者有进待处理的
    static func shouldKeep(_ result: IngestResult) -> Bool {
        result.classification != .skipped && (result.items.isEmpty || result.pendingCount > 0)
    }

    @discardableResult
    static func save(image: Data, reading: ScreenshotReader.Reading, ingestID: String?) async -> Entry? {
        let entry = Entry(
            id: UUID().uuidString, savedAt: Date(), capturedAt: reading.capturedAt, iconApp: reading.iconApp, lines: reading.lines, ingestID: ingestID
        )
        return await run {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try image.write(to: imageURL(entry.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try JSONEncoder().encode(entry).write(to: infoURL(entry.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return entry
        }
    }

    /// 新存的在前
    static func all() async -> [Entry] {
        await run {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            let decoder = JSONDecoder()
            return names.filter { $0.hasSuffix(".json") }.compactMap { name -> Entry? in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
                return try? decoder.decode(Entry.self, from: data)
            }
            .sorted { $0.savedAt > $1.savedAt }
        } ?? []
    }

    /// 留着几张（首页「待处理」那一行用，不读内容）
    static func count() async -> Int {
        await run {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".json") }.count
        } ?? 0
    }

    static func delete(_ id: String) async {
        _ = await run {
            try? FileManager.default.removeItem(at: imageURL(id))
            try? FileManager.default.removeItem(at: infoURL(id))
            return true
        }
    }

    static func deleteAll() async {
        _ = await run {
            try? FileManager.default.removeItem(at: directory)
            return true
        }
    }

    /// 存了超过 `days` 天的删掉（和通知原文的保留期限一样）
    static func purge(olderThan days: Int) async {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for entry in await all() where entry.savedAt < cutoff { await delete(entry.id) }
    }

    /// 缩略图：只解出这么大，不把整张截图读进内存
    static func thumbnail(_ id: String, maxPixel: Int) async -> UIImage? {
        await run {
            guard let source = CGImageSourceCreateWithURL(imageURL(id) as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: image)
        } ?? nil
    }

    private static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> T? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: try? work()) }
        }
    }
}
