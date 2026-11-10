import SwiftUI
import UIKit
import BKModel

/// 待处理：上面是「待分类」——已经入账、还没分类的支出和收入。点一笔打开面板：写备注、选分类，点「确定」才保存，
/// 选错了可以换。最可能的几个分类排在面板上面，这个商户选过的预先选好（`CategorySuggestions`）；
/// 没确认对方的转账在面板里选「转给自己」（不算收支）或直接选分类（算转给别人）。
/// 列表里每笔只是一行，不在每一行里放分类格子（旧流水升级后可能有几百笔待分类）。
/// 下面是「通知待处理」：只能「确认系统给出的候选」或「忽略」，不能借此手动编辑金额、时间。
/// 通知没写是支出还是收入的（「无法确定资金方向」），由用户选「记为支出」或「记为收入」再记入。
/// 认不准的写法可以用这条通知「做成识别模板」，之后同样写法的通知按模板识别。
/// 从卡片详情进入时只列出与这张卡有关的项（候选里有这张卡，或通知尾号与它相同）。
struct PendingView: View {
    var account: Account?
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var items: [PendingItem] = []
    @State private var waiting: [RecordRow] = []
    @State private var loaded = false
    @State private var errorText: String?
    @State private var templateSource: PendingItem?
    @State private var categorizing: CategorizeTarget?

    var body: some View {
        NavigationStack {
            List {
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.footnote)
                }
                if !shownWaiting.isEmpty {
                    Section {
                        ForEach(shownWaiting) { row in
                            Button { Task { await open(row) } } label: { UncategorizedRow(row: row) }
                        }
                    } header: {
                        Text("待分类")
                    }
                }
                Section {
                    if shown.isEmpty && loaded {
                        Text(account == nil ? "没有待处理的通知" : "这张卡没有待处理的账单").foregroundStyle(.secondary)
                    }
                    ForEach(shown) { item in
                        PendingItemCard(item: item, accounts: store.accounts.filter { $0.isCard || $0.cardType == .wallet }) { accountID, direction in
                            await run { try await store.confirmPending(id: item.id, accountID: accountID, direction: direction) }
                        } ignore: {
                            await run { try await store.ignorePending(id: item.id) }
                        } makeTemplate: {
                            templateSource = item
                        }
                    }
                } header: {
                    Text(account.map { L("\($0.localizedTitle) 的通知") } ?? L("通知待处理"))
                }
            }
            .navigationTitle(account == nil ? "待处理" : "待处理账单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成", systemImage: "checkmark") { dismiss() } } }
            .task { await reload() }
            .refreshable { await reload() }
            .sheet(item: $templateSource, onDismiss: { Task { await reload() } }) { item in
                TemplateEditorView(item: item)
            }
            .sheet(item: $categorizing, onDismiss: { Task { await reload() } }) { target in
                CategorizeSheet(target: target)
            }
        }
    }

    /// 先取好候选再打开面板，面板里的内容不会在打开之后才跳出来
    private func open(_ row: RecordRow) async {
        let suggestions = await store.categorySuggestions(recordID: row.id)
        categorizing = CategorizeTarget(row: row, suggestions: suggestions)
    }

    private var shownWaiting: [RecordRow] {
        guard let account else { return waiting }
        return waiting.filter { $0.record.accountID == account.id }
    }

    private var shown: [PendingItem] {
        guard let account else { return items }
        return items.filter { Self.belongs($0, to: account) }
    }

    static func belongs(_ item: PendingItem, to account: Account) -> Bool {
        if item.candidateAccountIDs.contains(account.id) { return true }
        guard account.isCard, item.candidateAccountIDs.isEmpty, let tail = item.draft?.cardTail else { return false }
        return account.matches(tail: tail)
    }

    private func reload() async {
        items = await store.pendingItems()
        waiting = await store.uncategorized()
        loaded = true
    }

    private func run(_ action: () async throws -> Void) async {
        do {
            try await action()
            errorText = nil
        } catch {
            errorText = L("操作失败：\(error.localizedDescription)")
        }
        await reload()
    }
}

/// 要打开面板的这一笔和它的候选。候选放在 sheet 的 item 里传：只在 sheet 闭包里读的 `@State` 打开时可能还是旧值
struct CategorizeTarget: Identifiable, Hashable {
    let row: RecordRow
    let suggestions: CategorySuggestions

    var id: String { row.id }
}

