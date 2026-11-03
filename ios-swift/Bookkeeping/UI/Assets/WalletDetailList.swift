import SwiftUI
import UIKit
import BKModel

/// 卡片详情里随数据变化的内容。详情内容和资产页右上角的「更多」菜单都读它。
@MainActor
@Observable
final class WalletDetailModel {
    var pendingCount = 0
    var recordTotal = 0
    /// 卡里的币种，主币种在前；多币种的卡按币种分开看流水
    var currencies: [CurrencyCode] = []
    /// 正在看的币种；单币种的卡为 nil（看全部）
    var currency: CurrencyCode?
    /// 看哪段时间的流水
    var period: RecordPeriod = .all
}

/// 卡片详情的滚动列表（UIKit）：顶部给选中的卡留出位置，下面是「交易记录」标题一行（`AccountDetailSummary`）和流水，
/// 没有流水时是单独一格「暂无流水」。
///
/// 卡片本身不在列表里，画在列表上层（`WalletController`），按这里的滚动距离摆放：
/// 卡片和内容一起滚动；在顶部往下拉时卡片不动，只有下面的内容被拉开。
///
/// 每一格仍由 SwiftUI 画，放在关掉安全区的 `UIHostingController` 里：格子滚到状态栏下面时内容不移动、不重新布局。
/// 格子高度事先量好（流水行每一部分都只有一行，高度只取决于系统字号），列表不做自适应高度：滚动时不再量高度、不改布局，
/// 也不会因为格子高度随位置变化而卡在布局循环里。
///
/// 打开时第一页流水、笔数和待处理数量都读到后，内容整块从屏幕底下升上来；返回时整块退到屏幕底下。
/// 两个动画都只动列表的显示位置（Core Animation），升起途中也能滚动、点按。
///
/// 流水行左滑露出「编辑」「删除」，用系统的滑动按钮，和首页一模一样（右滑是返回卡包，在 `WalletController`）。
/// 所以列表是 `UITableView`：collection view 只有自适应高度的列表布局才有系统的滑动按钮，table view 的行高可以事先量好。
/// 滑动按钮贴着格子右边，所以列表和卡片一样宽；每笔流水单独一组，行之间的空隙是组尾，按钮才和这一行一样高。
@MainActor
final class WalletDetailList: NSObject, UITableViewDelegate {
    enum Section: Hashable {
        case card, summary, empty
        case record(String)
    }

    enum Item: Hashable {
        case card
        case summary
        case record(String)
        /// 「暂无流水」
        case empty
    }

    let tableView: UITableView
    /// 列表滚动了：卡片跟着移动
    var onScroll: () -> Void = {}
    var onSelectRecord: (RecordRow) -> Void = { _ in }
    var onEditRecord: (RecordRow) -> Void = { _ in }
    var onDeleteRecord: (RecordRow) -> Void = { _ in }
    var onOpenPending: () -> Void = {}
    /// 读屏激活顶部的卡片：返回卡包
    var onActivateCard: () -> Void = {}
    /// 多币种的卡换了一个币种看：卡面换成这个币种的余额
    var onCurrencyChange: () -> Void = {}

    private let store: LedgerStore
    private let model: WalletDetailModel
    /// 格子里的 SwiftUI 宿主挂在它下面，跟随它的外观和字号
    private unowned let parent: UIViewController
    private var dataSource: UITableViewDiffableDataSource<Section, Item>!
    /// 量格子高度用，不显示
    private let sizer: UIHostingController<AnyView>
    private var summaryHeight: CGFloat = 0
    /// 流水行的高度，量一次；宽度或系统字号变了清空
    private var recordRowHeight: CGFloat?
    /// 「暂无流水」的高度；宽度或系统字号变了清空
    private var emptyHeight: CGFloat?
    private var account: Account?
    private var rows: [RecordRow] = []
    private var rowsByID: [String: RecordRow] = [:]
    private var hasMore = false
    private var loadingMore = false
    private var loadTask: Task<Void, Never>?
    /// 每次重新读第一页 +1；读数据的任务据此判断结果是否过时
    private var session = 0
    /// 余额和流水是否已经显示（升起之后，到关闭后清空之前）
    private var contentShown = false
    /// 有一行正在滑动或露着按钮
    private(set) var hasOpenRow = false

    /// 每页流水条数
    private static let pageSize = 40
    /// 流水行之间的空隙
    private static let rowSpacing: CGFloat = 8

