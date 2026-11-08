import SwiftUI
import BKModel

/// 首页：本月概览（支出、收入、结余，换算成「我的」里选的主要币种）+ 全部账户的流水（按日期分组，分页加载）。
/// 分组列表，不做下拉刷新（数据变了会自动更新）。
/// 一笔钱只占一行：转帐两边合成一行，合成的一单只占一行，手续费写在那一笔下面；失败、冻结的不在首页（在卡片详情里）。
///
/// 顶部一行（`HomeTopBar`）和资产页一样：左边大标题「首页」，右边「记一笔」和搜索两个圆形玻璃按钮（不用系统导航栏，系统的大标题和按钮不在同一行）。
/// 点搜索按钮展开搜索框，标题的位置变成「全部 / 支出 / 收入 / 转帐」的下拉按钮（不用打字也按它筛选，收起搜索回到全部）；
/// 可以按备注、交易对方、分类、金额、卡号尾号、银行查流水，只写整数的金额找差不多的（记不清几毛几分、大概多少）。
/// 查过的条件记住结果，来回切换类型不重新查；数据变了才重新查。
/// 按天分组，每一笔只写时间（日期在分组标题上），完整时间在流水详情里。
/// 一行流水左滑露出「编辑」「删除」（`RecordSwipe.swift`，删除要先确认），流水详情里也能改、能删。
/// 点一笔打开流水详情；待分类的（标题旁标着「待分类」）直接推进选分类页（`RecordPage`）。
struct HomeView: View {
    let openPending: () -> Void
    @Environment(LedgerStore.self) private var store
    @State private var query = ""
    @State private var scope: SearchScope = .all
    @State private var results: [RecordRow] = []
    @State private var resultsHaveMore = false
    /// 已经查过的条件：结果对应这些条件时才显示「没有结果」
    @State private var searched: SearchKey?
    /// 查过的条件和结果（含翻到的页）；数据变了（`revision` 不同）的丢掉
    @State private var cache: [SearchKey: SearchPage] = [:]
    @State private var loadingMore = false
    @State private var adding = false
    /// 列表滚到了顶部那一行下面：显示磨砂背景
    @State private var scrolledUnderBar = false
    @State private var listInset: CGFloat = 0
    @State private var swipe = RecordSwipeState()

    enum SearchScope: Hashable, CaseIterable {
        case all, expense, income, transfer

        var title: String { entryType?.displayName.loc ?? L("全部") }

        /// 搜索没有结果、又没打字时（只选了类型）
        var emptyTitle: LocalizedStringKey {
            switch self {
            case .all: "还没有流水"
            case .expense: "没有支出"
            case .income: "没有收入"
            case .transfer: "没有转帐"
            }
        }

        var entryType: EntryType? {
            switch self {
            case .all: nil
            case .expense: .expense
            case .income: .income
            case .transfer: .transfer
            }
        }
    }

    struct SearchKey: Hashable {
        var text: String
        var scope: SearchScope
        /// 数据变了（删除、修改、新流水）重新查
        var revision: Int
    }

    struct SearchPage {
        var rows: [RecordRow]
        var hasMore: Bool
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 打了字，或者选了支出 / 收入 / 转帐（只有搜索展开时能选，收起时回到全部）
    private var filtering: Bool { !trimmedQuery.isEmpty || scope != .all }

    var body: some View {
        NavigationStack {
            List {
                if filtering {
                    searchResults
                } else {
                    feed
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.immediately)
            .trackingScrollUnderTopBar($scrolledUnderBar)
            .trackingListInset($listInset)
            .navigationTitle("首页")
            // 系统导航栏藏起来了，但默认的大标题模式仍在：往下拉时列表先停在「大标题展开」的位置再弹回，
            // 点状态栏回到顶部时列表停在大标题展开的位置（多出一截空白）。改成小标题就没有这一截
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.hidden, for: .navigationBar)
            // 顶部一行固定在上面，列表从它下面滚过时垫一层磨砂背景（搜索展开时也一直在）。
            // 和资产页的标题行一样高、一样的位置：44pt 高，离状态栏 2pt
            .safeAreaBar(edge: .top) {
                HomeTopBar(query: $query, scope: $scope, add: { adding = true })
                    .frame(height: HomeTopBarView.height)
                    .padding(.horizontal, AppLayout.cardInset)
                    .padding(.top, 2)
                    .padding(.bottom, AppLayout.topBarBottom)
                    .background { TopBarBackdrop(visible: scrolledUnderBar) }
            }
            .navigationDestination(for: RecordRow.self) { row in RecordPage(row: row) }
            .sheet(isPresented: $adding) { AddRecordView() }
            .recordSwipeHost($swipe)
            .task(id: SearchKey(text: trimmedQuery, scope: scope, revision: store.revision)) {
                await search(SearchKey(text: trimmedQuery, scope: scope, revision: store.revision))
            }
        }
    }

    // MARK: 流水

