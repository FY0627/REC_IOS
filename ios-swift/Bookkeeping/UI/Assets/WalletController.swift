import SwiftUI
import UIKit
import BKModel

/// 资产页交给卡包的操作：弹出各个页面
struct WalletActions {
    /// 打开了一张卡（它的标识）或返回了卡包（nil）：资产页据此隐藏标签栏
    var selectionChanged: (String?) -> Void = { _ in }
    var addAccount: () -> Void = {}
    /// 卡包状态的「更多」
    var manageAccounts: () -> Void = {}
    var openInfo: () -> Void = {}
    var openFace: () -> Void = {}
    var openPending: () -> Void = {}
    var openRecord: (RecordRow) -> Void = { _ in }
    /// 流水左滑露出的两个按钮；删除在列表里确认过才到这里
    var editRecord: (RecordRow) -> Void = { _ in }
    var deleteRecord: (RecordRow) -> Void = { _ in }
    /// 流水的时间段选了「自定义…」
    var chooseCustomPeriod: () -> Void = {}
}

/// 资产页通过它换详情里流水的时间段（自定义时间的面板），再点一次标签栏的「资产」时让卡包滚回顶部。
@MainActor
final class WalletBridge {
    weak var controller: WalletController?

    func setPeriod(_ period: RecordPeriod) {
        controller?.setPeriod(period)
    }

    func scrollToTop() {
        controller?.scrollToTop()
    }
}

/// 卡包和卡片详情。界面和转场是 UIKit（`WalletController`），卡面、标题区、详情内容和每一行流水仍由 SwiftUI 画。
struct WalletPage: UIViewControllerRepresentable {
    /// 卡包顺序：使用中的卡在前，已停用的卡在后
    let accounts: [Account]
    let activeCount: Int
    /// 卡面上显示的余额
    let balanceTexts: [String: String]
    let revision: Int
    let store: LedgerStore
    let rates: ExchangeRateStore
    let detail: WalletDetailModel
    let bridge: WalletBridge
    let actions: WalletActions

    func makeUIViewController(context: Context) -> WalletController {
        let controller = WalletController(store: store, rates: rates, detail: detail)
        bridge.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: WalletController, context: Context) {
        controller.actions = actions
        controller.update(accounts: accounts, activeCount: activeCount, balanceTexts: balanceTexts, revision: revision)
    }
}