    init(store: LedgerStore, model: WalletDetailModel, parent: UIViewController) {
        self.store = store
        self.model = model
        self.parent = parent
        tableView = DetailTableView(frame: .zero, style: .plain)
        sizer = UIHostingController(rootView: AnyView(EmptyView()))
        super.init()

        sizer.safeAreaRegions = []
        sizer.view.isHidden = true
        parent.addChild(sizer)
        parent.view.addSubview(sizer.view)
        sizer.didMove(toParent: parent)

        tableView.backgroundColor = .clear
        // 行往左滑时能走到屏幕边上，不在列表左边被切掉
        tableView.clipsToBounds = false
        tableView.separatorStyle = .none
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.insetsContentViewsToSafeArea = false
        tableView.cellLayoutMarginsFollowReadableWidth = false
        tableView.selfSizingInvalidation = .disabled
        // 高度都事先量好，估算设成 0：列表不估算、不量格子，滚动时内容不跳
        tableView.estimatedRowHeight = 0
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.sectionHeaderHeight = 0
        tableView.sectionHeaderTopPadding = 0
        tableView.alwaysBounceVertical = true
        tableView.showsVerticalScrollIndicator = false
        tableView.showsHorizontalScrollIndicator = false
        tableView.scrollsToTop = false
        // 最后一行下面留白（详情里标签栏是隐藏的），加上这一行的组尾一共 48pt
        tableView.contentInset.bottom = 48 - Self.rowSpacing
        tableView.delegate = self

        tableView.register(CardSlotCell.self, forCellReuseIdentifier: "card")
        tableView.register(HostingCell.self, forCellReuseIdentifier: "summary")
        tableView.register(HostingCell.self, forCellReuseIdentifier: "record")
        tableView.register(HostingCell.self, forCellReuseIdentifier: "empty")
        dataSource = RecordDataSource(tableView: tableView) { [weak self] _, indexPath, item in
            self?.cell(for: item, at: indexPath)
        }
        dataSource.defaultRowAnimation = .none
        applySnapshot(reconfigure: false)
    }

    private func cell(for item: Item, at indexPath: IndexPath) -> UITableViewCell {
        switch item {
        case .card:
            let cell = tableView.dequeueReusableCell(withIdentifier: "card", for: indexPath)
            cell.accessibilityLabel = cardLabel
            (cell as? CardSlotCell)?.activate = { [weak self] in self?.onActivateCard() }
            return cell
        case .summary:
            let cell = hostingCell("summary", at: indexPath)
            if account != nil { cell.show(summaryView(), parent: parent) }
            return cell
        case .record(let id):
            let cell = hostingCell("record", at: indexPath)
            guard let row = rowsByID[id] else { return cell }
            cell.show(
                RecordRowView(row: row, showAccount: false, boxed: true)
                    .accessibilityAction(named: "编辑") { [weak self] in self?.editRecord(id) }
                    .accessibilityAction(named: "删除") { [weak self, weak cell] in
                        // 读屏不用滑开这一行，这时没有「删除」按钮，菜单从这一行弹出
                        if let cell { self?.confirmDelete(id, from: cell) { _ in } }
                    },
                parent: parent
            )
            return cell
        case .empty:
            let cell = hostingCell("empty", at: indexPath)
            cell.show(EmptyRecordsView(), parent: parent)
            return cell
        }
    }

    private func hostingCell(_ identifier: String, at indexPath: IndexPath) -> HostingCell {
        tableView.dequeueReusableCell(withIdentifier: identifier, for: indexPath) as! HostingCell
    }

    private func summaryView() -> some View {
        AccountDetailSummary(
            model: model,
            openPending: { [weak self] in self?.onOpenPending() },
            selectCurrency: { [weak self] currency in self?.setCurrency(currency) }
        )
    }