    @ViewBuilder
    private var feed: some View {
        Section {
            ConvertedTotalsView(total: store.monthStats?.converted, expenseTitle: "本月支出", incomeTitle: "本月收入")
                .background(RowInsetsProbe { insets in
                    if FirstBoxLayout.shared.homeRowInsets != insets { FirstBoxLayout.shared.homeRowInsets = insets }
                })
        } header: {
            Text(Self.monthTitle)
                .background(FirstBoxProbe(listInset: listInset) { position in
                    if FirstBoxLayout.shared.home != position { FirstBoxLayout.shared.home = position }
                })
        }
        if store.pendingCount + store.uncategorizedCount > 0 {
            Section { pendingBanner }
        }
        if store.homeRows.isEmpty {
            Section("流水") { emptyState }
        } else {
            ForEach(Self.group(store.homeRows), id: \.day) { group in
                Section(group.title) {
                    ForEach(group.rows) { row in
                        recordLink(row)
                            .onAppear {
                                if row.id == store.homeRows.last?.id { Task { await store.loadMoreHome() } }
                            }
                    }
                }
            }
            if store.homeHasMore {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private func recordLink(_ row: RecordRow) -> some View {
        NavigationLink(value: row) { RecordRowView(row: row, timeOnly: true) }
            .recordSwipe(row, state: $swipe)
    }

    // MARK: 搜索

    @ViewBuilder
    private var searchResults: some View {
        if results.isEmpty {
            if searched?.text == trimmedQuery, searched?.scope == scope {
                if trimmedQuery.isEmpty {
                    ContentUnavailableView(scope.emptyTitle, systemImage: "magnifyingglass")
                } else {
                    ContentUnavailableView.search(text: trimmedQuery)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } else {
            ForEach(Self.group(results), id: \.day) { group in
                Section(group.title) {
                    ForEach(group.rows) { row in
                        recordLink(row)
                            .onAppear {
                                if row.id == results.last?.id { Task { await loadMoreResults() } }
                            }
                    }
                }
            }
            if resultsHaveMore {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private func search(_ key: SearchKey) async {
        // 没在搜索，或者搜索框空着、选的是全部：就是首页本来的流水
        guard !key.text.isEmpty || key.scope != .all else {
            results = []
            resultsHaveMore = false
            searched = nil
            return
        }
        cache = cache.filter { $0.key.revision == key.revision }
        if let page = cache[key] {
            show(page, for: key)
            return
        }
        let sameText = (searched?.text ?? "") == key.text
        if sameText, let type = key.scope.entryType {
            // 只换了类型：先从手上已有的里挑出这一类显示，查回来再换成完整的
            let shown = searched == nil ? store.homeRows : results
            results = shown.filter { $0.entryType == type }
        }
        // 边打字边查：停下来一会儿再查；只换了类型或者数据变了马上查
        if !sameText {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        let rows = await store.records(Self.searchFilter(key), after: nil, limit: LedgerStore.pageSize)
        guard !Task.isCancelled else { return }
        let page = SearchPage(rows: rows, hasMore: rows.count == LedgerStore.pageSize)
        if cache.count >= 24 { cache.removeAll() }
        cache[key] = page
        show(page, for: key)
    }

    private func show(_ page: SearchPage, for key: SearchKey) {
        results = page.rows
        resultsHaveMore = page.hasMore
        searched = key
    }

    private func loadMoreResults() async {
        guard resultsHaveMore, !loadingMore, let key = searched, let last = results.last else { return }
        loadingMore = true
        defer { loadingMore = false }
        let page = await store.records(Self.searchFilter(key), after: last, limit: LedgerStore.pageSize)
        guard searched == key else { return }
        let known = Set(results.map(\.id))
        results += page.filter { !known.contains($0.id) }
        resultsHaveMore = page.count == LedgerStore.pageSize
        cache[key] = SearchPage(rows: results, hasMore: resultsHaveMore)
    }

    /// 搜索也和首页一样：一笔钱一行
    private static func searchFilter(_ key: SearchKey) -> RecordFilter {
        RecordFilter(text: key.text, entryType: key.scope.entryType, feed: true, mergeFees: true)
    }

    // MARK: 概览

    private static var monthTitle: String {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return Fmt.monthTitle(year: c.year ?? 0, month: c.month ?? 0)
    }

    private var pendingTitle: String {
        var parts: [String] = []
        if store.uncategorizedCount > 0 { parts.append(L("\(store.uncategorizedCount) 笔待分类")) }
        if store.pendingCount > 0 { parts.append(L("\(store.pendingCount) 条通知待处理")) }
        return parts.joined(separator: L("，"))
    }

    private var pendingBanner: some View {
        Button(action: openPending) {
            HStack(spacing: 12) {
                Image(systemName: "tray.full").font(.title3).foregroundStyle(AppTheme.debt)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pendingTitle).font(.headline).foregroundStyle(.primary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView("还没有流水", systemImage: "list.bullet.rectangle")
    }

    struct DayGroup {
        let day: Date
        let title: String
        let rows: [RecordRow]
    }

    static func group(_ rows: [RecordRow]) -> [DayGroup] {
        let calendar = Calendar.current
        let now = Date()
        var groups: [DayGroup] = []
        var currentDay: Date?
        var bucket: [RecordRow] = []
        for row in rows {
            let day = calendar.startOfDay(for: row.record.effectiveAt)
            if day != currentDay, let currentDay {
                groups.append(DayGroup(day: currentDay, title: Fmt.day(currentDay, now: now), rows: bucket))
                bucket = []
            }
            currentDay = day
            bucket.append(row)
        }
        if let currentDay { groups.append(DayGroup(day: currentDay, title: Fmt.day(currentDay, now: now), rows: bucket)) }
        return groups
    }
}
