import Foundation

/// 共享的快捷指令（iCloud 链接，ADR 0023）：点一下添加，不用自己搭动作。
/// iOS 27 的快捷指令自己带触发条件（链接里一起带过去），不用再另建自动化；iOS 26 没有，自动化要用户自己建。
/// 链接里的动作按 App 标识找 REC，只认 TestFlight / App Store 装的 `com.fy0627.rec`；
/// 自己侧载的 App 标识后面带签名团队，对不上，设置页改成自己搭的步骤。
/// 换了快捷指令的内容或名字，要用 TestFlight 装的 App 重新做链接，再改这里（页面上的一句话也写着名字）
enum SharedShortcuts {
    static let bundleID = "com.fy0627.rec"
    static var available: Bool { Bundle.main.bundleIdentifier == bundleID }

    /// iOS 27 用的「自动记账」：自带触发条件——电子邮件（主题包含「你」「您」或空格）和 App 通知（银行 App 由用户选），
    /// 通知内容是这几个触发条件的输出，来源 = 自动。iOS 26 打不开这些触发条件，用手动步骤
    static let bankMessage = URL(string: "https://www.icloud.com/shortcuts/c6bec568572348c795b6e625585a4564")!
    /// 「记录付款截图」：截屏 → 记录付款截图，设到轻点背面
    static let paymentScreenshot = URL(string: "https://www.icloud.com/shortcuts/f74bd6647eb5403590fedb68422b2c8b")!
    /// 「汇率导入」：获取 URL 内容（`ExchangeRateFeed.url`）→ 导入汇率；iOS 27 上自带每天定时运行的触发条件
    static let exchangeRates = URL(string: "https://www.icloud.com/shortcuts/72889ca0b22a4b3e8f72cf1d412f64db")!
}
