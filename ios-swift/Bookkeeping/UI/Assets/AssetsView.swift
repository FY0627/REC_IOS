import SwiftUI
import BKModel
import BKBackend

/// 资产页：卡包 → 点按卡片展开详情 → 返回。最下方是灰色的「已停用」卡包，也可以点开查看详情。
///
/// 卡包、详情、顶部按钮和它们之间的转场在 `WalletController`（UIKit + Core Animation，ADR 0012）。
/// 这里是 SwiftUI 的外壳：标签栏显隐和各个弹出页面。打开 / 关闭时 `WalletController` 通知这里，
/// 标签栏和卡片用同样参数的弹簧同时开始。
struct AssetsView: View {
    let openAddAccount: () -> Void
    /// 每次再点一次标签栏的「资产」加 1
    let reselectCount: Int

    @Environment(LedgerStore.self) private var store
    @Environment(ExchangeRateStore.self) private var rates
    @Environment(DetailMotionState.self) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ExchangeRateStore.primaryKey) private var primaryCode = CurrencyCode.cny.rawValue

    @State private var detail = WalletDetailModel()
    @State private var bridge = WalletBridge()
    @State private var sheet: AssetsSheet?
    @State private var swipe = RecordSwipeState()

    private var selectedID: String? { motion.selectedAccountID }
    private var isOpen: Bool { selectedID != nil }

    enum AssetsSheet: Identifiable, Hashable {
        case info, face, pending, manage, customPeriod
        case record(RecordRow)
        /// 点了一笔待分类的：直接选分类
        case categorize(CategorizeTarget)
        var id: Self { self }
    }

    var body: some View {
        WalletPage(
            accounts: store.accounts + store.archivedAccounts,
            activeCount: store.accounts.count,
            // 卡包里都换算成「我的」主要币种（多币种的卡是合计）；打开详情后那张卡显示正在看的币种（`WalletController`）
            balanceTexts: store.balances.mapValues { $0.stackText(rates: rates.rates, primary: CurrencyCode(primaryCode)) },
            revision: store.revision,
            store: store,
            rates: rates,
            detail: detail,
            bridge: bridge,
            actions: actions
        )
        // 铺满屏幕：标签栏显隐不改变页面尺寸；内容和顶部按钮从状态栏下面开始，由 WalletController 按窗口的安全区处理
        .ignoresSafeArea()
        // 详情展开时用系统的方式隐藏标签栏（随打开 / 关闭的动画滑出 / 滑入）。
        // 放在资产页里而不是根视图上：打开详情时只有资产页重新计算，其他标签页不受影响
        .toolbarVisibility(isOpen ? .hidden : .visible, for: .tabBar)
        .onChange(of: reselectCount) { bridge.scrollToTop() }
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet)
        }
        .recordSwipeHost($swipe)
    }

    private var actions: WalletActions {
        WalletActions(
            selectionChanged: { [motion, reduceMotion] id in
                withAnimation(DetailMotionState.transition(reduceMotion: reduceMotion)) {
                    motion.selectedAccountID = id
                }
            },
            addAccount: openAddAccount,
            manageAccounts: { sheet = .manage },
            openInfo: { sheet = .info },
            openFace: { sheet = .face },
            openPending: { sheet = .pending },
            openRecord: openRecord,
            editRecord: { swipe.editing = $0 },
            deleteRecord: { swipe.confirmedDelete = $0 },
            chooseCustomPeriod: { sheet = .customPeriod }
        )
    }

    /// 待分类的先取好候选再打开选分类面板，其余的打开流水详情
    private func openRecord(_ row: RecordRow) {
        guard row.needsCategory else {
            sheet = .record(row)
            return
        }
        Task {
            let suggestions = await store.categorySuggestions(recordID: row.id)
            sheet = .categorize(CategorizeTarget(row: row, suggestions: suggestions))
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: AssetsSheet) -> some View {
        switch sheet {
        case .manage:
            AccountManagerView()
        case .record(let row):
            RecordDetailSheet(recordID: row.id)
        case .categorize(let target):
            CategorizeSheet(target: target)
        case .pending:
            PendingView(account: selectedID.flatMap { store.account(id: $0) })
        case .info:
            if let selectedID { CardInfoView(accountID: selectedID) }
        case .face:
            if let selectedID { CardFaceEditor(accountID: selectedID) }
        case .customPeriod:
            CustomPeriodSheet(initial: detail.period.customDates) { [bridge] period in bridge.setPeriod(period) }
        }
    }
}

