import Foundation
import BKModel

/// 付款成功页标题旁边的对勾是什么颜色（ADR 0021）：微信是绿的，支付宝是蓝的。
/// 新版微信扫码付款的成功页只有「支付成功」、商家、金额和「返回商家」，没有只有一边才有的字，靠它认是哪个 App。
/// 取像素在 App 里做（`ScreenshotReader`），这里只决定取哪一块、怎么数，不依赖图片框架
public enum ScreenshotIcon {
    private static let successWords = Rx(#"支付成功|付款成功|交易成功|转账成功"#)

    /// 页面最上面的「支付成功」这类标题：对勾在它左边或者上面。长句子（「支付成功后可在账单中查看」）不算
    public static func successTitle(in lines: [ScreenTextLine]) -> ScreenTextLine? {
        lines.filter { $0.text.count <= 8 && successWords.test($0.text) }.min { $0.y < $1.y }
    }

    /// 要取颜色的一块（像素，原点在左上角）：标题本身，加上左边 3 个字高、上面 5 个字高、右边和下面各半个字高。
    /// 新版微信的对勾在标题左边，旧版和支付宝的在上面；下面的广告、按钮不在里面
    public static func sampleRect(around title: ScreenTextLine, imageWidth: Int, imageHeight: Int) -> (x: Int, y: Int, width: Int, height: Int)? {
        let w = Double(imageWidth), h = Double(imageHeight)
        let line = title.height * h
        guard line >= 1 else { return nil }
        let x0 = max(0, Int((title.x * w - 3 * line).rounded()))
        let x1 = min(imageWidth, Int(((title.x + title.width) * w + 0.5 * line).rounded()))
        let y0 = max(0, Int((title.y * h - 5 * line).rounded()))
        let y1 = min(imageHeight, Int(((title.y + title.height) * h + 0.5 * line).rounded()))
        guard x1 > x0, y1 > y0 else { return nil }
        return (x0, y0, x1 - x0, y1 - y0)
    }

    /// 这一块里很绿的点和很蓝的点各数一数（RGBA，每点 4 个字节）：一种够一个对勾那么多、又是另一种的 3 倍以上，就是它。
    /// 黑白灰的字和背景都不算；两种差不多、或者都很少时认不出，返回 nil，不猜
    public static func app(rgba: [UInt8], width: Int, height: Int, lineHeight: Double) -> String? {
        let count = width * height
        guard count > 0, rgba.count >= count * 4 else { return nil }
        var green = 0, blue = 0
        for i in stride(from: 0, to: count * 4, by: 4) {
            let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
            if g >= 120, g - r >= 70, g - b >= 40 { green += 1 }
            else if b >= 160, b - r >= 90, b - g >= 30 { blue += 1 }
        }
        let enough = max(40, Int(lineHeight * lineHeight / 8))
        if green >= enough, green >= blue * 3 { return "wechatpay" }
        if blue >= enough, blue >= green * 3 { return "alipay" }
        return nil
    }
}
