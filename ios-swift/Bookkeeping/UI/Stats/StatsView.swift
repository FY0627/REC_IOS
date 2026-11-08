import SwiftUI
import UIKit
import BKModel

/// 统计看哪些数据：全部账户（换算成主要币种）、一个账户、一个币种。存成文字，记住上次选的
enum StatsScope: Hashable, RawRepresentable {
    case all
    case account(String)
    case currency(CurrencyCode)

    init?(rawValue: String) {
        if rawValue == "all" {
            self = .all
        } else if rawValue.hasPrefix("account:") {
            self = .account(String(rawValue.dropFirst("account:".count)))
        } else if rawValue.hasPrefix("currency:") {
            self = .currency(CurrencyCode(String(rawValue.dropFirst("currency:".count))))
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .all: "all"
        case .account(let id): "account:\(id)"
        case .currency(let code): "currency:\(code.rawValue)"
        }
    }

    var accountID: String? {
        if case .account(let id) = self { id } else { nil }
    }
}

/// 统计：右上角两个玻璃胶囊，左边选看哪些数据（全部账户、一个账户、一个币种），右边选时间段
/// （和卡片详情一样：全部、本周、本月、上月、今年、自定义），默认本周（本月的首页上有）。
/// 三种看法一个样子：上面是这段时间的支出、收入、结余，下面是支出和收入按分类排（哪一类花得最多，点进去看小类和每一笔）。
/// 全部账户：所有币种换算成「我的」里选的主要币种（和首页的本月合计一样算）；
/// 一个账户、一个币种：不换算，账户用了几个币种就分开几组。
/// 转帐（自己的账户之间、还信用卡、存取现金）不算在收支里；退款从它所在的分类里减掉。
/// 顶部一行和首页、资产页一样：左边大标题「统计」。
struct StatsView: View {
    private struct LoadKey: Equatable {
        let period: RecordPeriod
        let revision: Int
    }

    private struct AccountKey: Equatable {
        let period: RecordPeriod
        let accountID: String?
        let revision: Int
    }

    /// 只算一个账户的统计，和它是哪个账户（换账户时不显示上一个账户的）
    private struct AccountStats {
        let accountID: String
        let stats: MonthStats
    }

    @Environment(LedgerStore.self) private var store
    @AppStorage("stats.scope") private var scope = StatsScope.all
    @State private var period: RecordPeriod = .thisWeek
    @State private var choosingCustom = false
    /// 所有账户：全部账户、一个币种用它
    @State private var stats: MonthStats?
    @State private var accountStats: AccountStats?
    @State private var scrolledUnderBar = false

