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
/// 流水行左滑露出「编辑」「删除」（右滑是返回卡包，在 `WalletController`）。系统的滑动按钮只有自适应高度的列表布局才有，
/// 这里不用（见上），所以手势写在这里：只移动格子里 SwiftUI 那一层的显示位置，不重新布局。
@MainActor
final class WalletDetailList: NSObject, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
    enum Section: Int {
        case card, summary, records
    }

    enum Item: Hashable {
        case card
        case summary
        case record(String)
        /// 「暂无流水」
        case empty
    }

    let collectionView: UICollectionView
    /// 列表滚动了：卡片跟着移动
    var onScroll: () -> Void = {}
    var onSelectRecord: (RecordRow) -> Void = { _ in }
    var onEditRecord: (RecordRow) -> Void = { _ in }
    var onDeleteRecord: (RecordRow) -> Void = { _ in }
    var onOpenPending: () -> Void = {}
    /// 读屏激活顶部的卡片：返回卡包
    var onActivateCard: () -> Void = {}

    private let store: LedgerStore
    private let model: WalletDetailModel
    /// 格子里的 SwiftUI 宿主挂在它下面，跟随它的外观和字号
    private unowned let parent: UIViewController
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
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
    private let rowSwipe = UIPanGestureRecognizer()
    /// 手指按下的那一行
    private weak var touchedRow: RecordCell?
    /// 露着按钮的那一行，同时只有一行
    private weak var openRow: RecordCell?
    /// 这次滑动开始时那一行的位置
    private var swipeStart: CGFloat = 0

    /// 每页流水条数
    private static let pageSize = 40

    init(store: LedgerStore, model: WalletDetailModel, parent: UIViewController) {
        self.store = store
        self.model = model
        self.parent = parent
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        sizer = UIHostingController(rootView: AnyView(EmptyView()))
        super.init()

        sizer.safeAreaRegions = []
        sizer.view.isHidden = true
        parent.addChild(sizer)
        parent.view.addSubview(sizer.view)
        sizer.didMove(toParent: parent)

        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.selfSizingInvalidation = .disabled
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.scrollsToTop = false
        // 最后一行下面留白（详情里标签栏是隐藏的）
        collectionView.contentInset.bottom = 48
        collectionView.delegate = self

        rowSwipe.addTarget(self, action: #selector(rowSwiped(_:)))
        rowSwipe.maximumNumberOfTouches = 1
        rowSwipe.delegate = self
        collectionView.addGestureRecognizer(rowSwipe)
        // 先看是不是左滑这一行；不是的话（`gestureRecognizerShouldBegin` 说不）马上轮到滚动，不多等
        collectionView.panGestureRecognizer.require(toFail: rowSwipe)

        let cardSlot = UICollectionView.CellRegistration<CardSlotCell, Item> { [weak self] cell, _, _ in
            cell.accessibilityLabel = self?.cardLabel
            cell.activate = { [weak self] in self?.onActivateCard() }
        }
        let summary = UICollectionView.CellRegistration<HostingCell, Item> { [weak self] cell, _, _ in
            guard let self, self.account != nil else { return }
            cell.show(self.summaryView(), parent: self.parent)
        }
        let record = UICollectionView.CellRegistration<RecordCell, Item> { [weak self] cell, _, item in
            guard let self, case .record(let id) = item, let row = self.rowsByID[id] else { return }
            cell.onEdit = { [weak self] in self?.editRecord(id) }
            cell.onDelete = { [weak self] in self?.deleteRecord(id) }
            cell.show(
                RecordRowView(row: row, showAccount: false, boxed: true)
                    .accessibilityAction(named: "编辑") { [weak self] in self?.editRecord(id) }
                    .accessibilityAction(named: "删除") { [weak self] in self?.deleteRecord(id) },
                parent: self.parent
            )
        }
        let empty = UICollectionView.CellRegistration<HostingCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.show(EmptyRecordsView(), parent: self.parent)
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .card:
                return collectionView.dequeueConfiguredReusableCell(using: cardSlot, for: indexPath, item: item)
            case .summary:
                return collectionView.dequeueConfiguredReusableCell(using: summary, for: indexPath, item: item)
            case .record:
                return collectionView.dequeueConfiguredReusableCell(using: record, for: indexPath, item: item)
            case .empty:
                return collectionView.dequeueConfiguredReusableCell(using: empty, for: indexPath, item: item)
            }
        }
        applySnapshot(reconfigure: false)
    }

    private func summaryView() -> some View {
        AccountDetailSummary(
            model: model,
            openPending: { [weak self] in self?.onOpenPending() },
            selectCurrency: { [weak self] currency in self?.setCurrency(currency) }
        )
    }

    // MARK: 格子尺寸

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = collectionView.bounds.width
        let contentWidth = AppLayout.cardWidth(width)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .card:
            // 卡片画在列表上层，这里只留出位置：顶部按钮一行 + 卡片
            return CGSize(width: width, height: AppLayout.detailTop + AppLayout.cardHeight(width))
        case .summary:
            return CGSize(width: contentWidth, height: summaryHeight)
        case .record(let id):
            return CGSize(width: contentWidth, height: rowHeight(rowsByID[id], width: contentWidth))
        case .empty:
            if emptyHeight == nil { emptyHeight = measure(EmptyRecordsView(), width: contentWidth) }
            return CGSize(width: contentWidth, height: emptyHeight ?? 1)
        case nil:
            return CGSize(width: contentWidth, height: 1)
        }
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        let inset = AppLayout.cardInset
        switch Section(rawValue: section) {
        case .summary:
            return UIEdgeInsets(top: 8, left: inset, bottom: 0, right: inset)
        case .records:
            return UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        default:
            return .zero
        }
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        Section(rawValue: section) == .records ? 8 : 0
    }

    /// 宽度或系统字号变了：重新量高度
    func invalidateSizes() {
        recordRowHeight = nil
        emptyHeight = nil
        updateSummaryHeight()
        collectionView.collectionViewLayout.invalidateLayout()
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
        summaryHeight = measure(summaryView(), width: AppLayout.cardWidth(collectionView.bounds.width))
    }

    // MARK: 滚动

    /// 往上滚动的距离；在顶部往下拉时为负
    var scrolledDistance: CGFloat { collectionView.contentOffset.y + collectionView.contentInset.top }

    /// 顶部留出状态栏，滚动距离不变
    func setTopInset(_ top: CGFloat) {
        guard collectionView.contentInset.top != top else { return }
        let scrolled = scrolledDistance
        collectionView.contentInset.top = top
        collectionView.contentOffset.y = scrolled - top
    }

    /// 停止惯性滚动：返回时卡片从它现在的位置回卡包
    func stopScrolling() {
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onScroll()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        closeOpenRow()
    }

    // MARK: 打开 / 关闭

    /// 打开一张卡的详情。返回途中再点同一张卡、内容还没清空时，内容从当前位置升回来；
    /// 否则回到顶部，读到第一页流水后内容从屏幕底下升上来
    func open(_ account: Account) {
        collectionView.isHidden = false
        collectionView.isUserInteractionEnabled = true
        collectionView.scrollsToTop = true
        collectionView.accessibilityElementsHidden = false
        let layer = collectionView.layer
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
        collectionView.contentOffset = CGPoint(x: 0, y: -collectionView.contentInset.top)
        load()
    }

    /// 返回：内容整块退到屏幕底下（和入场相反，与卡片同一个弹簧），不再接收触摸
    func close() {
        loadTask?.cancel()
        loadTask = nil
        closeOpenRow()
        stopScrolling()
        collectionView.isUserInteractionEnabled = false
        collectionView.scrollsToTop = false
        collectionView.accessibilityElementsHidden = true
        let layer = collectionView.layer
        if UIAccessibility.isReduceMotionEnabled {
            CardMotion.setOpacity(layer, 0, timing: .easeIn(0.15))
        } else {
            let away = CATransform3DMakeTranslation(0, collectionView.bounds.height, 0)
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
        collectionView.isHidden = true
        let layer = collectionView.layer
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
                    self.collectionView.layer,
                    from: self.collectionView.bounds.height,
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
        updateSummaryHeight()
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.card])
        snapshot.appendItems([.card], toSection: .card)
        if contentShown {
            snapshot.appendSections([.summary, .records])
            snapshot.appendItems([.summary], toSection: .summary)
            snapshot.appendItems(rows.isEmpty ? [.empty] : rows.map { Item.record($0.id) }, toSection: .records)
        }
        if reconfigure {
            // 已经显示的格子内容可能变了（备注、状态、余额），重新配置；新出现的格子本来就会配置
            let shown = Set(dataSource.snapshot().itemIdentifiers)
            snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { shown.contains($0) })
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        if reconfigure {
            // 余额区、有没有备注变了时高度也会变；列表不自己量高度，要重新取一次
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    private var cardLabel: String? {
        guard let account else { return nil }
        let balance = store.balances[account.id]?.cardText ?? "余额未知"
        return "\(account.spokenTitle)，\(balance)"
    }

    // MARK: 点按

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        // 有一行露着按钮时，点一下只是把它合上
        if closeOpenRow() { return false }
        return isRecord(indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        isRecord(indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard case .record(let id) = dataSource.itemIdentifier(for: indexPath), let row = rowsByID[id] else { return }
        onSelectRecord(row)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard case .record(let id) = dataSource.itemIdentifier(for: indexPath), id == rows.last?.id else { return }
        loadMore()
    }

    private func isRecord(_ indexPath: IndexPath) -> Bool {
        if case .record = dataSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    // MARK: 左滑

    var hasOpenRow: Bool { openRow != nil }

    @discardableResult
    private func closeOpenRow() -> Bool {
        guard let openRow else { return false }
        openRow.settle(open: false)
        self.openRow = nil
        return true
    }

    private func editRecord(_ id: String) {
        closeOpenRow()
        if let row = rowsByID[id] { onEditRecord(row) }
    }

    private func deleteRecord(_ id: String) {
        closeOpenRow()
        if let row = rowsByID[id] { onDeleteRecord(row) }
    }

    /// 手指按下时就定下是哪一行：滑动识别出来时手指已经走了一段，可能离开了这一行
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard !collectionView.isDecelerating,
              let indexPath = collectionView.indexPathForItem(at: touch.location(in: collectionView)),
              let cell = collectionView.cellForItem(at: indexPath) as? RecordCell else { return false }
        touchedRow = cell
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let velocity = rowSwipe.velocity(in: collectionView)
        guard abs(velocity.x) > abs(velocity.y), let touchedRow else { return false }
        // 往右是返回卡包，只有这一行开着时才是把它合上
        return velocity.x < 0 || touchedRow === openRow
    }

    @objc private func rowSwiped(_ recognizer: UIPanGestureRecognizer) {
        guard let cell = touchedRow else { return }
        switch recognizer.state {
        case .began:
            if openRow !== cell { closeOpenRow() }
            swipeStart = cell.offset
            fallthrough
        case .changed:
            let x = swipeStart + recognizer.translation(in: collectionView).x
            // 超过按钮的宽度后手指走得多、行走得少
            cell.setOffset(x < -RecordCell.revealWidth ? (x - RecordCell.revealWidth * 2) / 3 : min(0, x))
        case .ended:
            // 松手时的速度也算上：轻轻一甩也能打开、合上
            let open = cell.offset + recognizer.velocity(in: collectionView).x * 0.2 < -RecordCell.revealWidth / 2
            cell.settle(open: open)
            openRow = open ? cell : nil
        case .cancelled, .failed:
            cell.settle(open: false)
            openRow = nil
        default:
            break
        }
    }
}

/// 一格由 SwiftUI 画的内容。用 `UIHostingController` 是为了关掉安全区：
/// 格子滚到状态栏下面时，SwiftUI 不会因为安全区变化把内容往下推、重新布局。
/// 内容贴着格子顶端：格子高度还没跟上内容时，内容只往下伸，不会居中往上跑到卡片后面
private class HostingCell: UICollectionViewCell {
    fileprivate var host: UIHostingController<AnyView>?

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

/// 一行流水：SwiftUI 那一层往左移，露出压在它下面的「编辑」「删除」。平时按钮隐藏，不参与合成。
private final class RecordCell: HostingCell {
    private static let buttonWidth: CGFloat = 76
    private static let spacing: CGFloat = 8
    /// 打开时行往左移的距离
    static let revealWidth = (buttonWidth + spacing) * 2

    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}
    private(set) var offset: CGFloat = 0
    private let buttons = UIView()
    private lazy var editButton = Self.button("编辑", symbol: "pencil", color: nil) { [weak self] in self?.onEdit() }
    private lazy var deleteButton = Self.button("删除", symbol: "trash", color: .systemRed) { [weak self] in self?.onDelete() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        buttons.frame = contentView.bounds
        buttons.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        buttons.isHidden = true
        buttons.addSubview(editButton)
        buttons.addSubview(deleteButton)
        contentView.addSubview(buttons)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `color` 为 nil 时跟主题色
    private static func button(_ title: String, symbol: String, color: UIColor?, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePlacement = .top
        configuration.imagePadding = 2
        configuration.buttonSize = .small
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 18
        configuration.baseBackgroundColor = color
        configuration.baseForegroundColor = .white
        return UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = buttons.bounds
        deleteButton.frame = CGRect(x: bounds.maxX - Self.buttonWidth, y: 0, width: Self.buttonWidth, height: bounds.height)
        editButton.frame = deleteButton.frame.offsetBy(dx: -(Self.buttonWidth + Self.spacing), dy: 0)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        host?.view.layer.removeAllAnimations()
        setOffset(0)
    }

    /// 手指拖着走
    func setOffset(_ x: CGFloat) {
        offset = x
        buttons.isHidden = x == 0
        host?.view.transform = CGAffineTransform(translationX: x, y: 0)
    }

    /// 松手：弹到打开或合上的位置
    func settle(open: Bool) {
        let target = open ? -Self.revealWidth : 0
        offset = target
        UIView.animate(springDuration: 0.35, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.host?.view.transform = CGAffineTransform(translationX: target, y: 0)
        } completion: { _ in
            self.buttons.isHidden = self.offset == 0
        }
    }
}

/// 详情顶部给选中卡片留的位置。卡片画在列表上层；读屏时这里代表卡片，激活即返回卡包
private final class CardSlotCell: UICollectionViewCell {
    var activate: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
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
