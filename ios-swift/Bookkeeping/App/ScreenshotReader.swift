import Foundation
import ImageIO
import Vision
import BKBackend
import BKModel

/// 付款页截图的文字识别（ADR 0021）：系统 Vision，在手机上做，不联网。这里不保存图片；认不出的由 `ScreenshotInbox` 留着（ADR 0028）。
/// 识别在自己的串行队列上做（低端机上一张要大半秒），不占主线程；几张一起交过来时一张一张来，不同时占内存
enum ScreenshotReader {
    struct Reading: Sendable {
        var lines: [ScreenTextLine]
        /// 照片里记的拍摄时间。快捷指令「截屏」交过来的图多半没有，是 nil
        var capturedAt: Date?
        /// 成功页标题旁边对勾的颜色认出的 App（`ScreenshotIcon`）：微信绿、支付宝蓝；认不出是 nil
        var iconApp: String?
    }

    enum ReadError: LocalizedError {
        case unreadable

        var errorDescription: String? { L("读不出这张图片") }
    }

    private static let queue = DispatchQueue(label: "rec.screenshot-ocr", qos: .userInitiated)

    static func read(_ data: Data) async throws -> Reading {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try readNow(data))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func readNow(_ data: Data) throws -> Reading {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ReadError.unreadable }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        // Vision 的位置原点在左下角，换成左上角。旁边的小图标认成了字的，按每个字的框拆成单独一段（`ScreenLayout.splitIcons`）
        let lines = (request.results ?? []).flatMap { observation -> [ScreenTextLine] in
            guard let candidate = observation.topCandidates(1).first else { return [] }
            let line = ScreenTextLine(rect: observation.boundingBox, text: candidate.string)
            return ScreenLayout.splitIcons(line, glyphs: glyphs(candidate))
        }
        let iconApp = ScreenshotIcon.successTitle(in: lines).flatMap { iconApp(image, around: $0) }
        return Reading(lines: lines, capturedAt: captureDate(source), iconApp: iconApp)
    }

    /// 一段里每个不是空白的字的框（原点换成左上角）。长的段（多半是整句话，不会是图标）和取不到框的不算，交回空的就不拆
    private static func glyphs(_ candidate: VNRecognizedText) -> [ScreenTextLine] {
        let text = candidate.string
        guard text.count <= 40 else { return [] }
        var result: [ScreenTextLine] = []
        for index in text.indices where !text[index].isWhitespace {
            let range = index..<text.index(after: index)
            guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { return [] }
            result.append(ScreenTextLine(rect: box, text: String(text[range])))
        }
        return result
    }

    /// 只取「支付成功」左边、上面的一小块（几个字高见方），画成 sRGB 再数绿点、蓝点
    private static func iconApp(_ image: CGImage, around title: ScreenTextLine) -> String? {
        guard let rect = ScreenshotIcon.sampleRect(around: title, imageWidth: image.width, imageHeight: image.height),
              rect.width * rect.height <= 4_000_000,
              let cropped = image.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = cropped.width, height = cropped.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return ScreenshotIcon.app(rgba: pixels, width: width, height: height, lineHeight: title.height * Double(image.height))
    }

    /// 照片的拍摄时间：EXIF、TIFF，或者 XMP 的创建时间（iPhone 截屏存成 PNG 时写在 XMP 里）。比现在还晚、或者早于两年前的不用
    private static func captureDate(_ source: CGImageSource) -> Date? {
        var candidates: [String] = []
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any], let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                candidates.append(text)
            }
            if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any], let text = tiff[kCGImagePropertyTIFFDateTime] as? String {
                candidates.append(text)
            }
        }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            for path in ["photoshop:DateCreated", "xmp:CreateDate", "exif:DateTimeOriginal"] {
                if let value = CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) { candidates.append(value as String) }
            }
        }
        let now = Date()
        return candidates.lazy.compactMap(parseDate).first { $0 <= now.addingTimeInterval(60) && $0 > now.addingTimeInterval(-2 * 365 * 86_400) }
    }

    /// 「2026:10:24 14:30:45」（EXIF）或「2026-10-24T14:30:45+08:00」（XMP）；没写时区的按这台手机的时区
    private static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            iso.formatOptions = options
            if let date = iso.date(from: trimmed) { return date }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}

private extension ScreenTextLine {
    /// Vision 的框（归一化，原点在左下角）换成原点在左上角
    init(rect: CGRect, text: String) {
        self.init(text: text, x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }
}
