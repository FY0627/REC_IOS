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
        // Vision 的位置原点在左下角，换成左上角。旁边的小图标认成了字的，看图上每一列有没有字拆成单独一段（`ScreenLayout.splitIcons`）
        let lines = (request.results ?? []).flatMap { observation -> [ScreenTextLine] in
            guard let candidate = observation.topCandidates(1).first else { return [] }
            let line = ScreenTextLine(rect: observation.boundingBox, text: candidate.string)
            guard let ink = inkColumns(image, line: line) else { return [line] }
            return ScreenLayout.splitIcons(line, ink: ink)
        }
        let iconApp = ScreenshotIcon.successTitle(in: lines).flatMap { iconApp(image, around: $0) }
        return Reading(lines: lines, capturedAt: captureDate(source), iconApp: iconApp)
    }

    /// 这一段的框里每一列有字的上下边（像素，从框的上边数），给 `ScreenLayout.splitIcons` 找粘着的小图标。
    /// 开头、结尾都不是字母、数字的（拆不了），长的段（多半是整句话）、很大的框不看，交回 nil 就不拆。
    /// 底色取框四边的像素里亮度排中间的那个，和底色差得多的点算字
    private static func inkColumns(_ image: CGImage, line: ScreenTextLine) -> [ClosedRange<Int>?]? {
        let visible = line.text.filter { !$0.isWhitespace }
        guard visible.count >= 2, visible.count <= 40,
              let first = visible.first, let last = visible.last,
              first.isLetter || first.isNumber || last.isLetter || last.isNumber else { return nil }
        let rect = CGRect(
            x: line.x * Double(image.width), y: line.y * Double(image.height),
            width: line.width * Double(image.width), height: line.height * Double(image.height)
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard rect.width >= 4, rect.height >= 4, rect.width * rect.height <= 600_000,
              let cropped = image.cropping(to: rect), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
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
        func color(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        var border: [(Int, Int, Int)] = []
        for x in 0..<width { border.append(color(x, 0)); border.append(color(x, height - 1)) }
        for y in 0..<height { border.append(color(0, y)); border.append(color(width - 1, y)) }
        let background = border.sorted { $0.0 + $0.1 + $0.2 < $1.0 + $1.1 + $1.2 }[border.count / 2]
        var columns: [ClosedRange<Int>?] = []
        columns.reserveCapacity(width)
        for x in 0..<width {
            var top: Int?, bottom = 0
            for y in 0..<height {
                let c = color(x, y)
                if max(abs(c.0 - background.0), abs(c.1 - background.1), abs(c.2 - background.2)) > 40 {
                    if top == nil { top = y }
                    bottom = y
                }
            }
            columns.append(top.map { $0...bottom })
        }
        return columns
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
