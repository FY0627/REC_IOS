import Foundation
import Observation
import BKBackend
import BKModel

/// 界面状态。只在 MainActor 上保存结果；所有查询和写入都由 `LedgerBackend`
/// 在数据库队列上执行，主线程只负责接收结果。
///
/// 刷新时只改真正变了的数据：没变的不重新赋值，读它的页面就不用重新计算。
/// 几次刷新同时进行时只用最后开始的那次的结果，先开始、后完成的旧结果不会盖掉新的。
@MainActor
@Observable
final class LedgerStore {
    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: LoadState = .loading
    /// 使用中的卡（资产页上方的卡包、净资产、待处理账单的账户选择）
    private(set) var accounts: [Account] = []

    /// 自己的账户里有的币种（按账户顺序，不重复）：记一笔、编辑流水选币种时排在最上面
    var heldCurrencies: [CurrencyCode] {
        var codes: [CurrencyCode] = []
        for account in accounts {
            for code in account.currencies where !codes.contains(code) { codes.append(code) }
        }
        return codes
    }
    /// 已停用的卡：不参与自动记账和净资产，在资产页最下方以灰色卡包显示
    private(set) var archivedAccounts: [Account] = []
    /// 全部卡片（不含删除的），按管理银行卡里排的顺序，新卡在最后
    private(set) var allAccounts: [Account] = []
    /// 删除的账户：不在任何列表里，只用来显示它留下的流水（编辑流水、统计）
    private var deletedAccounts: [Account] = []
    private(set) var balances: [String: AccountBalances] = [:]
    private(set) var automation: [String: AccountAutomationStatus] = [:]
    private(set) var pendingCount = 0
    /// 待分类：已入账的支出、收入还没有分类（没确认对方的转账也在里面）
    private(set) var uncategorizedCount = 0
    /// 全部分类（含隐藏的）
    private(set) var categories: [LedgerCategory] = []
    private(set) var categoryTree = CategoryTree([])
    private(set) var homeRows: [RecordRow] = []
    private(set) var homeHasMore = false
    private(set) var monthStats: MonthStats?
    /// 每次数据变化 +1，详情页等据此重新加载自己的分页数据
    private(set) var revision = 0

    private var backend: LedgerBackend?
    private var loadingMore = false
    private var refreshTask: Task<Void, Never>?
    /// 每次刷新 +1；结果回来时不是最新一次就丢掉
    private var refreshGeneration = 0
    static let pageSize = 60