    // MARK: 格子尺寸

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let width = tableView.bounds.width
        switch dataSource.itemIdentifier(for: indexPath) {
        case .card:
            // 卡片画在列表上层，这里只留出位置：顶部按钮一行 + 卡片，下面空 8pt 才是余额区
            return AppLayout.detailTop + AppLayout.cardHeight(parent.view.bounds.width) + 8
        case .summary:
            return summaryHeight
        case .record(let id):
            return rowHeight(rowsByID[id], width: width)
        case .empty:
            if emptyHeight == nil { emptyHeight = measure(EmptyRecordsView(), width: width) }
            return emptyHeight ?? 1
        case nil:
            return 1
        }
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        isRecordSection(section) ? Self.rowSpacing : 0
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard isRecordSection(section) else { return nil }
        // 普通样式的组尾停在屏幕底部，不能挡住下面的行
        let gap = UIView()
        gap.isUserInteractionEnabled = false
        return gap
    }

    private func isRecordSection(_ section: Int) -> Bool {
        if case .record = dataSource.sectionIdentifier(for: section) { return true }
        return false
    }

    /// 宽度或系统字号变了：重新量高度
    func invalidateSizes() {
        recordRowHeight = nil
        emptyHeight = nil
        updateSummaryHeight()
        refreshHeights()
    }

    /// 列表不自己量高度，要它重新取一次
    private func refreshHeights() {
        UIView.performWithoutAnimation { tableView.performBatchUpdates(nil, completion: nil) }
    }

    private func measure(_ content: some View, width: CGFloat) -> CGFloat {
        sizer.rootView = AnyView(content)
        return sizer.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height.rounded(.up)
    }

    /// 流水行每一部分都只有一行，高度只取决于系统字号
    private func rowHeight(_ row: RecordRow?, width: CGFloat) -> CGFloat {
        guard let row else { return 1 }
        if let height = recordRowHeight { return height }
        let height = measure(RecordRowView(row: row, showAccount: false, boxed: true), width: width)
        recordRowHeight = height
        return height
    }

    private func updateSummaryHeight() {
        guard contentShown, account != nil else {
            summaryHeight = 0
            return
        }
        summaryHeight = measure(summaryView(), width: tableView.bounds.width)
    }

    // MARK: 滚动

    /// 往上滚动的距离；在顶部往下拉时为负
    var scrolledDistance: CGFloat { tableView.contentOffset.y + tableView.contentInset.top }

    /// 顶部留出状态栏，滚动距离不变
    func setTopInset(_ top: CGFloat) {
        guard tableView.contentInset.top != top else { return }
        let scrolled = scrolledDistance
        tableView.contentInset.top = top
        tableView.contentOffset.y = scrolled - top
    }

    /// 停止惯性滚动：返回时卡片从它现在的位置回卡包
    func stopScrolling() {
        tableView.setContentOffset(tableView.contentOffset, animated: false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onScroll()
    }

    // MARK: 打开 / 关闭

    /// 打开一张卡的详情。返回途中再点同一张卡、内容还没清空时，内容从当前位置升回来；
    /// 否则回到顶部，读到第一页流水后内容从屏幕底下升上来
    func open(_ account: Account) {
        tableView.isHidden = false
        tableView.isUserInteractionEnabled = true
        tableView.scrollsToTop = true
        tableView.accessibilityElementsHidden = false
        let layer = tableView.layer
        if contentShown, self.account?.id == account.id {
            let timing = CardMotion.entrance(reduceMotion: UIAccessibility.isReduceMotionEnabled)
            CardMotion.setTransform(layer, CATransform3DIdentity, timing: timing)
            CardMotion.setOpacity(layer, 1, timing: timing)
            return
        }
        self.account = account
        // 换了一张卡：从主币种、全部时间看起（只在变化时写入，写入会让读它的视图重新计算）
        let currency = account.isMultiCurrency ? account.currency : nil
        if model.currencies != account.currencies { model.currencies = account.currencies }
        if model.currency != currency { model.currency = currency }
        if model.period != .all { model.period = .all }
        contentShown = false
        rows = []
        rowsByID = [:]
        layer.removeAllAnimations()
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        applySnapshot(reconfigure: false)
        tableView.contentOffset = CGPoint(x: 0, y: -tableView.contentInset.top)
        load()
    }

    /// 返回：内容整块退到屏幕底下（和入场相反，与卡片同一个弹簧），不再接收触摸
    func close() {
        loadTask?.cancel()
        loadTask = nil
        closeOpenRow()
        stopScrolling()
        tableView.isUserInteractionEnabled = false
        tableView.scrollsToTop = false
        tableView.accessibilityElementsHidden = true
        let layer = tableView.layer
        if UIAccessibility.isReduceMotionEnabled {
            CardMotion.setOpacity(layer, 0, timing: .easeIn(0.15))
        } else {
            let away = CATransform3DMakeTranslation(0, tableView.bounds.height, 0)
            CardMotion.setTransform(layer, away, timing: CardMotion.transition(reduceMotion: false))
        }
    }

    /// 返回动画结束：隐藏并清空，下次打开从头开始
    func finishClose() {
        session += 1
        loadTask?.cancel()
        loadTask = nil
        account = nil
        contentShown = false
        rows = []
        rowsByID = [:]
        hasMore = false
        loadingMore = false
        tableView.isHidden = true
        let layer = tableView.layer
        layer.removeAllAnimations()
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        applySnapshot(reconfigure: false)
    }

    /// 详情打开时卡片信息变了（改名、停用、改了币种）
    func update(account: Account) {
        guard self.account?.id == account.id, self.account != account else { return }
        let currenciesChanged = self.account?.currencies != account.currencies
        self.account = account
        if currenciesChanged {
            model.currencies = account.currencies
            if !account.isMultiCurrency {
                model.currency = nil
            } else if model.currency.map({ !account.currencies.contains($0) }) ?? true {
                model.currency = account.currency
            }
            onCurrencyChange()
            reload()
        }
        applySnapshot(reconfigure: true)
    }

    /// 数据变了（新流水、改了初始余额、处理了待处理账单）：重新读第一页
    func reload() {
        guard account != nil, contentShown || loadTask != nil else { return }
        load()
    }

    /// 多币种的卡换一个币种看流水
    func setCurrency(_ currency: CurrencyCode) {
        guard model.currency != currency else { return }
        model.currency = currency
        onCurrencyChange()
        reload()
    }

    /// 换一个时间段看流水，笔数跟着变
    func setPeriod(_ period: RecordPeriod) {
        guard model.period != period else { return }
        model.period = period
        reload()
    }

    /// 当前看的流水：这张卡、选中的币种（主币种包括卡里没有的币种的交易）、时间段
    private var filter: RecordFilter? {
        guard let account else { return nil }
        let range = model.period.range()
        return RecordFilter(accountID: account.id, currency: model.currency, from: range.from, to: range.to, mergeFees: true)
    }

    // MARK: 数据

    /// 读第一页流水、笔数和待处理数量，读到后一起显示；第一次显示时内容从屏幕底下升上来
    private func load() {
        guard let account, let filter else { return }
        let id = account.id
        session += 1
        let session = session
        loadingMore = false
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let first = await self.store.records(filter, after: nil, limit: WalletDetailList.pageSize)
            let total = await self.store.recordCount(filter)
            let pending = await self.pendingCount(accountID: id)
            guard !Task.isCancelled, session == self.session else { return }
            self.loadTask = nil
            var seen = Set<String>()
            self.rows = first.filter { seen.insert($0.id).inserted }
            self.rowsByID = Dictionary(uniqueKeysWithValues: self.rows.map { ($0.id, $0) })
            self.hasMore = first.count == WalletDetailList.pageSize
            // 只在变化时写入：写入就会让读它的 SwiftUI 视图重新计算
            if self.model.recordTotal != total { self.model.recordTotal = total }
            if self.model.pendingCount != pending { self.model.pendingCount = pending }
            let reveal = !self.contentShown
            self.contentShown = true
            self.applySnapshot(reconfigure: true)
            if reveal {
                CardMotion.rise(
                    self.tableView.layer,
                    from: self.tableView.bounds.height,
                    timing: CardMotion.entrance(reduceMotion: UIAccessibility.isReduceMotionEnabled)
                )
            }
        }
    }

    private func pendingCount(accountID: String) async -> Int {
        guard store.pendingCount > 0, let account = store.account(id: accountID) else { return 0 }
        return await store.pendingItems().filter { PendingView.belongs($0, to: account) }.count
    }

    private func loadMore() {
        guard hasMore, !loadingMore, let filter, let last = rows.last else { return }
        loadingMore = true
        let session = session
        Task { [weak self] in
            guard let self else { return }
            let page = await self.store.records(filter, after: last, limit: WalletDetailList.pageSize)
            guard session == self.session else { return }
            self.loadingMore = false
            self.hasMore = page.count == WalletDetailList.pageSize
            let fresh = page.filter { self.rowsByID[$0.id] == nil }
            guard !fresh.isEmpty else { return }
            self.rows += fresh
            for row in fresh { self.rowsByID[row.id] = row }
            self.applySnapshot(reconfigure: false)
        }
    }

    private func applySnapshot(reconfigure: Bool) {
        let oldSummaryHeight = summaryHeight
        updateSummaryHeight()
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.card])
        snapshot.appendItems([.card], toSection: .card)
        if contentShown {
            snapshot.appendSections([.summary])
            snapshot.appendItems([.summary], toSection: .summary)
            if rows.isEmpty {
                snapshot.appendSections([.empty])
                snapshot.appendItems([.empty], toSection: .empty)
            }
            for row in rows {
                snapshot.appendSections([.record(row.id)])
                snapshot.appendItems([.record(row.id)], toSection: .record(row.id))
            }
        }
        if reconfigure {
            // 已经显示的格子内容可能变了（备注、状态、余额），重新配置；新出现的格子本来就会配置
            let shown = Set(dataSource.snapshot().itemIdentifiers)
            snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { shown.contains($0) })
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        // 流水行的高度不变，只有余额区会变
        if summaryHeight != oldSummaryHeight { refreshHeights() }
    }

    private var cardLabel: String? {
        guard let account else { return nil }
        let balance = store.balances[account.id]?.item(model.currency ?? account.currency)?.cardText ?? "余额未知"
        return "\(account.spokenTitle)，\(balance)"
    }

    // MARK: 点按

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        isRecord(indexPath)
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        isRecord(indexPath) ? indexPath : nil
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard case .record(let id) = dataSource.itemIdentifier(for: indexPath), let row = rowsByID[id] else { return }
        onSelectRecord(row)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard case .record(let id) = dataSource.itemIdentifier(for: indexPath), id == rows.last?.id else { return }
        loadMore()
    }

    private func isRecord(_ indexPath: IndexPath) -> Bool {
        if case .record = dataSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    // MARK: 左滑

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard case .record(let id) = dataSource.itemIdentifier(for: indexPath) else { return nil }
        // 和首页一样：不用 destructive（系统会马上把这一行划走，而这时还没有确认）；点了才算，滑到底不直接触发
        let delete = UIContextualAction(style: .normal, title: "删除") { [weak self] _, source, finished in
            self?.confirmDelete(id, from: source, finished: finished)
        }
        delete.image = UIImage(systemName: "trash")
        delete.backgroundColor = .systemRed
        let edit = UIContextualAction(style: .normal, title: "编辑") { [weak self] _, _, finished in
            finished(true)
            self?.editRecord(id)
        }
        edit.image = UIImage(systemName: "pencil")
        edit.backgroundColor = tableView.tintColor
        let configuration = UISwipeActionsConfiguration(actions: [delete, edit])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    func tableView(_ tableView: UITableView, willBeginEditingRowAt indexPath: IndexPath) {
        hasOpenRow = true
    }

    func tableView(_ tableView: UITableView, didEndEditingRowAt indexPath: IndexPath?) {
        hasOpenRow = false
    }

    private func closeOpenRow() {
        if hasOpenRow { tableView.setEditing(false, animated: true) }
    }

    private func editRecord(_ id: String) {
        closeOpenRow()
        if let row = rowsByID[id] { onEditRecord(row) }
    }

    /// 确认菜单从「删除」按钮弹出，这一行等菜单收起才合上
    private func confirmDelete(_ id: String, from source: UIView, finished: @escaping (Bool) -> Void) {
        guard let row = rowsByID[id], let container = parent.view else { return finished(false) }
        RecordDeleteMenuButton.show(
            row,
            at: source.convert(source.bounds, to: container),
            in: container,
            onDelete: { [weak self] in self?.onDeleteRecord(row) },
            onEnd: { finished(false) }
        )
    }
}

