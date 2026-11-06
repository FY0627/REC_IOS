import Foundation

/// 截图上识别出的一行文字和它的位置（ADR 0021）。识别在 App 里用系统 Vision 做，这里只是结果，不依赖 Vision。
/// 位置按整张图归一化到 0…1，原点在左上角（Vision 的原点在左下角，App 换算好再交过来）。
public struct ScreenTextLine: Hashable, Sendable, Codable {
    public var text: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(text: String, x: Double, y: Double, width: Double, height: Double) {
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midY: Double { y + height / 2 }
}