/// 待分类列表里的一行：标题、时间和账户、金额
private struct UncategorizedRow: View {
    let row: RecordRow

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.headline).foregroundStyle(Color.primary).lineLimit(1)
                Text("\(Fmt.dateTime(row.record.effectiveAt)) · \(row.account.localizedText)").font(.subheadline).foregroundStyle(Color.secondary).lineLimit(1)
            }
            Spacer()
            Text(row.amountText(inAccount: false))
                .font(.headline).monospacedDigit()
                .foregroundStyle(row.amountColor(inAccount: false))
        }
        .contentShape(Rectangle())
    }
}

/// 选分类的面板（待处理页、通知点进来）：带「取消」的弹出面板，内容是 `CategorizeForm`
struct CategorizeSheet: View {
    let target: CategorizeTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CategorizeForm(target: target)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                }
        }
    }
}

/// 列表里点一笔待分类的流水推进来的选分类页：先取好候选再显示，「确定」后回到列表
struct CategorizePage: View {
    let row: RecordRow
    @Environment(LedgerStore.self) private var store
    @State private var target: CategorizeTarget?

    var body: some View {
        Group {
            if let target {
                CategorizeForm(target: target)
            } else {
                Color(.systemGroupedBackground).ignoresSafeArea()
            }
        }
        .navigationTitle("选分类")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard target == nil else { return }
            target = CategorizeTarget(row: row, suggestions: await store.categorySuggestions(recordID: row.id))
        }
    }
}

/// 列表里点一笔流水打开的页面：待分类的直接选分类，其余的是流水详情
struct RecordPage: View {
    let row: RecordRow

    var body: some View {
        if row.needsCategory {
            CategorizePage(row: row)
        } else {
            RecordDetailView(recordID: row.id)
        }
    }
}

/// 给一笔待分类选分类：先写备注（选填），点分类选上（可以换），点「确定」才保存。
/// 「建议」是最可能的几个分类，这个商户选过的已经选好，看一眼点「确定」就行。
/// 没确认对方的转账多一个「转给自己的账户」：算转帐，不算收支（选了分类就是转给别人）。
/// 从通知点进来也是这个面板；自动归类的那笔，现在的分类已经选好。
/// 保存后 `dismiss`：弹出面板里是关掉，推进来的页面是返回
struct CategorizeForm: View {
    let row: RecordRow
    let suggested: [LedgerCategory]

    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var categoryID: String?
    @State private var busy = false
    @State private var errorText: String?

    init(target: CategorizeTarget) {
        row = target.row
        suggested = target.suggestions.categories
        _categoryID = State(initialValue: target.suggestions.preferredID ?? target.row.record.categoryID)
    }

    var body: some View {
        let r = row.record
        Form {
            Section {
                UncategorizedRow(row: row)
                if let counterparty = r.counterparty, counterparty != row.title {
                    LabeledContent("交易对方", value: counterparty)
                }
            }
            Section("备注") {
                TextField("选填，比如买了什么", text: $note, axis: .vertical)
                    .lineLimit(1...4)
            }
            if r.needsTransferConfirmation {
                Section {
                    Button {
                        Task { await save { try await store.setTransferParty(recordID: row.id, party: .own) } }
                    } label: {
                        Label(r.direction == .outflow ? "转给自己的账户（不算支出）" : "来自自己的账户（不算收入）", systemImage: "arrow.left.arrow.right.circle")
                    }
                } footer: {
                    Text("转给别人的话，直接在下面选分类。")
                }
            }
            if !suggested.isEmpty {
                Section("建议") {
                    SuggestedCategories(categories: suggested, selected: categoryID) { categoryID = $0 }
                }
            }
            Section("分类") {
                CategoryGrid(type: CategoryType(row.entryType), selected: categoryID, expandsSelected: true) { categoryID = $0 }
            }
            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }
        }
        .disabled(busy)
        .navigationTitle("选分类")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("确定", systemImage: "checkmark") {
                    guard let categoryID else { return }
                    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await save { try await store.setCategory(recordID: row.id, categoryID: categoryID, note: trimmed.isEmpty ? nil : trimmed) } }
                }
                .disabled(categoryID == nil || busy)
            }
        }
        .onAppear { note = row.record.note }
    }

    private func save(_ action: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await action()
            dismiss()
        } catch {
            errorText = L("保存失败：\(error.localizedDescription)")
        }
    }
}