/// 系统的滑动按钮要数据源允许编辑这一行；这个数据源默认不允许
private final class RecordDataSource: UITableViewDiffableDataSource<WalletDetailList.Section, WalletDetailList.Item> {
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        if case .record = itemIdentifier(for: indexPath) { return true }
        return false
    }
}

/// 列表和卡片一样宽，两边的空白也算在列表里：手指放在那里一样能滚动、右滑返回
private final class DetailTableView: UITableView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -AppLayout.cardInset, dy: 0).contains(point)
    }
}

/// 一格由 SwiftUI 画的内容。用 `UIHostingController` 是为了关掉安全区：
/// 格子滚到状态栏下面时，SwiftUI 不会因为安全区变化把内容往下推、重新布局。
/// 内容贴着格子顶端：格子高度还没跟上内容时，内容只往下伸，不会居中往上跑到卡片后面
private final class HostingCell: UITableViewCell {
    private var host: UIHostingController<AnyView>?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ content: some View, parent: UIViewController) {
        let view = AnyView(content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        if let host {
            host.rootView = view
            return
        }
        let host = UIHostingController(rootView: view)
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.frame = contentView.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parent.addChild(host)
        contentView.addSubview(host.view)
        host.didMove(toParent: parent)
        self.host = host
    }
}

/// 详情顶部给选中卡片留的位置。卡片画在列表上层；读屏时这里代表卡片，激活即返回卡包
private final class CardSlotCell: UITableViewCell {
    var activate: () -> Void = {}

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "返回卡包"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func accessibilityActivate() -> Bool {
        activate()
        return true
    }
}
