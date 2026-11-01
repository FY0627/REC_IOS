import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// 自定义卡面背景图。
///
/// 性能：选图时一次性按卡片比例居中裁剪、缩小到卡片的屏幕像素（ImageIO 直接生成缩略图，不解码原图全尺寸），
/// 存成 JPEG；显示时在后台线程画成卡片屏幕像素大小、带圆角的位图，按标识缓存。滚动卡包和详情转场时只是绘制这张位图：
/// 圆角在位图里，卡面不用再加遮罩（每张卡一个遮罩，每帧都要离屏合成一次），大小和屏幕像素一一对应，也不用边显示边缩放。
@MainActor
@Observable
final class CardFaceImages {
    static let shared = CardFaceImages()

    private var decoded: [String: UIImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    private init() {}

    /// 已解码的图片；第一次访问时在后台加载，加载完成后使用它的视图自动刷新。
    func image(_ id: String) -> UIImage? {
        if let image = decoded[id] { return image }
        if !loading.contains(id) {
            loading.insert(id)
            Task { await load(id) }
        }
        return nil
    }

    private func load(_ id: String) async {
        let url = Self.fileURL(id)
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        let width = AppLayout.cardWidth(screen?.bounds.width ?? 390)
        let size = CGSize(width: width, height: width / AppLayout.cardAspect)
        let scale = screen?.scale ?? 3
        let image = await Task.detached(priority: .userInitiated) {
            Self.cardBitmap(contentsOf: url, size: size, scale: scale)
        }.value
        loading.remove(id)
        if let image { decoded[id] = image }
    }

    /// 不要在主线程调用。
    nonisolated private static func cardBitmap(contentsOf url: URL, size: CGSize, scale: CGFloat) -> UIImage? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        // 普通 8 位就够：广色域的位图占两倍内存
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let bounds = CGRect(origin: .zero, size: size)
            UIBezierPath(roundedRect: bounds, cornerRadius: AppLayout.cardCornerRadius).addClip()
            image.draw(in: bounds)
        }
    }

    /// 删除不再使用的图片（换图、移除图片、取消编辑时）。
    func discard(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        for id in ids { decoded[id] = nil }
        Task.detached(priority: .utility) {
            for id in ids { try? FileManager.default.removeItem(at: Self.fileURL(id)) }
        }
    }

    enum ImportError: LocalizedError {
        case unreadable

        var errorDescription: String? { "无法读取这张图片" }
    }

    /// 裁剪、缩小并保存，返回新图片的标识。不要在主线程调用。
    /// - Parameters:
    ///   - pixelWidth: 卡片宽度对应的屏幕像素
    ///   - aspect: 卡片宽高比
    nonisolated static func importImage(_ data: Data, pixelWidth: CGFloat, aspect: CGFloat) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelsWide = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let pixelsHigh = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else { throw ImportError.unreadable }
        var width = CGFloat(pixelsWide.doubleValue)
        var height = CGFloat(pixelsHigh.doubleValue)
        guard width > 0, height > 0 else { throw ImportError.unreadable }
        // EXIF 方向 5–8 是旋转 90°：缩略图会按方向转正，这里先交换宽高
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation >= 5 {
            swap(&width, &height)
        }
        let targetWidth = pixelWidth
        let targetHeight = pixelWidth / aspect
        // 等比填满卡片所需的缩放；原图更小时不放大
        let scale = min(1, max(targetWidth / width, targetHeight / height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int((max(width, height) * scale).rounded(.up)),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ImportError.unreadable }

        // 居中裁成卡片比例
        let w = CGFloat(thumbnail.width), h = CGFloat(thumbnail.height)
        let crop = w / h > aspect
            ? CGRect(x: ((w - h * aspect) / 2).rounded(), y: 0, width: (h * aspect).rounded(), height: h)
            : CGRect(x: 0, y: ((h - w / aspect) / 2).rounded(), width: w, height: (w / aspect).rounded())
        guard let cropped = thumbnail.cropping(to: crop) else { throw ImportError.unreadable }

        let id = UUID().uuidString
        let url = fileURL(id)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw ImportError.unreadable }
        CGImageDestinationAddImage(destination, cropped, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.unreadable }
        return id
    }

    nonisolated static func fileURL(_ id: String) -> URL {
        AppServices.databaseURL.deletingLastPathComponent()
            .appendingPathComponent("CardFaces", isDirectory: true)
            .appendingPathComponent("\(id).jpg")
    }
}
