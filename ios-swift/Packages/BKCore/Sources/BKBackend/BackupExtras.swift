import Foundation

/// 备份 zip 里账本以外的文件（ADR 0019）：卡面图片和「我的」里的设置。
/// 文件由 App 提供、由 App 用（图片存在 App 的目录里，设置在本机设置里），这里只负责放进 zip、从 zip 里取出来。
public enum BackupExtras {
    /// 卡面图片：`卡面图片/<图片标识>.jpg`，标识就是账户卡面里记的那个
    public static let faceImageFolder = "卡面图片"
    /// 「我的」里的设置（外观、语言、主要币种、通知……）
    public static let settingsName = "设置.json"

    /// zip 里账本以外的文件，路径去掉最外层的文件夹（`卡面图片/xxx.jpg`、`设置.json`）。
    /// CSV 和数据库副本不算：那些是账本
    public static func files(in archive: Data) throws -> [String: Data] {
        let entries: [ZipStore.Entry]
        do { entries = try ZipStore.entries(archive) } catch { throw BackendError.backupUnreadable }
        var files: [String: Data] = [:]
        for entry in entries {
            guard let slash = entry.name.firstIndex(of: "/") else { continue }
            let path = String(entry.name[entry.name.index(after: slash)...])
            guard !path.isEmpty, !path.hasSuffix("/"), !path.hasSuffix(".csv"), path != DataExport.backupName else { continue }
            files[path] = entry.data
        }
        return files
    }

    /// 卡面图片的标识 → 图片
    public static func faceImages(_ files: [String: Data]) -> [String: Data] {
        var images: [String: Data] = [:]
        let prefix = faceImageFolder + "/"
        for (path, data) in files where path.hasPrefix(prefix) && path.hasSuffix(".jpg") {
            let id = String(path.dropFirst(prefix.count).dropLast(4))
            // 标识是 UUID：别的名字（子文件夹、`..`）不认
            guard !id.isEmpty, !id.contains("/"), !id.contains(".") else { continue }
            images[id] = data
        }
        return images
    }

    /// 一张卡面图片在 zip 里的路径
    public static func faceImagePath(_ id: String) -> String { "\(faceImageFolder)/\(id).jpg" }
}
