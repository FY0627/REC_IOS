import Foundation
import ImageIO
import Vision
import BKModel

/// 付款页截图的文字识别（ADR 0021）：系统 Vision，在手机上做，不联网。图片识别完就丢，不保存。
/// 识别在自己的串行队列上做（低端机上一张要大半秒），不占主线程；几张一起交过来时一张一张来，不同时占内存
enum ScreenshotReader {
    struct Reading: Sendable {
        var lines: [ScreenTextLine]
        /// 照片里记的拍摄时间。快捷指令「截屏」交过来的图多半没有，是 nil
        var capturedAt: Date?
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
        // Vision 的位置原点在左下角，换成左上角
        let lines = (request.results ?? []).compactMap { observation -> ScreenTextLine? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return ScreenTextLine(text: text, x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        }
        return Reading(lines: lines, capturedAt: captureDate(source))
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