    func start() async {
        guard backend == nil else { return }
        do {
            // 打开数据库（含迁移）放在后台线程
            let opened = try await Task.detached(priority: .userInitiated) { try AppServices.shared.backend() }.value
            backend = opened
            // 更新前只缓存了最新一份汇率：放进按天保存的汇率表（已有就跳过）
            if let cached = ExchangeRateStore.cached() { _ = try? await opened.saveExchangeRates(cached) }
            await adoptLedgerRates()
            // 更新前手选的分类：回放一遍，学习不从零开始（只做一次）
            try? await opened.seedCategoryLearning()
            await refresh()
            _ = try? await backend?.purgeExpiredRawContent()
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    func retryStart() async {
        state = .loading
        backend = nil
        await start()
    }

    /// 合并短时间内的多次刷新请求（例如自动化连续写入）。
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func refresh() async {
        guard let backend else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let signpost = AppServices.signposter.beginInterval("StoreRefresh")
        defer { AppServices.signposter.endInterval("StoreRefresh", signpost) }
        do {
            let now = Date()
            let year = Calendar.current.component(.year, from: now)
            let month = Calendar.current.component(.month, from: now)
            async let accounts = backend.accounts(includeArchived: true, includeDeleted: true)
            async let balances = backend.balanceSummaries()
            async let automation = backend.automationStatus()
            async let pending = backend.pendingCount()
            async let waiting = backend.uncategorizedCount()
            async let rows = backend.records(filter: Self.feedFilter, limit: Self.pageSize)
            async let stats = backend.monthStats(year: year, month: month, convertTo: ExchangeRateStore.primaryCurrency)
            async let categories = backend.categories()
            let (a, b, au, p, r, s, w, c) = try await (accounts, balances, automation, pending, rows, stats, waiting, categories)
            // 期间又开始了一次刷新：这份结果可能已经旧了，交给那一次
            guard generation == refreshGeneration else { return }
            let kept = a.filter { !$0.deleted }
            if allAccounts != kept {
                allAccounts = kept
                self.accounts = kept.filter { !$0.archived }
                archivedAccounts = kept.filter(\.archived)
            }
            let deleted = a.filter(\.deleted)
            if deletedAccounts != deleted { deletedAccounts = deleted }
            if self.balances != b { self.balances = b }
            if self.automation != au { self.automation = au }
            if pendingCount != p { pendingCount = p }
            if uncategorizedCount != w { uncategorizedCount = w }
            if self.categories != c {
                self.categories = c
                categoryTree = CategoryTree(c)
            }
            if homeRows != r {
                homeRows = r
                homeHasMore = r.count == Self.pageSize
            }
            if monthStats != s { monthStats = s }
            revision += 1
            if state != .ready { state = .ready }
        } catch {
            guard generation == refreshGeneration else { return }
            state = .failed(String(describing: error))
        }
    }

    /// 首页的看法：只列已入账的；转帐两边、合成的一单都只占一行；手续费合到那一笔下面
    nonisolated static let feedFilter = RecordFilter(feed: true, mergeFees: true)

    func loadMoreHome() async {
        guard let backend, homeHasMore, !loadingMore, let last = homeRows.last else { return }
        loadingMore = true
        defer { loadingMore = false }
        let generation = refreshGeneration
        let cursor = RecordCursor(effectiveAt: last.record.effectiveAt, id: last.id)
        guard let page = try? await backend.records(filter: Self.feedFilter, before: cursor, limit: Self.pageSize),
              // 读下一页的时候首页刷新过了：接不上，等滚到底再读
              generation == refreshGeneration, homeRows.last?.id == last.id else { return }
        let known = Set(homeRows.map(\.id))
        homeRows += page.filter { !known.contains($0.id) }
        homeHasMore = page.count == Self.pageSize
    }

    /// 按条件查流水（卡片详情、首页搜索），接在 `last` 后面分页
    func records(_ filter: RecordFilter, after last: RecordRow?, limit: Int) async -> [RecordRow] {
        guard let backend else { return [] }
        let cursor = last.map { RecordCursor(effectiveAt: $0.record.effectiveAt, id: $0.id) }
        return (try? await backend.records(filter: filter, before: cursor, limit: limit)) ?? []
    }

    func updateRecord(id: String, _ edit: RecordEdit) async throws {
        guard let backend else { throw BackendError.notFound }
        try await backend.updateRecord(id: id, edit)
        await refresh()
    }

    func deleteRecord(id: String) async throws {
        guard let backend else { throw BackendError.notFound }
        try await backend.deleteRecord(id: id)
        await refresh()
    }

    func addAccount(_ draft: AccountDraft) async throws -> Account {
        guard let backend else { throw BackendError.notFound }
        let account = try await backend.addAccount(draft)
        await refresh()
        return account
    }

    func updateCardFace(accountID: String, paletteID: String, face: CardFace) async throws {
        guard let backend else { throw BackendError.notFound }
        try await backend.updateCardFace(accountID: accountID, paletteID: paletteID, face: face)
        await refresh()
    }

    func updateAccount(id: String, _ edit: AccountEdit) async throws {
        guard let backend else { throw BackendError.notFound }
        try await backend.updateAccount(id: id, edit)
        await refresh()
    }

    /// 至少有一张卡收到过自动输入：说明自动化已经在工作，新卡不需要再设置
    var automationVerified: Bool { automation.values.contains { $0.lastSuccessAt != nil } }

    func setArchived(accountID: String, archived: Bool) async {
        try? await backend?.setArchived(accountID: accountID, archived: archived)
        await refresh()
    }

    /// 拖动排序：界面上的顺序当场换（要在拖动的回调里同步改好，松手时行才直接停在新位置），
    /// 再写数据库；写失败时刷新回原来的顺序
    func reorderAccounts(_ ids: [String]) {
        let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        allAccounts.sort { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        accounts = allAccounts.filter { !$0.archived }
        archivedAccounts = allAccounts.filter(\.archived)
        Task {
            try? await backend?.reorderAccounts(ids)
            await refresh()
        }
    }

    /// 删除停用的卡；它的流水留着，账户名称后面写「已删除」
    func deleteAccount(id: String) async throws {
        guard let backend else { throw BackendError.notFound }
        try await backend.deleteAccount(id: id)
        await refresh()
    }

    func detail(recordID: String) async -> RecordDetail? {
        try? await backend?.recordDetail(id: recordID)
    }

    func pendingItems() async -> [PendingItem] {
        (try? await backend?.openPendingItems()) ?? []
    }

    func confirmPending(id: String, accountID: String) async throws {
        try await backend?.confirmPending(id: id, accountID: accountID)
        await refresh()
    }

    func ignorePending(id: String) async throws {
        try await backend?.ignorePending(id: id)
        await refresh()
    }

    func templates() async -> [MessageTemplate] {
        (try? await backend?.templates()) ?? []
    }

    /// 保存识别模板，并用它重新识别待处理项；返回重新识别的通知条数
    func saveTemplate(_ template: MessageTemplate) async throws -> Int {
        guard let backend else { throw BackendError.notFound }
        let count = try await backend.saveTemplate(template)
        await refresh()
        return count
    }

    func deleteTemplate(id: String) async throws {
        try await backend?.deleteTemplate(id: id)
    }

    /// 确认转账的对方：自己的账户（不算收支）或别人
    func setTransferParty(recordID: String, party: TransferParty?) async throws {
        try await backend?.setTransferParty(recordID: recordID, party: party)
        await refresh()
    }

    func updateNote(recordID: String, note: String) async throws {
        try await backend?.updateNote(recordID: recordID, note: note)
        await refresh()
    }

    // MARK: 分类

    func uncategorized() async -> [RecordRow] {
        (try? await backend?.uncategorized()) ?? []
    }

    func categorySuggestions(recordID: String) async -> CategorySuggestions {
        (try? await backend?.categorySuggestions(recordID: recordID)) ?? CategorySuggestions()
    }

    /// 从通知打开选分类面板：流水已经删了时是 nil
    func categorizeTarget(recordID: String) async -> CategorizeTarget? {
        guard let row = await detail(recordID: recordID)?.row else { return nil }
        return CategorizeTarget(row: row, suggestions: await categorySuggestions(recordID: recordID))
    }

    /// 给一笔选分类，可以顺手写备注
    func setCategory(recordID: String, categoryID: String, note: String? = nil) async throws {
        guard let backend else { throw BackendError.notFound }
        try await backend.setCategory(recordID: recordID, categoryID: categoryID, note: note)
        await refresh()
    }

    @discardableResult
    func addCategory(_ draft: CategoryDraft) async throws -> LedgerCategory {
        guard let backend else { throw BackendError.notFound }
        let category = try await backend.addCategory(draft)
        await refresh()
        return category
    }

    func updateCategory(id: String, name: String, symbol: String) async throws {
        try await backend?.updateCategory(id: id, name: name, symbol: symbol)
        await refresh()
    }

    func setCategoryHidden(id: String, hidden: Bool) async throws {
        try await backend?.setCategoryHidden(id: id, hidden: hidden)
        await refresh()
    }

    func reorderCategories(_ ids: [String]) async throws {
        try await backend?.reorderCategories(ids)
        await refresh()
    }

    func moveCategory(id: String, toParent parentID: String?) async throws {
        try await backend?.moveCategory(id: id, toParent: parentID)
        await refresh()
    }

    func mergeCategory(id: String, into targetID: String) async throws {
        try await backend?.mergeCategory(id: id, into: targetID)
        await refresh()
    }

    func deleteCategory(id: String, moveRecordsTo targetID: String?) async throws {
        try await backend?.deleteCategory(id: id, moveRecordsTo: targetID)
        await refresh()
    }

    // MARK: 手动记一笔

    func lastManualAccountID() async -> String? {
        try? await backend?.lastManualAccountID()
    }

    func similarRecords(to entry: ManualEntry) async -> [RecordRow] {
        (try? await backend?.similarRecords(to: entry)) ?? []
    }

    func addRecord(_ entry: ManualEntry) async throws {
        guard let backend else { throw BackendError.notFound }
        try await backend.addRecord(entry)
        await refresh()
    }

    // MARK: 合成一单

    func orderCandidates(recordID: String) async -> [RecordRow] {
        (try? await backend?.orderCandidates(recordID: recordID)) ?? []
    }

    func mergeOrder(recordIDs: [String]) async throws {
        try await backend?.mergeOrder(recordIDs: recordIDs)
        await refresh()
    }

    func splitOrder(recordIDs: [String]) async throws {
        try await backend?.splitOrder(recordIDs: recordIDs)
        await refresh()
    }

    // MARK: 退款关联到原交易

    func refundLinkCandidates(recordID: String) async -> [RecordRow] {
        (try? await backend?.refundLinkCandidates(recordID: recordID)) ?? []
    }

    func linkRefunds(_ refundIDs: [String], to originID: String) async throws {
        try await backend?.linkRefunds(refundIDs, to: originID)
        await refresh()
    }

    func unlinkRefund(_ refundID: String) async throws {
        try await backend?.unlinkRefund(refundID)
        await refresh()
    }

    // MARK: 一笔支出和另一个账户的一笔收入合成转帐

    func transferMergeCandidates(recordID: String) async -> [RecordRow] {
        (try? await backend?.transferMergeCandidates(recordID: recordID)) ?? []
    }

    func mergeTransfer(recordID: String, with otherID: String) async throws {
        try await backend?.mergeTransfer(recordID: recordID, with: otherID)
        await refresh()
    }

    func splitTransfer(recordID: String) async throws {
        try await backend?.splitTransfer(recordID: recordID)
        await refresh()
    }

    /// 分类建议体检：已经选好分类的流水重新推荐一遍，只读
    func categoryCheckup() async throws -> CategoryCheckup {
        guard let backend else { throw BackendError.notFound }
        return try await backend.categoryCheckup()
    }

    // MARK: 截图记账（ADR 0021）

    /// 从相册选的付款截图：一张一张识别、入账，和快捷指令交过来的一样。返回合在一起的结果，比如「入账 2 笔，待处理 1 条」；一张都没有时是空的
    func ingestScreenshots(_ images: [Data]) async -> String {
        guard let backend else { return L("账本还没打开") }
        var recorded = 0, merged = 0, pending = 0, skipped = 0, failed = 0
        for data in images {
            do {
                let reading = try await ScreenshotReader.read(data)
                let result = try await backend.ingestScreenshot(lines: reading.lines, capturedAt: reading.capturedAt ?? Date())
                recorded += result.recordedCount
                merged += result.mergedCount
                pending += result.pendingCount
                if result.items.isEmpty { skipped += 1 }
            } catch {
                failed += 1
            }
        }
        await refresh()
        var parts: [String] = []
        if recorded > 0 { parts.append(L("入账 \(recorded) 笔")) }
        if merged > 0 { parts.append(L("和已记的合并 \(merged) 笔")) }
        if pending > 0 { parts.append(L("待处理 \(pending) 条")) }
        if skipped > 0 { parts.append(L("\(skipped) 张没有认出付款")) }
        if failed > 0 { parts.append(L("\(failed) 张读不出来")) }
        return parts.joined(separator: L("，"))
    }

    // MARK: 模拟消费

    /// 模拟一笔消费，和快捷指令收到短信一样发记账结果通知。金额在这个场景的范围里随机
    func simulateSpend(_ spend: SimulatedSpend) async throws -> IngestResult {
        guard let backend else { throw BackendError.notFound }
        let amount = Int64.random(in: Int64(spend.yuan.lowerBound) * 100...Int64(spend.yuan.upperBound) * 100)
        let result = try await backend.simulateSpend(spend, amountMinor: amount)
        await refresh()
        await IngestNotifier.post(result, backend: backend)
        return result
    }

    func simulatedRecordCount() async -> Int {
        (try? await backend?.simulatedRecordCount()) ?? 0
    }

    func clearSimulation() async throws -> Int {
        guard let backend else { throw BackendError.notFound }
        let removed = try await backend.clearSimulation()
        await refresh()
        return removed
    }

    // MARK: 导出、导入（ADR 0019）

    /// 导出全部数据：一个 zip 写在临时目录，给分享菜单用。上一次导出的先删掉，临时目录系统也会自己清理
    func exportData() async throws -> (url: URL, summary: DataExportSummary) {
        guard let backend else { throw BackendError.notFound }
        let day = Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(L("REC 数据 \(day).zip"))
        return (url, try await backend.exportData(to: url))
    }

    /// 导入前自动存的现在的数据（撤销导入用）；每次导入换成新的一份，撤销后删掉
    nonisolated static var undoCopyURL: URL {
        AppServices.databaseURL.deletingLastPathComponent().appendingPathComponent("导入前的数据.sqlite")
    }

    var canUndoImport: Bool { FileManager.default.fileExists(atPath: Self.undoCopyURL.path) }

    /// 卡面图片在这台手机上：导入的账户图片不在就换成颜色
    nonisolated static let faceImageExists: @Sendable (String) -> Bool = { id in
        FileManager.default.fileExists(atPath: CardFaceImages.fileURL(id).path)
    }

    func backupInfo(archive: Data) async throws -> BackupInfo {
        guard let backend else { throw BackendError.notFound }
        return try await backend.backupInfo(archive: archive)
    }

    /// 先把现在的数据存一份（撤销用），再导入
    func importBackup(archive: Data, mode: ImportMode) async throws -> ImportSummary {
        guard let backend else { throw BackendError.notFound }
        try await backend.saveDatabaseCopy(to: Self.undoCopyURL)
        let summary = try await backend.importBackup(archive: archive, mode: mode, keepFaceImage: Self.faceImageExists)
        await adoptLedgerRates()
        await refresh()
        return summary
    }

    /// 账本里的汇率比本机缓存的新（或本机还没有）：换成账本里的。
    /// 最新汇率缓存在本机设置里，不在备份里：新装（换了 Bundle ID）后导入备份，卡包和净资产不至于没有汇率可换算
    private func adoptLedgerRates() async {
        guard let latest = try? await backend?.latestExchangeRates() else { return }
        if let cached = ExchangeRateStore.cached(), cached.fetchedAt >= latest.fetchedAt { return }
        ExchangeRateStore.save(latest)
        NotificationCenter.default.post(name: .exchangeRatesDidChange, object: nil)
    }

    /// 撤销上次导入：换回导入前存的那份
    func undoImport() async throws {
        guard let backend else { throw BackendError.notFound }
        _ = try await backend.importDatabase(at: Self.undoCopyURL, mode: .replace, keepFaceImage: Self.faceImageExists)
        try? FileManager.default.removeItem(at: Self.undoCopyURL)
        await refresh()
    }

    /// 统计页：一段时间的统计，nil 表示不限。`converted` 时另外把所有币种换算成主要币种合计（统计页的总览）
    /// `accountID`：只算这个账户
    func stats(from: Date?, to: Date?, converted: Bool = false, accountID: String? = nil) async -> MonthStats? {
        try? await backend?.stats(from: from, to: to, convertTo: converted ? ExchangeRateStore.primaryCurrency : nil, accountID: accountID)
    }

    /// 账户没有这个币种时，按它的主币种大概扣（入）多少（手动记一笔时提示）
    func estimateCharge(amountMinor: Int64, currency: CurrencyCode, to primary: CurrencyCode, at time: Date) async -> RecordCharge? {
        try? await backend?.estimateCharge(amountMinor: amountMinor, currency: currency, to: primary, at: time)
    }

    func retentionDays() async -> Int {
        (try? await backend?.rawRetentionDays()) ?? 30
    }

    func setRetentionDays(_ days: Int) async {
        try? await backend?.setRawRetentionDays(days)
        _ = try? await backend?.purgeExpiredRawContent()
    }

    /// 包括已停用的卡
    /// 包括删除的账户（它的流水还在）
    func account(id: String) -> Account? { allAccounts.first { $0.id == id } ?? deletedAccounts.first { $0.id == id } }
}
