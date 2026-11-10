import Foundation

/// 共享的快捷指令（iCloud 链接，ADR 0023）：点一下添加，不用自己搭动作。
/// iOS 27 的快捷指令自己带触发条件（链接里一起带过去），不用再另建自动化；iOS 26 打不开 iOS 27 做的链接，
/// 自动化也和快捷指令分开、带不过去，自动记账分两个链接，iOS 26 的要用户自己建自动化。
/// 链接里的动作按 App 标识找 REC，只认 TestFlight / App Store 装的 `com.fy0627.rec`；
/// 自己侧载的 App 标识后面带签名团队，对不上，设置页改成自己搭的步骤。
/// 换了快捷指令的内容或名字，要用 TestFlight 装的 App 重新做链接，再改这里（页面上的一句话也写着名字）
enum SharedShortcuts {
    static let bundleID = "com.fy0627.rec"
    static var available: Bool { Bundle.main.bundleIdentifier == bundleID }

    /// iOS 27 用的「自动记账」：自带 App 通知触发（银行 App 由用户选，短信也走这里）和电子邮件触发，来源 = 自动
    static let bankMessage27 = URL(string: "https://www.icloud.com/shortcuts/45fcd3946e3748cda1b2a509aab94dff")!
    /// iOS 26 用的「自动记账」：只有动作（记录银行动账通知，来源 = 自动），不带触发条件，自动化由用户建
    static let bankMessage26 = URL(string: "https://www.icloud.com/shortcuts/06c0d81542244813b1bcbb50e6a4a437")!
    static var bankMessage: URL {
        if #available(iOS 27, *) { return bankMessage27 }
        return bankMessage26
    }
    /// 「记录付款截图」：截屏 → 记录付款截图，设到轻点背面
    static let paymentScreenshot = URL(string: "https://www.icloud.com/shortcuts/f74bd6647eb5403590fedb68422b2c8b")!
    /// 「汇率导入」：获取 URL 内容（`ExchangeRateFeed.url`）→ 导入汇率，自带每天定时运行的触发条件
    static let exchangeRates = URL(string: "https://www.icloud.com/shortcuts/72889ca0b22a4b3e8f72cf1d412f64db")!
}
