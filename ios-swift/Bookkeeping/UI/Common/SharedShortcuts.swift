import Foundation

/// 共享的快捷指令（iCloud 链接，ADR 0023）：点一下添加，不用自己搭动作。
/// 快捷指令自己带触发条件（链接里一起带过去），不用再另建自动化。「App 通知」触发 iOS 27 才有，自动记账分两个链接。
/// 链接里的动作按 App 标识找 REC，只认 TestFlight / App Store 装的 `com.fy0627.rec`；
/// 自己侧载的 App 标识后面带签名团队，对不上，设置页改成自己搭的步骤。
/// 换了快捷指令的内容或名字，要用 TestFlight 装的 App 重新做链接，再改这里（页面上的一句话也写着名字）
enum SharedShortcuts {
    static let bundleID = "com.fy0627.rec"
    static var available: Bool { Bundle.main.bundleIdentifier == bundleID }

    /// iOS 27 用的「自动记账」：自带 App 通知触发（银行 App 由用户选，短信也走这里）和电子邮件触发，来源 = 自动
    static let bankMessage27 = URL(string: "https://www.icloud.com/shortcuts/45fcd3946e3748cda1b2a509aab94dff")!
    /// iOS 26 用的「自动记账」：自带信息触发和电子邮件触发，来源 = 自动
    static let bankMessage26 = URL(string: "https://www.icloud.com/shortcuts/4b6174be756e4b21b6a00e0f3fdb5c95")!
    static var bankMessage: URL {
        if #available(iOS 27, *) { return bankMessage27 }
        return bankMessage26
    }
    /// 「记录付款截图」：截屏 → 记录付款截图，设到轻点背面
    static let paymentScreenshot = URL(string: "https://www.icloud.com/shortcuts/f74bd6647eb5403590fedb68422b2c8b")!
    /// 「汇率导入」：获取 URL 内容（`ExchangeRateFeed.url`）→ 导入汇率，自带每天定时运行的触发条件
    static let exchangeRates = URL(string: "https://www.icloud.com/shortcuts/72889ca0b22a4b3e8f72cf1d412f64db")!
}
