import AppIntents
import SwiftUI
import BKModel

/// 摘要卡片（ADR 0027）：画这一笔现在的样子（`CategorySnippetStore`）。点了卡片上的按钮，系统运行按钮的动作，再重新运行这里换上新的样子。
/// 系统会多次运行它，不能有副作用；参数只放不变的东西
struct CategorySnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "摘要卡片"
    static let isDiscoverable = false

    @Parameter(title: "流水")
    var recordID: String

    @Parameter(title: "商户")
    var merchant: String?

    @Parameter(title: "账户")
    var account: String

    @Parameter(title: "金额")
    var amount: String

    init() {}

    init(_ record: CategorySnippet.Record) {
        recordID = record.recordID
        merchant = record.header.merchant
        account = record.header.account
        amount = record.header.amount
    }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        let entry = await CategorySnippetStore.shared.entry(recordID)
        let tint = ThemeColor.color(stored: UserDefaults.standard.string(forKey: ThemeColor.key) ?? ThemeColor.blue.rawValue)
        return .result(view: CategorySnippetView(
            recordID: recordID, merchant: merchant, account: account, amount: amount,
            screen: entry.map { $0.picker.screen($0.page) }, chosen: entry?.chosen, tint: tint
        ))
    }
}

/// 卡片上的分类：写进账本。不打开 App
struct PickSnippetCategoryIntent: AppIntent {
    static let title: LocalizedStringResource = "摘要卡片选分类"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

    @Parameter(title: "流水")
    var recordID: String

    @Parameter(title: "分类")
    var categoryID: String

    init() {}

    init(recordID: String, categoryID: String) {
        self.recordID = recordID
        self.categoryID = categoryID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await CategorySnippetStore.shared.pick(recordID: recordID, categoryID: categoryID)
        return .result()
    }
}

/// 卡片上的「全部」「更多」「返回」、有小类的大类：只换一页，不写账本
struct ShowSnippetPageIntent: AppIntent {
    static let title: LocalizedStringResource = "摘要卡片换页"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

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

    @MainActor
    func perform() async throws -> some IntentResult {
        await CategorySnippetStore.shared.show(recordID: recordID, token: page)
        return .result()
    }
}