// MARK: - 标题区

/// 卡包上方的标题区：净资产卡、「银行卡」一行（没有使用中的卡时是添加卡片的占位）。
/// 由 `WalletController` 放在卡包的滚动区里，打开详情时向上淡出。
/// 最上面给「资产」留出一行：标题单独放（`WalletController`），往下拉时留在原位，这里的内容被拉开。
struct WalletHeader: View {
    /// 「资产」上面的空隙
    static let titleTop: CGFloat = 2

    let count: Int
    let store: LedgerStore
    let rates: ExchangeRateStore
    let addAccount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OverviewCard()

            if count > 0 {
                // 只有银行卡时叫「银行卡」；加了现金、电子钱包后叫「账户」
                let allCards = store.accounts.allSatisfy(\.isCard)
                WalletSectionTitle(title: allCards ? "银行卡" : "账户", count: count, unit: allCards ? "张" : "个")
            } else {
                EmptyWalletCard(action: addAccount)
                    .padding(.top, 24)
                    .padding(.bottom, 10)
            }
        }
        .padding(.top, Self.titleTop + GlassControls.size)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(store)
        .environment(rates)
    }
}

/// 卡包上方的分组标题：「银行卡 共 N 张」「账户 共 N 个」「已停用 共 N 张」
struct WalletSectionTitle: View {
    let title: String
    let count: Int
    var unit = "张"

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            Text("共 \(count) \(unit)").font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 24)
        .padding(.bottom, 10)
    }
}

/// 已停用卡包上方的标题，贴着下面的卡
struct ArchivedPileTitle: View {
    let count: Int