/// 资产页的卡包 → 点按卡片展开详情 → 返回。
///
/// 转场参考 Apple 钱包：选中的卡片移到顶部；它上面的卡一边上移一边缩小，收到选中卡片后面；
/// 它下面的卡同时向下落出屏幕；详情内容从屏幕底下整块升上来。返回时内容整块退到屏幕底下，卡片回到原位，
/// 下面的卡同时升回来，像原来一样压住它的下半部分。
///
/// 做法和钱包一样用 UIKit + Core Animation（ADR 0012）：
/// - 每张卡只有一个视图，放在卡包和详情两个滚动区的上层，按滚动距离摆放：卡包里的卡跟卡包滚动，选中的卡跟详情滚动。
///   层级始终按卡包顺序，下面的卡压在选中的卡和详情内容上面；
/// - 打开 / 关闭时把卡片的模型位置直接改成终点，再加 Core Animation 的叠加动画（`CardMotion`），由系统渲染进程播放，
///   主线程读流水、生成列表行都不影响动画。动画途中滚动或再次点按，新的位移叠加上去，卡片从当前位置平滑转向；
/// - 卡片不接收触摸。点按由下面的滚动区识别，再按卡片显示的位置（动画途中也是）找到点中的卡；
///   拖动卡片就是拖动下面的滚动区，所以点开马上能滑，返回一开始卡包就能滑、能点；
/// - 顶部按钮（`WalletTopBar`）也是 UIKit 的液态玻璃，和卡片同时开始动画；
/// - 屏幕外的卡不画（隐藏，不参与合成）。打开 / 关闭时只有起点或终点在屏幕上的卡做动画，
///   卡包滚到很下面时，上面滚出屏幕的卡不跟着飞进来，下面看不见的卡也不用落下去。
final class WalletController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var actions = WalletActions()

    private let store: LedgerStore
    private let rates: ExchangeRateStore
    private let detailModel: WalletDetailModel

    // 从下到上：详情列表、卡包、卡片、顶部按钮。详情打开时卡包不接收触摸，触摸落到下面的详情
    private var detailList: WalletDetailList!
    private let stackScroll = UIScrollView()
    private let cardsView = UIView()
    private let topBar = WalletTopBar()
    private var headerHost: UIHostingController<WalletHeader>!
    private var archivedTitleHost: UIHostingController<ArchivedPileTitle>!
    private var stackTap: UITapGestureRecognizer!
    private var detailTap: UITapGestureRecognizer!
    private var detailSwipe: UIPanGestureRecognizer!

    private var accounts: [Account] = []
    private var activeCount = 0
    private var balanceTexts: [String: String] = [:]
    private var revision: Int?
    /// 状态栏（灵动岛）高度：卡包和详情铺满屏幕，内容从它下面开始。从窗口读，SwiftUI 传进来的安全区在这里是 0
    private var safeTop: CGFloat = 0
    /// 上次布局时的宽度；变了要重新量详情格子的高度
    private var laidOutWidth: CGFloat = 0
    /// 按卡包顺序
    private var cards: [StackCardView] = []
    private var headerHeight: CGFloat = 0

    /// 打开的卡在卡包里的位置
    private var selectedIndex: Int?
    /// 打开动画进行中，收在后面的卡还看得见，跟着详情滚动；之后它们已透明，滚动时不再移动（返回时再摆到选中卡的位置）
    private var behindFollowsScroll = false
    /// 下面的卡落下的距离：页面高度；卡包顶端已滚出屏幕时再加上滚出的部分，保证落到屏幕外
    private var dropDistance: CGFloat = 0
    /// 每次打开 / 关闭 +1；延迟执行的收尾据此判断自己是否已经过时
    private var motionToken = 0
    /// 正在打开 / 关闭的动画里要显示的卡：动画停稳之前，模型位置在屏幕外也不隐藏
    private var transitionCards: Set<ObjectIdentifier> = []
    /// 转场停稳的时间：之后只显示屏幕上的卡
    private static let transitionSettle: Duration = .milliseconds(900)

    init(store: LedgerStore, rates: ExchangeRateStore, detail: WalletDetailModel) {
        self.store = store
        self.rates = rates
        self.detailModel = detail
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        detailList = WalletDetailList(store: store, model: detailModel, parent: self)
        let list = detailList.collectionView
        list.isHidden = true
        list.accessibilityElementsHidden = true
        view.addSubview(list)
        detailList.onScroll = { [weak self] in self?.detailScrolled() }
        detailList.onSelectRecord = { [weak self] row in self?.actions.openRecord(row) }
        detailList.onEditRecord = { [weak self] row in self?.actions.editRecord(row) }
        detailList.onDeleteRecord = { [weak self] row in self?.actions.deleteRecord(row) }
        detailList.onOpenPending = { [weak self] in self?.actions.openPending() }
        detailList.onActivateCard = { [weak self] in self?.close() }

        stackScroll.delegate = self
        stackScroll.backgroundColor = .clear
        stackScroll.contentInsetAdjustmentBehavior = .never
        stackScroll.alwaysBounceVertical = true
        stackScroll.showsVerticalScrollIndicator = false
        stackScroll.showsHorizontalScrollIndicator = false
        view.addSubview(stackScroll)
        headerHost = host(makeHeader(), in: stackScroll)
        archivedTitleHost = host(ArchivedPileTitle(count: 0), in: stackScroll)

        cardsView.isUserInteractionEnabled = false
        // 读屏用卡包滚动区里的代替元素（见 updateCardElements），这里的卡片视图不出现
        cardsView.accessibilityElementsHidden = true
        view.addSubview(cardsView)

        view.addSubview(topBar)
        topBar.onBack = { [weak self] in self?.close() }
        topBar.onAdd = { [weak self] in self?.actions.addAccount() }
        topBar.onManage = { [weak self] in self?.actions.manageAccounts() }
        topBar.moreMenu = { [weak self] in self?.moreMenuItems() ?? [] }
        topBar.periodMenu = { [weak self] in self?.periodMenuItems() ?? [] }

        stackTap = UITapGestureRecognizer(target: self, action: #selector(stackTapped(_:)))
        stackTap.delegate = self
        stackScroll.addGestureRecognizer(stackTap)

        detailTap = UITapGestureRecognizer(target: self, action: #selector(detailTapped(_:)))
        detailTap.delegate = self
        list.addGestureRecognizer(detailTap)

        // 右滑返回卡包（左滑不响应，避免误触）
        detailSwipe = UIPanGestureRecognizer(target: self, action: #selector(detailSwiped(_:)))
        detailSwipe.delegate = self
        list.addGestureRecognizer(detailSwipe)

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: WalletController, _: UITraitCollection) in
            controller.detailList.invalidateSizes()
            controller.view.setNeedsLayout()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // 第一次放进窗口后才读得到状态栏高度
        view.setNeedsLayout()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    /// SwiftUI 画的内容放进 UIKit：不使用安全区（位置由这里决定，滚到状态栏下面时内容也不移动），背景透明
    private func host<Content: View>(_ content: Content, in container: UIView) -> UIHostingController<Content> {
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        addChild(host)
        container.addSubview(host.view)
        host.didMove(toParent: self)
        return host
    }

    private func makeHeader() -> WalletHeader {
        WalletHeader(count: activeCount, store: store, rates: rates, addAccount: { [weak self] in self?.actions.addAccount() })
    }

    // MARK: 数据

    func update(accounts: [Account], activeCount: Int, balanceTexts: [String: String], revision: Int) {
        loadViewIfNeeded()
        var needsLayout = false
        let textsChanged = balanceTexts != self.balanceTexts
        self.balanceTexts = balanceTexts
        if accounts != self.accounts || activeCount != self.activeCount {
            let selectedID = selectedIndex.map { self.accounts[$0].id }
            self.accounts = accounts
            self.activeCount = activeCount
            syncCards()
            headerHost.rootView = makeHeader()
            archivedTitleHost.rootView = ArchivedPileTitle(count: accounts.count - activeCount)
            if let selectedID { keepSelection(selectedID) }
            needsLayout = true
        } else if textsChanged {
            syncCards()
        }
        if revision != self.revision {
            self.revision = revision
            detailList.reload()
        }
        if needsLayout {
            view.setNeedsLayout()
            view.layoutIfNeeded()
        } else if textsChanged {
            updateCardElements(stackLayout)
        }
    }

    /// 卡片视图和账户一一对应：新卡新建，没了的卡移除，其余更新卡面。层级按卡包顺序，后面的卡在上层
    private func syncCards() {
        var existing: [String: StackCardView] = [:]
        for card in cards { existing[card.account.id] = card }
        let width = view.bounds.width
        let size = CGSize(width: AppLayout.cardWidth(width), height: AppLayout.cardHeight(width))
        var ordered: [StackCardView] = []
        for account in accounts {
            let text = balanceTexts[account.id] ?? "余额未知"
            if let card = existing.removeValue(forKey: account.id) {
                card.update(account: account, balanceText: text)
                ordered.append(card)
            } else {
                let card = StackCardView(account: account, balanceText: text)
                card.bounds = CGRect(origin: .zero, size: size)
                addChild(card.host)
                cardsView.addSubview(card)
                card.host.didMove(toParent: self)
                ordered.append(card)
            }
        }
        for card in existing.values {
            card.host.willMove(toParent: nil)
            card.removeFromSuperview()
            card.host.removeFromParent()
        }
        cards = ordered
        for card in ordered { cardsView.bringSubviewToFront(card) }
    }

    /// 详情打开时卡片换了位置（停用 / 启用）：详情保持打开，按新位置重新区分上面和下面的卡；卡片没了就直接关闭
    private func keepSelection(_ id: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            closeImmediately()
            return
        }
        detailList.update(account: accounts[index])
        // 位置没变（例如只改了卡面、初始余额）时不动卡片，正在进行的转场继续
        guard index != selectedIndex else { return }
        selectedIndex = index
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        for (i, card) in cards.enumerated() {
            let behind = role(i) == .behind
            let transform = behind && !reduceMotion ? CardMotion.behindTransform : CATransform3DIdentity
            CardMotion.setTransform(card.layer, transform, timing: nil)
            CardMotion.setOpacity(card.layer, behind ? 0 : 1, timing: nil)
        }
        transitionCards = []
    }

    // MARK: 布局

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let window = view.window { safeTop = window.safeAreaInsets.top }
        let bounds = view.bounds
        // 只改尺寸和中心：详情列表返回时带着下移的变换，这时不能设 frame；滚动区的 bounds 原点是滚动位置，不能动
        for subview in [detailList.collectionView, stackScroll, cardsView] as [UIView] {
            if subview.bounds.size != bounds.size { subview.bounds.size = bounds.size }
            subview.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        if bounds.width != laidOutWidth {
            laidOutWidth = bounds.width
            detailList.invalidateSizes()
        }
        // 和资产页标题「资产」同一行：状态栏下面 2pt
        let barFrame = CGRect(x: AppLayout.cardInset, y: safeTop + 2, width: bounds.width - 2 * AppLayout.cardInset, height: WalletTopBar.height)
        if topBar.frame != barFrame { topBar.frame = barFrame }
        layoutStack()
    }

    private var stackLayout: StackLayout {
        let width = view.bounds.width
        return StackLayout(
            active: activeCount,
            archived: accounts.count - activeCount,
            cardHeight: AppLayout.cardHeight(width),
            peek: AppLayout.peek(width)
        )
    }

    /// 标题区、「已停用」标题、卡包内容高度和所有卡片的位置
    private func layoutStack() {
        let width = view.bounds.width
        guard width > 0 else { return }
        let inset = AppLayout.cardInset
        let contentWidth = AppLayout.cardWidth(width)

        if stackScroll.contentInset.top != safeTop {
            let scrolled = stackScroll.contentOffset.y + stackScroll.contentInset.top
            stackScroll.contentInset.top = safeTop
            stackScroll.contentOffset.y = scrolled - safeTop
        }
        detailList.setTopInset(safeTop)

        headerHeight = headerHost.sizeThatFits(in: CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height.rounded(.up)
        place(headerHost.view, CGRect(x: inset, y: 0, width: contentWidth, height: headerHeight))
        let layout = stackLayout
        archivedTitleHost.view.isHidden = layout.archived == 0
        place(archivedTitleHost.view, CGRect(x: inset, y: headerHeight + layout.archivedTitleY, width: contentWidth, height: StackLayout.sectionTitleHeight))
        // 下方留白在标签栏下面（页面铺满屏幕）
        stackScroll.contentSize = CGSize(width: width, height: headerHeight + layout.height + 120)
        if selectedIndex == nil, !stackScroll.isDragging, !stackScroll.isDecelerating {
            // 卡片变少、内容变短时不停在内容外面（手指拖动和惯性滚动时不打断）
            let maxOffset = max(-safeTop, stackScroll.contentSize.height - stackScroll.bounds.height)
            if stackScroll.contentOffset.y > maxOffset { stackScroll.contentOffset.y = maxOffset }
        }

        let size = CGSize(width: contentWidth, height: layout.cardHeight)
        for card in cards where card.bounds.size != size {
            card.bounds = CGRect(origin: .zero, size: size)
        }
        placeCards()
        updateCardElements(layout)
    }

    /// 用 bounds 和 center 摆放：视图可能带着变换（标题区淡出时上移），这时不能直接设 frame
    private func place(_ view: UIView, _ rect: CGRect) {
        if view.bounds.size != rect.size { view.bounds = CGRect(origin: .zero, size: rect.size) }
        view.center = CGPoint(x: rect.midX, y: rect.midY)
    }

    // MARK: 卡片位置

    private enum CardRole {
        /// 卡包里按顺序叠放
        case resting
        /// 选中的卡：在详情顶部，跟详情滚动
        case selected
        /// 选中卡上面的卡：收在选中卡后面，缩小并向里倾斜，最后隐藏
        case behind
        /// 选中卡下面的卡：落出屏幕
        case below
    }

    private func role(_ index: Int) -> CardRole {
        guard let selectedIndex else { return .resting }
        if index == selectedIndex { return .selected }
        return index < selectedIndex ? .behind : .below
    }

    /// 卡包顶端（第一张卡的上边缘）在屏幕上的位置
    private var pileTop: CGFloat { headerHeight - stackScroll.contentOffset.y }

    /// 详情里卡片上边缘在屏幕上的位置：跟着详情往上滚；在顶部往下拉时不动
    private var detailCardTop: CGFloat { safeTop + AppLayout.detailTop - max(0, detailList.scrolledDistance) }

    private func cardTop(_ index: Int, _ layout: StackLayout) -> CGFloat {
        switch role(index) {
        case .resting: pileTop + layout.restY(index)
        case .selected, .behind: detailCardTop
        case .below: pileTop + layout.restY(index) + dropDistance
        }
    }

    /// 按当前状态把卡片放到位：只改模型位置，不加动画，进行中的叠加动画继续叠在上面。
    /// 滚动时每一帧调用，卡片和滚动区在同一帧移动
    private func placeCards(only roles: Set<CardRole>? = nil) {
        guard !cards.isEmpty else { return }
        let layout = stackLayout
        let x = cardsView.bounds.midX
        UIView.performWithoutAnimation {
            for (index, card) in cards.enumerated() {
                if let roles, !roles.contains(role(index)) { continue }
                card.center = CGPoint(x: x, y: cardTop(index, layout) + card.bounds.height / 2)
            }
        }
        cullCards()
    }

    /// 卡片上边缘在 `top` 时，有没有一部分在屏幕上（多算一点阴影）
    private func isOnScreen(top: CGFloat, _ layout: StackLayout) -> Bool {
        let margin: CGFloat = 16
        return top < view.bounds.height + margin && top + layout.cardHeight > -margin
    }

    /// 屏幕外的卡、透明的卡隐藏起来，不参与绘制；转场途中要显示的卡除外
    private func cullCards() {
        let layout = stackLayout
        for card in cards {
            let shown = transitionCards.contains(ObjectIdentifier(card))
                || (card.layer.opacity > 0 && isOnScreen(top: card.center.y - card.bounds.height / 2, layout))
            if card.isHidden == shown { card.isHidden = !shown }
        }
    }

    /// 转场停稳后：不再特别保留哪张卡，只显示屏幕上的
    private func finishTransition(_ token: Int) {
        guard token == motionToken else { return }
        transitionCards = []
        cullCards()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        placeCards(only: [.resting, .below])
    }

    /// 再点一次标签栏的「资产」：卡包滚回顶部（和其他标签页的系统行为一样）。卡包是 UIKit 的滚动区，系统不会替它滚
    func scrollToTop() {
        guard selectedIndex == nil else { return }
        stackScroll.setContentOffset(CGPoint(x: 0, y: -stackScroll.contentInset.top), animated: true)
    }

    private func detailScrolled() {
        placeCards(only: behindFollowsScroll ? [.selected, .behind] : [.selected])
    }

    // MARK: 转场

    private func openCard(_ index: Int) {
        guard selectedIndex == nil, cards.indices.contains(index) else { return }
        motionToken += 1
        let token = motionToken
        let signpost = AppServices.signposter.beginInterval("DetailOpen")
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let account = accounts[index]

        // 卡包停在当前位置，之后不接收触摸
        stackScroll.setContentOffset(stackScroll.contentOffset, animated: false)
        stackScroll.isUserInteractionEnabled = false
        stackScroll.scrollsToTop = false
        stackScroll.accessibilityElementsHidden = true

        let before = cards.map(\.center.y)
        let wasShown = cards.map { !$0.isHidden }
        selectedIndex = index
        behindFollowsScroll = true
        dropDistance = view.bounds.height + max(0, -pileTop)
        detailList.open(account)
        topBar.setPeriodTitle(detailModel.period.title, animated: false)
        topBar.setDetail(true, animated: true)
        // 只有看得见的卡做动画：选中的卡，和本来就在屏幕上的上面、下面的卡。
        // 滚出屏幕的上面的卡直接收起来，看不见的下面的卡直接落到屏幕外
        let moving = Set(cards.indices.filter { role($0) == .selected || wasShown[$0] })
        transitionCards = Set(moving.map { ObjectIdentifier(cards[$0]) })
        placeCards()

        let transition = CardMotion.transition(reduceMotion: reduceMotion)
        for (i, card) in cards.enumerated() {
            let layer = card.layer
            let delta = before[i] - card.center.y
            guard moving.contains(i) else {
                if role(i) == .behind {
                    CardMotion.setTransform(layer, reduceMotion ? CATransform3DIdentity : CardMotion.behindTransform, timing: nil)
                    CardMotion.setOpacity(layer, 0, timing: nil)
                }
                continue
            }
            switch role(i) {
            case .selected:
                CardMotion.addMove(layer, deltaY: delta, timing: transition)
            case .behind:
                CardMotion.addMove(layer, deltaY: delta, timing: transition)
                if !reduceMotion {
                    CardMotion.setTransform(layer, CardMotion.behindTransform, timing: transition)
                }
                // 先收到后面，末段再淡出（这时已被选中的卡挡住，淡出后不再参与绘制）
                CardMotion.setOpacity(layer, 0, timing: .easeIn(0.15), delay: 0.25)
            case .below:
                CardMotion.addMove(layer, deltaY: delta, timing: reduceMotion ? transition : CardMotion.drop)
            case .resting:
                break
            }
        }
        setHeaderShown(false, reduceMotion: reduceMotion)
        announceScreenChange()
        actions.selectionChanged(account.id)
        FrameMonitor.current?.watch(cards[index].layer, title: "展开")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            AppServices.signposter.endInterval("DetailOpen", signpost)
            // 收在后面的卡这时已经透明，滚动详情时不再移动它们
            guard let self, token == self.motionToken else { return }
            self.behindFollowsScroll = false
            try? await Task.sleep(for: Self.transitionSettle - .milliseconds(500))
            self.finishTransition(token)
        }
    }

    /// 详情里流水换一个时间段：顶部时间段胶囊的菜单，或自定义时间的面板
    func setPeriod(_ period: RecordPeriod) {
        detailList.setPeriod(period)
        topBar.setPeriodTitle(detailModel.period.title, animated: true)
    }

    /// 顶部时间段胶囊的菜单：常用时间段，另起一组「自定义…」（选中时写自定义的日期）
    private func periodMenuItems() -> [UIMenuElement] {
        let current = detailModel.period
        let presets: [UIMenuElement] = RecordPeriod.presets.map { period in
            UIAction(title: period.title, state: period == current ? .on : .off) { [weak self] _ in self?.setPeriod(period) }
        }
        let custom = UIAction(title: current.isCustom ? current.title : "自定义…", state: current.isCustom ? .on : .off) { [weak self] _ in
            self?.actions.chooseCustomPeriod()
        }
        return presets + [UIMenu(options: .displayInline, children: [custom])]
    }

    /// 详情里「更多」的菜单
    private func moreMenuItems() -> [UIMenuElement] {
        let pending = detailModel.pendingCount
        return [
            UIAction(title: "卡片信息", image: UIImage(systemName: "creditcard")) { [weak self] _ in self?.actions.openInfo() },
            UIAction(title: "编辑卡面", image: UIImage(systemName: "paintbrush")) { [weak self] _ in self?.actions.openFace() },
            UIAction(title: pending > 0 ? "待处理账单（\(pending)）" : "待处理账单", image: UIImage(systemName: "tray")) { [weak self] _ in
                self?.actions.openPending()
            },
        ]
    }

    func close() {
        guard selectedIndex != nil else { return }
        motionToken += 1
        let token = motionToken
        let signpost = AppServices.signposter.beginInterval("DetailClose")
        let reduceMotion = UIAccessibility.isReduceMotionEnabled

        // 详情停在当前位置：卡片从它现在的位置（详情滚动过就更靠上）回卡包。
        // 收在后面的卡已透明，先不带动画摆到选中卡的位置，再和它一起回去
        detailList.stopScrolling()
        placeCards(only: [.selected, .behind])
        let roles = cards.indices.map { role($0) }
        let before = cards.map(\.center.y)
        selectedIndex = nil
        behindFollowsScroll = false
        // 只有回到屏幕上的卡做动画；回到屏幕外的直接放回卡包
        let layout = stackLayout
        let moving = Set(cards.indices.filter { roles[$0] == .selected || isOnScreen(top: cardTop($0, layout), layout) })
        transitionCards = Set(moving.map { ObjectIdentifier(cards[$0]) })
        placeCards()

        let transition = CardMotion.transition(reduceMotion: reduceMotion)
        for (i, card) in cards.enumerated() {
            let layer = card.layer
            let delta = before[i] - card.center.y
            guard moving.contains(i) else {
                if roles[i] == .behind {
                    CardMotion.setTransform(layer, CATransform3DIdentity, timing: nil)
                    CardMotion.setOpacity(layer, 1, timing: nil)
                }
                continue
            }
            switch roles[i] {
            case .selected:
                CardMotion.addMove(layer, deltaY: delta, timing: transition)
            case .behind:
                CardMotion.addMove(layer, deltaY: delta, timing: transition)
                CardMotion.setTransform(layer, CATransform3DIdentity, timing: transition)
                CardMotion.setOpacity(layer, 1, timing: .easeOut(0.1))
            case .below:
                // 稍晚一点，让详情内容先开始退下。下面的卡走得最远（一整屏多）：带回弹的弹簧会冲过头 4pt 左右再退回来，
                // 正好在快收完的时候，和选中的卡错开，看起来顿一下，所以用不回弹的弹簧
                let rise = PerfFlags.shared.gentleCardReturn ? CardMotion.entrance(reduceMotion: reduceMotion) : transition
                CardMotion.addMove(layer, deltaY: delta, timing: rise, delay: reduceMotion ? 0 : CardMotion.riseDelay)
            case .resting:
                break
            }
        }
        // 调试指标盯走得最远的卡：下面的卡，没有时是选中的卡
        if let farthest = moving.first(where: { roles[$0] == .below }) ?? moving.first(where: { roles[$0] == .selected }) {
            FrameMonitor.current?.watch(cards[farthest].layer, title: "返回")
        }
        // 内容退到屏幕底下；卡包马上能滑动、能点，返回途中再点卡片会从当前位置转向重新打开
        detailList.close()
        topBar.setDetail(false, animated: true)
        stackScroll.isUserInteractionEnabled = true
        stackScroll.scrollsToTop = true
        stackScroll.accessibilityElementsHidden = false
        setHeaderShown(true, reduceMotion: reduceMotion)
        announceScreenChange()
        actions.selectionChanged(nil)
        let cleanUpLate = PerfFlags.shared.lateDetailCleanup
        Task { @MainActor [weak self] in
            // 详情内容已退到屏幕外，隐藏并清空。这一步要拆掉列表里的格子，
            // 0.5 秒时卡片还在收尾，所以等全部停稳再做；停稳前再点同一张卡，内容从当前位置升回来
            try? await Task.sleep(for: .milliseconds(500))
            AppServices.signposter.endInterval("DetailClose", signpost)
            guard let self, token == self.motionToken else { return }
            if !cleanUpLate { self.detailList.finishClose() }
            try? await Task.sleep(for: Self.transitionSettle - .milliseconds(500))
            guard token == self.motionToken else { return }
            if cleanUpLate { self.detailList.finishClose() }
            self.finishTransition(token)
        }
    }

    /// 打开的卡没了（例如数据被清空）：不带动画回到卡包
    private func closeImmediately() {
        motionToken += 1
        selectedIndex = nil
        behindFollowsScroll = false
        transitionCards = []
        for view in cards.map({ $0 as UIView }) + [headerHost.view, archivedTitleHost.view].compactMap({ $0 }) {
            view.layer.removeAllAnimations()
            view.layer.transform = CATransform3DIdentity
            view.layer.opacity = 1
        }
        detailList.close()
        detailList.finishClose()
        topBar.setDetail(false, animated: false)
        stackScroll.isUserInteractionEnabled = true
        stackScroll.scrollsToTop = true
        stackScroll.accessibilityElementsHidden = false
        // 这时正在 SwiftUI 更新视图的过程中，改它的状态要放到之后
        Task { @MainActor [weak self] in self?.actions.selectionChanged(nil) }
    }

    /// 标题区和「已停用」标题随详情打开向上淡出，返回时在卡片回位后淡入
    private func setHeaderShown(_ shown: Bool, reduceMotion: Bool) {
        let transition = CardMotion.transition(reduceMotion: reduceMotion)
        for view in [headerHost.view, archivedTitleHost.view].compactMap({ $0 }) {
            CardMotion.setTransform(view.layer, shown ? CATransform3DIdentity : CATransform3DMakeTranslation(0, -32, 0), timing: transition)
            CardMotion.setOpacity(view.layer, shown ? 1 : 0, timing: shown ? .easeIn(0.2) : .easeOut(0.18), delay: shown ? 0.18 : 0)
        }
    }

    // MARK: 手势

    @objc private func stackTapped(_ recognizer: UITapGestureRecognizer) {
        guard let index = cardIndex(at: recognizer.location(in: cardsView), roles: [.resting]) else { return }
        openCard(index)
    }

    @objc private func detailTapped(_ recognizer: UITapGestureRecognizer) {
        close()
    }

    @objc private func detailSwiped(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let translation = recognizer.translation(in: view)
        let velocity = recognizer.velocity(in: view)
        // 按系统滚动的减速率估算松手后还会滑多远
        let rate = UIScrollView.DecelerationRate.normal.rawValue
        let predicted = translation.x + velocity.x / 1000 * rate / (1 - rate)
        if translation.x > 70, abs(translation.y) < 60, predicted > 140 { close() }
    }

    /// 点按位置上最上层的卡，按卡片显示的位置找（动画途中也是）。卡包里后面的卡压在前面的卡上
    private func cardIndex(at point: CGPoint, roles: Set<CardRole>) -> Int? {
        for index in cards.indices.reversed() where roles.contains(role(index)) {
            let layer = cards[index].layer
            let shown = layer.presentation() ?? layer
            if shown.opacity > 0.5, shown.frame.contains(point) { return index }
        }
        return nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === stackTap {
            // 卡包正在惯性滚动时，点一下只是让它停下
            return !stackScroll.isDecelerating && cardIndex(at: touch.location(in: cardsView), roles: [.resting]) != nil
        }
        if gestureRecognizer === detailTap {
            return cardIndex(at: touch.location(in: cardsView), roles: [.selected]) != nil
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === detailSwipe else { return true }
        let velocity = detailSwipe.velocity(in: view)
        // 有一行流水露着按钮时，右滑是把它合上
        return velocity.x > abs(velocity.y) && !detailList.hasOpenRow
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // 右滑和详情的上下滚动同时识别；右滑一旦识别，手指下面的流水、按钮就不再响应点按
        gestureRecognizer === detailSwipe
    }

    // MARK: 读屏

    /// 卡包里每张卡一个读屏元素，放在卡包滚动区里（聚焦时系统会把那张卡滚到屏幕上），激活即打开
    private func updateCardElements(_ layout: StackLayout) {
        let inset = AppLayout.cardInset
        let width = AppLayout.cardWidth(view.bounds.width)
        let elements: [CardAccessibilityElement] = accounts.indices.map { index in
            let account = accounts[index]
            let element = CardAccessibilityElement(accessibilityContainer: stackScroll)
            // 叠在下面的卡只露出上边一条；每叠最后一张整张露出
            let last = index == layout.active - 1 || index == accounts.count - 1
            element.accessibilityFrameInContainerSpace = CGRect(
                x: inset,
                y: headerHeight + layout.restY(index),
                width: width,
                height: last ? layout.cardHeight : layout.peek
            )
            element.accessibilityLabel = "\(account.spokenTitle)，\(balanceTexts[account.id] ?? "余额未知")"
            element.accessibilityHint = account.archived ? "已停用，打开账户详情" : "打开账户详情"
            element.accessibilityTraits = .button
            element.activate = { [weak self] in self?.openCard(index) }
            return element
        }
        var ordered: [Any] = []
        if let header = headerHost.view { ordered.append(header) }
        ordered += elements.prefix(layout.active).map { $0 as Any }
        if layout.archived > 0, let title = archivedTitleHost.view { ordered.append(title) }
        ordered += elements.dropFirst(layout.active).map { $0 as Any }
        stackScroll.accessibilityElements = ordered
    }

    private func announceScreenChange() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }
}

// MARK: - 卡片

/// 卡包里的一张卡。卡面仍由 SwiftUI 的 `WalletCardView` 画；位置、缩放、倾斜和透明度由 UIKit 控制，
/// 动画时卡面不重新计算，只是整张移动。
private final class StackCardView: UIView {
    let host: UIHostingController<CardFace>
    private(set) var account: Account
    private var balanceText: String

    init(account: Account, balanceText: String) {
        self.account = account
        self.balanceText = balanceText
        host = UIHostingController(rootView: CardFace(account: account, balanceText: balanceText))
        super.init(frame: .zero)
        // 不使用安全区：卡片滚到状态栏下面时卡面不重新布局
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.frame = bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(host.view)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(account: Account, balanceText: String) {
        guard account != self.account || balanceText != self.balanceText else { return }
        self.account = account
        self.balanceText = balanceText
        host.rootView = CardFace(account: account, balanceText: balanceText)
    }
}

/// 已停用的卡画成灰色
private struct CardFace: View {
    let account: Account
    let balanceText: String

    var body: some View {
        if account.archived {
            WalletCardView(account: account, balanceText: balanceText).grayscale(1)
        } else {
            WalletCardView(account: account, balanceText: balanceText)
        }
    }
}

private final class CardAccessibilityElement: UIAccessibilityElement {
    var activate: () -> Void = {}

    override func accessibilityActivate() -> Bool {
        activate()
        return true
    }
}

/// 卡包里每张卡静止时的位置：使用中的卡从顶端开始叠放；已停用的卡在下面，中间隔一行「已停用」标题。
private struct StackLayout {
    let active: Int
    let archived: Int
    let cardHeight: CGFloat
    let peek: CGFloat

    static let sectionTitleHeight: CGFloat = 64

    private func pileHeight(_ count: Int) -> CGFloat {
        count > 0 ? cardHeight + CGFloat(count - 1) * peek : 0
    }

    var archivedTitleY: CGFloat { pileHeight(active) }
    private var archivedTop: CGFloat { archivedTitleY + Self.sectionTitleHeight }

    func restY(_ index: Int) -> CGFloat {
        index < active ? CGFloat(index) * peek : archivedTop + CGFloat(index - active) * peek
    }

    var height: CGFloat { archived > 0 ? archivedTop + pileHeight(archived) : pileHeight(active) }
}