private struct PendingItemCard: View {
    let item: PendingItem
    let accounts: [Account]
    /// 记入这个账户；通知没写方向的（「无法确定资金方向」）带上用户选的方向
    let confirm: (String, FlowDirection?) async -> Void
    let ignore: () async -> Void
    let makeTemplate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.reason.displayName.loc).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(item.source.displayName.loc) · \(Fmt.dateTime(item.receivedAt ?? item.createdAt))").font(.caption).foregroundStyle(.secondary)
            }
            if let draft = item.draft {
                Text(draftSummary(draft)).font(.footnote)
                Text(draft.evidenceSnippet).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            } else if let raw = item.rawText {
                Text(raw).font(.caption).foregroundStyle(.secondary).lineLimit(5)
            }
            if let raw = item.rawText {
                // 截图识别出的文字很长、只显示几行：整段拷出来核对，或者发给开发者做样本
                Button {
                    UIPasteboard.general.string = raw
                } label: {
                    Label("拷贝原文", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
            if item.reason == .possibleDuplicate {
                Text("可能与已有流水重复").font(.caption2).foregroundStyle(.secondary)
            }
            if item.reason == .ambiguousAmount {
                Text("这条通知里认出了几个金额，每个是一条。记入正确的那一条，其余的会自动忽略。").font(.caption2).foregroundStyle(.secondary)
            }
            if item.reason.allowsConfirmation, item.draft != nil, candidates.isEmpty, !accounts.isEmpty {
                // 通知里没认出尾号，或尾号对不上任何卡：选一张卡记入
                Menu {
                    ForEach(accounts) { account in
                        Button(account.localizedTitle) { Task { await confirm(account.id, nil) } }
                    }
                } label: {
                    Label("选择账户记入", systemImage: "creditcard")
                }
            }
            if item.reason == .uncertainKind, item.draft?.direction == nil, item.draft != nil, !directionTargets.isEmpty {
                // 通知没写是支出还是收入：选了方向才能记入。候选只有一个账户时直接记，否则再选账户
                ForEach([FlowDirection.outflow, .inflow], id: \.self) { direction in
                    let title: LocalizedStringKey = direction == .outflow ? "记为支出" : "记为收入"
                    let symbol = direction == .outflow ? "arrow.up.circle" : "arrow.down.circle"
                    if directionTargets.count == 1 {
                        Button {
                            Task { await confirm(directionTargets[0].id, direction) }
                        } label: {
                            Label(direction == .outflow ? "记为支出，记入 \(directionTargets[0].localizedTitle)" : "记为收入，记入 \(directionTargets[0].localizedTitle)", systemImage: symbol)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Menu {
                            ForEach(directionTargets) { account in
                                Button(account.localizedTitle) { Task { await confirm(account.id, direction) } }
                            }
                        } label: {
                            Label(title, systemImage: symbol)
                        }
                    }
                }
            }
            if item.reason.allowsConfirmation, item.draft != nil {
                ForEach(candidates) { account in
                    Button {
                        Task { await confirm(account.id, nil) }
                    } label: {
                        Label(item.reason == .possibleDuplicate ? "不是重复，记入 \(account.localizedTitle)" : "记入 \(account.localizedTitle)", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if item.rawText != nil, item.reason != .possibleDuplicate {
                // 用这条通知做识别模板：以后同样写法的通知按模板识别
                Button(action: makeTemplate) {
                    Label("做成识别模板", systemImage: "text.viewfinder")
                }
                .buttonStyle(.borderless)
            }
            Button(role: .destructive) {
                Task { await ignore() }
            } label: {
                Label(item.reason == .possibleDuplicate ? "是重复，忽略" : "忽略", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private var candidates: [Account] {
        if item.candidateAccountIDs.isEmpty, let tail = item.draft?.cardTail {
            return accounts.filter { $0.isCard && $0.matches(tail: tail) }
        }
        return accounts.filter { item.candidateAccountIDs.contains($0.id) }
    }

    /// 选方向后可以记入的账户：系统给了候选就只有候选，没有就是全部账户
    private var directionTargets: [Account] {
        candidates.isEmpty ? accounts : candidates
    }

    private func draftSummary(_ d: EventDraft) -> String {
        var parts: [String] = []
        let currency = d.amount.preferredCurrency?.rawValue ?? d.amount.currencyCandidates.map(\.rawValue).joined(separator: "/")
        parts.append("\(d.direction?.displayName.loc ?? L("方向未知")) \(currency.isEmpty ? "" : currency + " ")\(d.amount.digits)")
        parts.append(d.kind.displayName.loc)
        if let s = d.settlement { parts.append(L("实际扣款 \(s.preferredCurrency?.rawValue ?? "") \(s.digits)")) }
        if let tail = d.cardTail { parts.append(L("尾号 \(tail)")) }
        if let c = d.counterparty { parts.append(c) }
        if let t = d.transactionTime { parts.append(Fmt.wallClock(t)) }
        return parts.joined(separator: " · ")
    }
}
