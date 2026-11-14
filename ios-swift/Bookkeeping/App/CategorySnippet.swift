import AppIntents
import Foundation
import BKBackend
import BKModel

/// 摘要卡片上选分类（ADR 0027）：「我的 › 摘要卡片选分类」打开后，记账动作记上一笔没分类的支出或收入，
/// 返回前弹出系统的摘要卡片（App Intents 的 snippet），卡片上和灵动岛一样三页按钮（`LiveCategoryPicker`）。
///
/// - 只有正在运行的动作能弹（快捷指令、Siri、聚焦）：用 `requestConfirmation(snippetIntent:)`，开关打开时才弹，动作的返回值不变；
/// - 卡片一直在，用户点「完成」或「稍后」才收起，不会像灵动岛那样几秒后自己收回。卡片在的时候快捷指令一直在运行，系统让 App 在后台留着；
/// - 点一个分类马上写进账本，卡片上换成选中的分类；没选点「完成」「稍后」都一样，这一笔留在待分类；
/// - 一次记了几笔要选的：一张一张弹，点「稍后」后面的不再弹，留在待分类；
/// - 没弹出来（不到 1 秒就返回了错误，人点不了这么快）：这一笔和后面的照常发记账结果通知。
enum CategorySnippet {
    struct Record: Sendable {
        var recordID: String
        var header: LiveCategoryActivity.Header
        var suggestions: CategorySuggestions
        /// 下面三个：没弹出来时照常发通知（`IngestNotifier.send`）
        var item: IngestItem
        var notificationID: String
        var screenshot: Bool
    }

    /// 「开发与调试」里显示上次弹卡片的结果：装到手机上看自动化里能不能弹
    static let lastResultKey = "snippet.lastResult"
    /// 不到这么久就返回了错误：卡片没弹出来
    private static let notShown: Duration = .seconds(1)

    /// 在记账动作的 `perform` 里、返回前调用
    static func present(_ records: [Record], from intent: some AppIntent) async {
        for (index, record) in records.enumerated() {
            await CategorySnippetStore.shared.open(record)
            let started = ContinuousClock.now
            do {
                try await intent.requestConfirmation(
                    actionName: .custom(
                        acceptLabel: "\(L("完成"))", acceptAlternatives: [],
                        denyLabel: "\(L("稍后"))", denyAlternatives: [],
                        destructive: false
                    ),
                    dialog: nil,
                    showDialogAsPrompt: false,
                    snippetIntent: CategorySnippetIntent(record)
                )
                await note(L("完成"))
            } catch {
                await CategorySnippetStore.shared.close(record.recordID)
                guard ContinuousClock.now - started < notShown else {
                    await note(L("稍后"))
                    return
                }
                AppServices.logger.error("snippet not shown: \(String(describing: error), privacy: .public)")
                await note(L("没弹出来：\(String(describing: error))"))
                for rest in records[index...] {
                    await IngestNotifier.send(rest.item, id: rest.notificationID, suggestions: rest.suggestions, screenshot: rest.screenshot)
                }
                return
            }
            await CategorySnippetStore.shared.close(record.recordID)
        }
    }

    @MainActor
    private static func note(_ text: String) {
        UserDefaults.standard.set("\(Fmt.dateTime(Date())) \(text)", forKey: lastResultKey)
    }
}

/// 卡片上正在选的几笔：在第几页、选了哪个。按钮的动作改这里，系统接着重新运行 `CategorySnippetIntent` 照着画。
/// 卡片在的时候系统让 App 留在内存里，不用存起来；万一 App 被重新拉起来、这里没有，按账本重新算第 1 页
@MainActor
final class CategorySnippetStore {
    static let shared = CategorySnippetStore()

    struct Entry {
        var picker: LiveCategoryPicker
        var page: LiveCategoryPicker.Page = .quick
        /// 点到的分类：卡片上换成它
        var chosen: LiveCategoryPicker.Option?
    }

    private var entries: [String: Entry] = [:]

    func open(_ record: CategorySnippet.Record) {
        entries[record.recordID] = Entry(picker: LiveCategoryActivity.makePicker(record.suggestions))
    }

    func close(_ recordID: String) {
        entries[recordID] = nil
    }

    func entry(_ recordID: String) async -> Entry? {
        if let entry = entries[recordID] { return entry }
        guard let backend = await Self.openBackend(),
              let suggestions = try? await backend.categorySuggestions(recordID: recordID), !suggestions.groups.isEmpty
        else { return nil }
        let entry = Entry(picker: LiveCategoryActivity.makePicker(suggestions))
        entries[recordID] = entry
        return entry
    }

    /// 「全部」「更多」「返回」、有小类的大类
    func show(recordID: String, token: String) async {
        guard let page = LiveCategoryPicker.Page(token: token), var entry = await entry(recordID) else { return }
        entry.page = page
        entries[recordID] = entry
    }

    /// 写进账本（学习和其他地方选分类一样）；写不进去时卡片上换回按钮
    func pick(recordID: String, categoryID: String) async {
        if var entry = await entry(recordID) {
            entry.chosen = entry.picker.option(categoryID) ?? LiveCategoryPicker.Option(id: categoryID, name: "", symbol: "checkmark")
            entries[recordID] = entry
        }
        do {
            guard let backend = await Self.openBackend() else { throw BackendError.notFound }
            try await backend.setCategory(recordID: recordID, categoryID: categoryID)
            NotificationCenter.default.post(name: .ledgerDidChange, object: nil)
        } catch {
            AppServices.logger.error("snippet pick failed: \(String(describing: type(of: error)), privacy: .public)")
            entries[recordID]?.chosen = nil
        }
    }

    /// 打开账本（含迁移）放在后台线程
    private static func openBackend() async -> LedgerBackend? {
        try? await Task.detached(priority: .userInitiated) { try AppServices.shared.backend() }.value
    }
}