    var body: some View {
        NavigationStack {
            List {
                switch current {
                case .all:
                    if let stats { allSections(stats) }
                case .currency(let code):
                    if let stats {
                        if let totals = stats.currencies.first(where: { $0.currency == code }) {
                            currencySections(totals, accountID: nil)
                        } else {
                            empty
                        }
                    }
                case .account(let id):
                    if let loaded = accountStats, loaded.accountID == id {
                        if loaded.stats.currencies.isEmpty { empty }
                        ForEach(loaded.stats.currencies, id: \.currency) { totals in
                            currencySections(totals, accountID: id)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .trackingScrollUnderTopBar($scrolledUnderBar)
            .navigationTitle("统计")
            // 系统导航栏的大标题在按钮下面一行；藏起来，自己放一行（和资产页的标题行一样高、一样的位置）
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.hidden, for: .navigationBar)
            .safeAreaBar(edge: .top) {
                TitleBar(title: "统计", menus: [
                    .init(title: scopeTitle) { scopeMenu() },
                    .init(title: period.title) { periodMenu() },
                ])
                .frame(height: GlassControls.size)
                .padding(.horizontal, AppLayout.cardInset)
                .padding(.top, 2)
                .padding(.bottom, AppLayout.topBarBottom)
                .background { TopBarBackdrop(visible: scrolledUnderBar) }
            }
            .sheet(isPresented: $choosingCustom) {
                CustomPeriodSheet(initial: period.customDates) { period = $0 }
            }
            .task(id: LoadKey(period: period, revision: store.revision)) {
                let range = period.range()
                stats = await store.stats(from: range.from, to: range.to, converted: true)
            }
            .task(id: AccountKey(period: period, accountID: current.accountID, revision: store.revision)) {
                guard let id = current.accountID else { return }
                let range = period.range()
                if let loaded = await store.stats(from: range.from, to: range.to, accountID: id) {
                    accountStats = AccountStats(accountID: id, stats: loaded)
                }
            }
        }
    }

    /// 选的账户删掉了就看全部账户
    private var current: StatsScope {
        if let id = scope.accountID, store.account(id: id)?.deleted != false { return .all }
        return scope
    }

    private var scopeTitle: String {
        switch current {
        case .all: L("全部账户")
        case .account(let id): store.account(id: id).map(menuName) ?? L("全部账户")
        case .currency(let code): code.localizedName
        }
    }

    /// 看哪些数据的菜单：全部账户，另起两组「账户」「币种」
    private func scopeMenu() -> [UIMenuElement] {
        let selected = current
        let all = UIAction(title: L("全部账户"), state: selected == .all ? .on : .off) { _ in scope = .all }
        let accounts = (store.accounts + store.archivedAccounts).map { account in
            UIAction(title: menuName(account), state: selected == .account(account.id) ? .on : .off) { _ in scope = .account(account.id) }
        }
        let currencies = menuCurrencies.map { code in
            UIAction(title: code.localizedName, state: selected == .currency(code) ? .on : .off) { _ in scope = .currency(code) }
        }
        var items: [UIMenuElement] = [all]
        if !accounts.isEmpty { items.append(UIMenu(title: L("账户"), options: .displayInline, children: accounts)) }
        items.append(UIMenu(title: L("币种"), options: .displayInline, children: currencies))
        return items
    }

    /// 菜单和胶囊上写账户名称（「招商银行信用卡」），不写尾号；同名的几个账户才加尾号分开
    private func menuName(_ account: Account) -> String {
        let name = account.localizedName
        let sameName = (store.accounts + store.archivedAccounts).contains { $0.id != account.id && $0.localizedName == name }
        return sameName && account.isCard ? "\(name) ·\(account.last4)" : name
    }

    /// 主要币种、这段时间用过的币种、账户里有的币种
    private var menuCurrencies: [CurrencyCode] {
        var seen: Set<CurrencyCode> = []
        let codes = [ExchangeRateStore.primaryCurrency] + (stats?.currencies.map(\.currency) ?? []) + store.accounts.flatMap(\.currencies)
        return codes.filter { seen.insert($0).inserted }
    }

    /// 时间段胶囊的菜单：常用时间段，另起一组「自定义…」（选中时写自定义的日期）
    private func periodMenu() -> [UIMenuElement] {
        let presets: [UIMenuElement] = RecordPeriod.presets.map { option in
            UIAction(title: option.title, state: option == period ? .on : .off) { _ in period = option }
        }
        let custom = UIAction(title: period.isCustom ? period.title : L("自定义…"), state: period.isCustom ? .on : .off) { _ in
            choosingCustom = true
        }
        return presets + [UIMenu(options: .displayInline, children: [custom])]
    }

    /// 这段时间的范围（按收到通知的时间）
    private var range: (from: Date?, to: Date?) { period.range() }

    private var empty: some View {
        Section {
            ContentUnavailableView("这段时间还没有记录", systemImage: "chart.bar", description: Text(period.title))
        }
    }

    /// 全部账户：换算成主要币种的合计，再按分类排（点进去的每一笔不限币种）
    @ViewBuilder
    private func allSections(_ stats: MonthStats) -> some View {
        if stats.currencies.isEmpty {
            empty
        } else {
            let total = stats.converted
            let currency = total?.currency ?? ExchangeRateStore.primaryCurrency
            Section {
                ConvertedTotalsView(total: total)
            } header: {
                Text("\(period.title) · 合计（\(currency.localizedName)）")
            }
            if let total {
                categorySections(Breakdown(
                    currency: currency, expense: total.expenseCategories, income: total.incomeCategories,
                    expenseTotal: total.expenseMinor, incomeTotal: total.incomeMinor, onlyCurrency: false
                ))
            }
        }
    }

    /// 一个币种（只看一个账户时是这个账户的这个币种）：支出、收入、结余和全部账户一个样子，再按分类排
    @ViewBuilder
    private func currencySections(_ t: MonthStats.CurrencyTotals, accountID: String?) -> some View {
        Section {
            ConvertedTotalsView(total: MonthStats.ConvertedTotals(
                currency: t.currency, expenseMinor: t.netExpenseMinor, incomeMinor: t.incomeMinor, unconverted: []
            ))
            if t.refundMinor > 0 {
                LabeledContent("其中退款", value: Fmt.money(t.refundMinor, t.currency))
            }
            if t.transferMinor > 0 {
                LabeledContent("转帐（不算收支）", value: Fmt.money(t.transferMinor, t.currency))
            }
        } header: {
            Text("\(period.title) · \(t.currency.localizedName)")
        }
        categorySections(Breakdown(
            currency: t.currency, expense: t.expenseCategories, income: t.incomeCategories,
            expenseTotal: t.netExpenseMinor, incomeTotal: t.incomeMinor, accountID: accountID
        ))
    }

    /// 下面按分类排的部分。`accountID`、`onlyCurrency`：点进去看每一笔时只看这个账户、这个币种
    private struct Breakdown {
        let currency: CurrencyCode
        let expense: [MonthStats.CategoryTotal]
        let income: [MonthStats.CategoryTotal]
        let expenseTotal: Int64
        let incomeTotal: Int64
        var accountID: String?
        var onlyCurrency = true
    }

    @ViewBuilder
    private func categorySections(_ b: Breakdown) -> some View {
        if !b.expense.isEmpty {
            Section("支出分类") {
                categoryRows(b.expense, type: .expense, total: b.expenseTotal, b)
            }
        }
        if !b.income.isEmpty {
            Section("收入分类") {
                categoryRows(b.income, type: .income, total: b.incomeTotal, b)
            }
        }
    }

    private func categoryRows(_ totals: [MonthStats.CategoryTotal], type: EntryType, total: Int64, _ b: Breakdown) -> some View {
        let maxAmount = max(1, totals.map(\.amountMinor).max() ?? 1)
        return ForEach(totals) { item in
            NavigationLink {
                CategoryStatsView(
                    item: item, type: type, currency: b.currency, onlyCurrency: b.onlyCurrency, accountID: b.accountID,
                    from: range.from, to: range.to
                )
            } label: {
                CategoryTotalRow(item: item, currency: b.currency, maxAmount: maxAmount, total: total)
            }
        }
    }
}

/// 一个分类的合计：图标、名称、占比、金额和一条比例条
private struct CategoryTotalRow: View {
    let item: MonthStats.CategoryTotal
    let currency: CurrencyCode
    let maxAmount: Int64
    let total: Int64

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(symbol: item.symbol)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.name.loc).lineLimit(1)
                    if total > 0, item.amountMinor > 0 {
                        Text(percent).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Text(Fmt.money(item.amountMinor, currency)).monospacedDigit()
                }
                GeometryReader { proxy in
                    Capsule().fill(TintShapeStyle().opacity(0.35))
                        .frame(width: max(6, proxy.size.width * CGFloat(max(0, Double(item.amountMinor)) / Double(maxAmount))), height: 6)
                }
                .frame(height: 6)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var percent: String {
        let value = Double(item.amountMinor) / Double(total) * 100
        return value < 1 ? "<1%" : "\(Int(value.rounded()))%"
    }
}

/// 一个分类这段时间的明细：大类下面的小类，和这段时间记在这个分类上的每一笔。
/// 金额是 `currency`；每一笔只看这个币种（`onlyCurrency`，全部账户的换算金额不限）、这个账户（`accountID`）
private struct CategoryStatsView: View {
    let item: MonthStats.CategoryTotal
    let type: EntryType
    let currency: CurrencyCode
    let onlyCurrency: Bool
    let accountID: String?
    let from: Date?
    let to: Date?

    @Environment(LedgerStore.self) private var store
    @State private var rows: [RecordRow] = []
    @State private var swipe = RecordSwipeState()

    var body: some View {
        List {
            Section {
                LabeledContent("合计", value: Fmt.money(item.amountMinor, currency))
                LabeledContent("笔数", value: L("\(item.count) 笔"))
            }
            if item.children.count > 1 || (item.children.first.map { $0.categoryID != item.categoryID } ?? false) {
                Section("小类") {
                    let maxAmount = max(1, item.children.map(\.amountMinor).max() ?? 1)
                    ForEach(item.children) { child in
                        CategoryTotalRow(
                            item: child.categoryID == item.categoryID ? MonthStats.CategoryTotal(
                                categoryID: child.categoryID, name: L("不细分"), symbol: child.symbol, amountMinor: child.amountMinor, count: child.count
                            ) : child,
                            currency: currency, maxAmount: maxAmount, total: item.amountMinor
                        )
                    }
                }
            }
            Section("每一笔") {
                ForEach(rows) { row in
                    NavigationLink {
                        RecordPage(row: row)
                    } label: {
                        RecordRowView(row: row)
                    }
                    .recordSwipe(row, state: $swipe)
                }
            }
        }
        .navigationTitle(item.name.loc)
        .navigationBarTitleDisplayMode(.inline)
        .recordSwipeHost($swipe)
        .task(id: store.revision) {
            let filter = RecordFilter(
                accountID: accountID, from: from, to: to, entryType: type, categoryID: item.categoryID ?? RecordFilter.uncategorized,
                feed: true, mergeFees: true
            )
            rows = await store.records(filter, after: nil, limit: 200).filter { !onlyCurrency || $0.record.currency == currency }
        }
    }
}
