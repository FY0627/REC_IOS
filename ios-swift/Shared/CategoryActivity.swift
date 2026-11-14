import ActivityKit
import AppIntents
import Foundation
import BKModel

// 灵动岛选分类（ADR 0024）：App 和小组件扩展 `CategoryActivity` 都编译这个文件。
// 不放进 BKCore：BKCore 要在 Linux 上测，没有 ActivityKit。

/// 实时活动。内容只放这一页要显示的东西（`LiveCategoryPicker.Screen`）和 App 按选的语言写好的文字：
/// 扩展不读账本，也不需要翻译表。整个内容要小于 4KB
struct CategoryActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var recordID: String
        /// 商户或交易对方；看不出时是 nil
        var merchant: String?
        /// 「尾号 1234 卡」「微信零钱」
        var account: String
        /// 带币种符号的金额
        var amount: String
        var screen: LiveCategoryPicker.Screen
        /// 点到的分类：显示一下就结束
        var chosen: LiveCategoryPicker.Option?
        /// App 的主题色（`ThemeColor` 的名字，例如 `pink`）：分类按钮的圆和图标用它。以前开的活动没有，用蓝色
        var tint: String?
        /// 这次换内容是「返回」：岛上往回滚，新的从上面下来。nil 和 false 一样，往前滚
        var back: Bool?
        /// 刚开启（系统可能自己展开约 3 秒）：展开的岛是一张提醒，不放商户、金额和按钮，单点打开 App 这一笔的选分类面板。
        /// 几秒后 App 更新一次去掉它（`LiveCategoryActivity.fillButtons`），长按展开才是按钮。nil 时放按钮。
        /// （以前叫 `reminder`、是一句话；还开着的旧活动里那个键不再读）
        var notice: Notice?
        /// 选好时中间的灰色小字：「已分类」，下面白色大字是分类名。以前开的活动没有，空着
        var chosenCaption: String?
        /// 选好以后画对勾：选中的分类先滚进来，过一会儿 App 再更新一次，对勾从左往右画出来
        var checked: Bool?
        /// 选好了、没有下一笔：整页往上走掉，接着结束
        var leaving: Bool?

        /// 这台手机没有灵动岛：只放提醒（`notice`），锁屏卡片和它在屏幕上方弹出的横幅是同一张提醒，没有按钮，单点打开 App 这一笔
        var reminderOnly: Bool?

        var isBack: Bool { back ?? false }
        var isOpening: Bool { notice != nil }
        var isReminderOnly: Bool { reminderOnly ?? false }
        var isChecked: Bool { checked ?? false }
        var isLeaving: Bool { leaving ?? false }
    }

    /// 刚开启时的提醒（像 AirPods 连上时那样）：左边收据图标，中间两行字，右边圆环里是待分类的笔数
    struct Notice: Codable, Hashable {
        /// 灰色小字：「刚刚记了一笔」
        var caption: String
        /// 白色大字：「待分类」
        var title: String
        /// 账本里没分类的笔数，算上这一笔
        var count: Int
    }
}

/// 岛上的格子：记到这个分类。系统在 App 的进程里运行它（`LiveActivityIntent`），不打开 App、不用解锁
struct PickLiveCategoryIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "灵动岛选分类"
    static let isDiscoverable = false

    @Parameter(title: "流水")
    var recordID: String

    @Parameter(title: "分类")
    var categoryID: String

    init() {}

    init(recordID: String, categoryID: String) {
        self.recordID = recordID
        self.categoryID = categoryID
    }

    func perform() async throws -> some IntentResult {
        await LiveCategoryActions.pick(recordID: recordID, categoryID: categoryID)
        return .result()
    }
}

/// 岛上的「全部」「更多」「返回」、有小类的大类：只换一页，不写账本
struct ShowLiveCategoryPageIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "灵动岛换页"
    static let isDiscoverable = false

    @Parameter(title: "流水")
    var recordID: String

    /// `LiveCategoryPicker.Page.token`
    @Parameter(title: "页面")
    var page: String

    init() {}

    init(recordID: String, page: LiveCategoryPicker.Page) {
        self.recordID = recordID
        self.page = page.token
    }

    func perform() async throws -> some IntentResult {
        await LiveCategoryActions.show(recordID: recordID, page: page)
        return .result()
    }
}

/// 单点岛或锁屏卡片打开 App，直接打开这一笔的选分类面板。
/// App 的 URL scheme 就是 App 的 Bundle ID（`Config/Info.plist` 里写的是 `$(PRODUCT_BUNDLE_IDENTIFIER)`），扩展的 Bundle ID 比它多一段
enum CategoryActivityLink {
    static let extensionSuffix = ".CategoryActivity"
    static let host = "categorize"

    static var scheme: String {
        let id = Bundle.main.bundleIdentifier ?? ""
        return id.hasSuffix(extensionSuffix) ? String(id.dropLast(extensionSuffix.count)) : id
    }

    static func url(recordID: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "record", value: recordID)]
        return components.url
    }

    static func recordID(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == host else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "record" }?.value
    }
}