    var body: some View {
        WalletSectionTitle(title: "已停用", count: count)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

// MARK: - 总览与空状态

/// 净资产卡：只显示净资产、总资产、总负债；点按卡片查看各币种明细。
///
/// 有汇率时（由快捷指令导入）所有币种换算成主要币种合计；
/// 否则只显示主要币种的金额，其他币种在明细里。
/// 每张卡每个币种取推算余额（从初始余额起算，没填初始余额的不计入）；正数计入总资产，负数（欠款）计入总负债。
private struct OverviewCard: View {
    @Environment(LedgerStore.self) private var store
    @Environment(ExchangeRateStore.self) private var rates
    @AppStorage(ExchangeRateStore.primaryKey) private var primaryCode = CurrencyCode.cny.rawValue
    @State private var showDetail = false

    var body: some View {
        let summary = NetWorth(store: store, rates: rates.rates, primary: CurrencyCode(primaryCode))
        let main = summary.main
        // 和首页、统计页的分组标题同一行，下面的白框才和它们一样高：位置取首页实际排出来的（`FirstBoxLayout`）。
        // 字号和系统的分组标题一样（真机截图量的：17pt，和正文一样大）
        let first = FirstBoxLayout.shared.home
        Text("合计（\(main.currency.chineseName)）")
            .font(.headline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(
                maxWidth: .infinity,
                minHeight: first.map { max(0, $0.title - WalletHeader.titleTop - GlassControls.size) },
                alignment: .bottomLeading
            )
            .padding(.bottom, first.map { $0.box - $0.title } ?? 0)
        VStack(alignment: .leading, spacing: 0) {
            Text("净资产").font(.subheadline).foregroundStyle(.secondary)
            Text(Fmt.money(main.net, main.currency))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 2)
            HStack(spacing: 0) {
                figure("总资产", Fmt.money(main.assets, main.currency))
                figure("总负债", Fmt.money(main.liabilities, main.currency))
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture { showDetail = true }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("查看各币种明细")
        .sheet(isPresented: $showDetail) { NetWorthDetailView() }
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 净资产明细：合计（有汇率时为换算后的金额）、各币种的原币金额、汇率来源。
private struct NetWorthDetailView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(ExchangeRateStore.self) private var rates
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ExchangeRateStore.primaryKey) private var primaryCode = CurrencyCode.cny.rawValue

    var body: some View {
        let summary = NetWorth(store: store, rates: rates.rates, primary: CurrencyCode(primaryCode))
        NavigationStack {
            List {
                Section(summary.converted == nil ? summary.main.currency.chineseName : "合计（\(summary.main.currency.chineseName)）") {
                    totalsRows(summary.main)
                }
                if !summary.totals.isEmpty {
                    Section("各币种") {
                        ForEach(summary.totals, id: \.currency) { t in
                            let skipped = summary.converted?.skipped.contains(t.currency) == true
                            VStack(alignment: .leading, spacing: 6) {
                                LabeledContent(t.currency.chineseName) {
                                    Text(skipped ? "无汇率" : amount(t.net, t.currency)).monospacedDigit()
                                }
                                .font(.headline)
                                if !skipped {
                                    LabeledContent("资产", value: amount(t.assets, t.currency))
                                    LabeledContent("负债", value: amount(t.liabilities, t.currency))
                                }
                            }
                            .monospacedDigit()
                        }
                    }
                }
                if let current = rates.rates {
                    Section("汇率") {
                        LabeledContent("更新时间", value: Fmt.dateTime(current.updatedAt))
                        Link(ExchangeRateFeed.attribution, destination: ExchangeRateFeed.attributionURL)
                    }
                }
            }
            .navigationTitle("净资产")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成", systemImage: "checkmark") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func totalsRows(_ t: NetWorth.Totals) -> some View {
        LabeledContent("净资产", value: amount(t.net, t.currency))
        LabeledContent("总资产", value: amount(t.assets, t.currency))
        LabeledContent("总负债", value: amount(t.liabilities, t.currency))
    }

    private func amount(_ minor: Int64, _ currency: CurrencyCode) -> String {
        Fmt.money(minor, currency)
    }
}

/// 净资产的计算：按币种汇总各卡的推算余额，有汇率时换算成主要币种合计。
private struct NetWorth {
    struct Totals {
        var currency: CurrencyCode
        var assets: Int64 = 0
        var liabilities: Int64 = 0
        var cards = 0
        var net: Int64 { assets - liabilities }
    }

    struct Converted {
        var total: Totals
        var skipped: Set<CurrencyCode>
    }

    /// 每个币种一项：主要币种在前，其余按有余额的卡多少、金额大小排序
    let totals: [Totals]
    /// 有汇率时的换算结果
    let converted: Converted?
    /// 卡片上显示的合计：换算后的金额，或者主要币种的金额
    let main: Totals

    @MainActor
    init(store: LedgerStore, rates: ExchangeRates?, primary: CurrencyCode) {
        let totals = Self.totals(store.accounts, store.balances, primary: primary)
        let converted = rates.flatMap { Self.convert(totals, to: primary, with: $0) }
        self.totals = totals
        self.converted = converted
        self.main = converted?.total ?? totals.first(where: { $0.currency == primary }) ?? Totals(currency: primary)
    }

    static func totals(_ accounts: [Account], _ balances: [String: AccountBalances], primary: CurrencyCode) -> [Totals] {
        var byCurrency: [CurrencyCode: Totals] = [:]
        for account in accounts {
            for item in balances[account.id]?.items ?? [] {
                guard let amount = item.ledgerDerivedMinor else { continue }
                var entry = byCurrency[item.currency] ?? Totals(currency: item.currency)
                if amount >= 0 { entry.assets += amount } else { entry.liabilities += -amount }
                entry.cards += 1
                byCurrency[item.currency] = entry
            }
        }
        return byCurrency.values.sorted { a, b in
            if (a.currency == primary) != (b.currency == primary) { return a.currency == primary }
            if a.cards != b.cards { return a.cards > b.cards }
            let sizeA = a.assets + a.liabilities, sizeB = b.assets + b.liabilities
            if sizeA != sizeB { return sizeA > sizeB }
            return a.currency < b.currency
        }
    }

    /// 资产和负债分别换算后相加；缺汇率的币种不计入。
    static func convert(_ totals: [Totals], to primary: CurrencyCode, with rates: ExchangeRates) -> Converted? {
        guard rates.rate(primary) != nil else { return nil }
        var sum = Totals(currency: primary)
        var skipped: Set<CurrencyCode> = []
        for t in totals {
            guard let assets = rates.convert(t.assets, from: t.currency, to: primary),
                  let liabilities = rates.convert(t.liabilities, from: t.currency, to: primary) else {
                skipped.insert(t.currency)
                continue
            }
            sum.assets += assets
            sum.liabilities += liabilities
            sum.cards += t.cards
        }
        return Converted(total: sum, skipped: skipped)
    }
}

private struct EmptyWalletCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "creditcard.and.123").font(.largeTitle).foregroundStyle(.secondary)
                Text("添加账户").font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
