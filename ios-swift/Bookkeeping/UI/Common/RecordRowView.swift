import SwiftUI
import BKModel
import BKBackend

/// 流水行：分类图标、标题（备注 → 交易对方 → 分类名）、时间和分类、金额。
/// 首页一笔钱只占一行：转帐两边合成「招行 → 工行」，合成的一单写整单金额和几张卡，手续费、退款写在金额下面。
/// 卡片详情里（`showAccount: false`）每一笔是这张卡自己的那一边，金额按这张卡的进出带正负号。
/// 字号用系统文字样式，跟随「更大字体」设置。在系统列表里直接使用；在自定义滚动页面里用 `boxed: true` 自带卡片背景。
/// 每一部分都只有一行，行高固定（卡片详情的列表事先量好高度）。
struct RecordRowView: View {
    let row: RecordRow
    var showAccount = true
    var boxed = false
    /// 按天分组的列表（首页）：只写时间，日期在分组标题上
    var timeOnly = false

    private var inAccount: Bool { !showAccount }

    var body: some View {
        let r = row.record
        HStack(spacing: 12) {
            CategoryIcon(symbol: row.symbol)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    if r.status != .posted { badge(r.status.displayName.loc) }
                    if r.isRefund { badge("退款") }
                    if r.categoryAuto { badge("自动（归类）") }
                    // 卡片详情里不标：待分类只在首页提醒
                    if row.needsCategory, !inAccount { badge("待分类", tinted: true) }
                }
                Text(subtitle)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            // 金额先占够宽度，左边的标题、时间放不下就省略；金额本身太长时缩小一点，不换行
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.amountText(inAccount: inAccount))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(row.amountColor(inAccount: inAccount))
                    .strikethrough(r.status == .failed)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let detail = trailingDetail {
                    Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .layoutPriority(1)
            .opacity(r.status == .posted ? 1 : 0.55)
        }
        .padding(.vertical, boxed ? 12 : 2)
        .padding(.horizontal, boxed ? 14 : 0)
        .background {
            if boxed {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemGroupedBackground))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// 时间 · 分类 · 账户（转帐写从哪到哪，合成的一单写几张卡各付多少）
    private var subtitle: String {
        let r = row.record
        var parts = [timeOnly ? Fmt.recordClock(r) : Fmt.recordTime(r)]
        // 待分类的标在标题旁边，这里不再写
        if !row.needsCategory, row.title != row.category?.localizedName || row.category == nil { parts.append(row.categoryText) }
        if inAccount {
            if let side = row.transferSideText { parts.append(side) }
        } else if let order = row.orderText {
            parts.append(order)
        } else if let route = row.transferRoute {
            parts.append(route)
        } else {
            parts.append(row.account.localizedText)
        }
        return parts.joined(separator: " · ")
    }

    /// 金额下面的小字：外币按主币种扣了多少、同一条通知的手续费、已退款
    private var trailingDetail: String? {
        if let charge = row.charge { return Fmt.charge(charge) }
        if let fee = row.feeMinor { return L("手续费 \(Fmt.money(fee, row.record.currency))") }
        if let refunded = row.refundedMinor, refunded > 0 { return L("已退 \(Fmt.money(refunded, row.record.currency))") }
        return nil
    }

    /// `tinted`：用主题色，要用户处理的（待分类）
    private func badge(_ text: String, tinted: Bool = false) -> some View {
        Text(text.loc)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tinted ? AnyShapeStyle(TintShapeStyle().opacity(0.15)) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Capsule())
    }
}

/// 流水按收到的那天分组：首页、统计里一个分类的每一笔、卡片详情都这样排。
/// 分组标题写「今天」「昨天」「11月8日 周六」，每一笔只写时间（`RecordRowView(timeOnly: true)`）
struct RecordDay {
    let day: Date
    let title: String
    let rows: [RecordRow]

    /// 流水已经按时间从新到旧排好
    static func group(_ rows: [RecordRow], now: Date = Date()) -> [RecordDay] {
        let calendar = Calendar.current
        var groups: [RecordDay] = []
        var currentDay: Date?
        var bucket: [RecordRow] = []
        for row in rows {
            let day = calendar.startOfDay(for: row.record.effectiveAt)
            if day != currentDay, let currentDay {
                groups.append(RecordDay(day: currentDay, title: Fmt.day(currentDay, now: now), rows: bucket))
                bucket = []
            }
            currentDay = day
            bucket.append(row)
        }
        if let currentDay { groups.append(RecordDay(day: currentDay, title: Fmt.day(currentDay, now: now), rows: bucket)) }
        return groups
    }
}

/// 卡片详情里每天的流水上面的日期，字和首页的分组标题一样；左边和流水行里的图标对齐
struct RecordDayHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 以面板方式打开流水详情（没有导航栈的页面使用）。
struct RecordDetailSheet: View {
    let recordID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RecordDetailView(recordID: recordID)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭", systemImage: "xmark") { dismiss() }
                    }
                }
        }
    }
}

/// 单笔流水详情：类型、分类（点一下就能改）、账户、时间、备注（直接写）；
/// 退款、手续费、同一单的其他几笔；方向、交易性质、状态、来源、原始通知收在「更多信息」里。
/// 右上角「编辑」可以改类型、金额、币种、分类、账户、交易对方、时间、备注和实际扣款；最下面可以删除。
/// 操作按钮文字在左、图标在右（和系统菜单一样）；删除点了先在按钮旁边弹出一个小菜单确认，不弹对话框。
struct RecordDetailView: View {
    let recordID: String
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var detail: RecordDetail?
    @State private var saveError: String?
    @State private var showMore = false
    @State private var editing = false
    @State private var deleted = false
    @State private var merging = false
    @State private var splitting = false
    /// 手动了结冻结：打开 `HoldCloseView`
    @State private var closingHold = false
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        Group {
            if let detail {
                form(detail)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("流水详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("编辑") { editing = true }
                    .disabled(detail == nil)
            }
        }
        .sheet(isPresented: $editing) {
            if let detail {
                RecordEditor(detail: detail) { Task { await reload() } }
            }
        }
        .sheet(isPresented: $merging, onDismiss: { Task { await reload() } }) {
            if let detail { OrderMergeView(row: detail.row) }
        }
        .sheet(isPresented: $splitting, onDismiss: { Task { await reload() } }) {
            if let detail { OrderSplitView(detail: detail) }
        }
        .sheet(isPresented: $closingHold, onDismiss: { Task { await reload() } }) {
            if let detail { HoldCloseView(row: detail.row) }
        }
        .onChange(of: noteFocused) { _, focused in
            if !focused { Task { await saveNote() } }
        }
        .onDisappear { if !deleted { Task { await saveNote() } } }
        .task { await reload() }
    }

    private func form(_ detail: RecordDetail) -> some View {
        let row = detail.row
        let r = row.record
        return Form {
            Section {
                HStack(spacing: 12) {
                    CategoryIcon(symbol: row.symbol)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(.headline).lineLimit(2)
                        Text(row.categoryText).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Text(row.amountText(inAccount: true))
                    .font(.largeTitle.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(row.amountColor(inAccount: true))
                    .strikethrough(r.status == .failed)
                if let charge = row.charge {
                    chargeRow(charge, record: r)
                }
                LabeledContent("类型", value: r.isRefund ? L("支出（退款，从支出里减掉）") : row.entryType.displayName.loc)
                // 只显示；改分类在右上角「编辑」里
                if row.entryType != .transfer {
                    LabeledContent("分类") {
                        Text(r.categoryAuto ? L("\(row.categoryText)（自动归类）") : row.categoryText)
                            .foregroundStyle(row.isUncategorized ? AppTheme.debt : Color.secondary)
                    }
                }
                if (r.kind == .transferIn || r.kind == .transferOut), r.transferGroupID == nil, r.status == .posted {
                    Picker(r.direction == .outflow ? "转给" : "来自", selection: Binding(
                        get: { r.transferParty },
                        set: { party in Task { await setTransferParty(party) } }
                    )) {
                        Text("未确认").tag(TransferParty?.none)
                        Text("自己的账户").tag(TransferParty?.some(.own))
                        Text("别人").tag(TransferParty?.some(.other))
                    }
                }
                if let route = row.transferRoute {
                    LabeledContent("转帐", value: route)
                } else {
                    LabeledContent("账户", value: row.account.localizedText)
                }
                // 到账和转出不一样（手续费、换汇）时写出另一边
                if let other = row.peerMoney, other != r.money {
                    LabeledContent(r.direction == .outflow ? "到账" : "转出", value: Fmt.money(other.minorUnits, other.currency))
                }
                if let fee = row.transferFeeMinor {
                    LabeledContent("手续费", value: Fmt.money(fee, r.currency))
                }
                LabeledContent("时间", value: Fmt.dateTime(r.effectiveAt))
                if let counterparty = r.counterparty {
                    LabeledContent("交易对方", value: counterparty)
                }
                if let fee = detail.fee {
                    LabeledContent("手续费", value: Fmt.money(fee.record.amountMinor, fee.record.currency))
                }
            }

            Section("备注") {
                TextField("写点什么，比如买了什么", text: $note, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($noteFocused)
                    .submitLabel(.done)
            }

            if !detail.refunds.isEmpty {
                Section("退款") {
                    ForEach(detail.refunds) { refund in link(refund) }
                }
            }
            if !detail.closedHolds.isEmpty {
                // 这笔扣款了结的冻结：列表里不单独显示，收在这里
                Section("预授权") {
                    ForEach(detail.closedHolds) { hold in link(hold) }
                }
            }
            if let related = detail.related {
                Section(r.isRefund ? "原交易" : (r.status == .holdReleased ? "完成扣款" : "关联的交易")) {
                    link(related)
                    // 关联错了：两笔都留着，退款的分类不变
                    if r.isRefund {
                        Button { Task { await unlinkRefund() } } label: { ActionLabel(title: "取消关联") }
                    }
                    // 了结错了：改回冻结，重新单独显示
                    if r.status == .holdReleased {
                        Button { Task { await reopenHold() } } label: { ActionLabel(title: "取消了结") }
                    }
                }
            }
            if r.status == .hold, r.direction == .outflow {
                // 没等到写了预授权时间的扣款通知：自己选是哪一笔扣款了结它（金额一样也可能不是同一单，不自动了结）
                Section {
                    Button { closingHold = true } label: { ActionLabel(title: "了结冻结") }
                }
            }
            if !detail.orderMembers.isEmpty {
                Section {
                    LabeledContent("整单", value: Fmt.money(row.record.amountMinor + detail.orderMembers.map(\.record.amountMinor).reduce(0, +), r.currency))
                    ForEach(detail.orderMembers) { member in link(member) }
                    Button { splitting = true } label: { ActionLabel(title: "拆开") }
                } header: {
                    Text("同一单")
                }
            } else if detail.mergedTransfer {
                // 一笔支出和一笔收入手动合成的转帐：拆开回到原来的两笔
                Section {
                    Button { Task { await splitTransfer() } } label: { ActionLabel(title: "拆开") }
                }
            } else if row.entryType != .transfer, r.status == .posted {
                Section {
                    Button { merging = true } label: { ActionLabel(title: "合并") }
                }
            }

            if let saveError {
                Section { Text(saveError).font(.footnote).foregroundStyle(.red) }
            }

            Section {
                DisclosureGroup("更多信息", isExpanded: $showMore) {
                    LabeledContent("方向", value: r.direction.displayName.loc)
                    LabeledContent("交易性质", value: r.kind.displayName.loc)
                    LabeledContent("状态", value: r.status.displayName.loc)
                    LabeledContent("来源", value: Set(detail.evidence.map(\.source)).map(\.displayName.loc).sorted().joined(separator: " + "))
                    LabeledContent("交易时间（通知内）", value: r.transactionTime.map(Fmt.wallClock) ?? L("通知未写明"))
                    LabeledContent("接收时间（系统）", value: r.receivedAt.map { Fmt.dateTime($0) } ?? L("系统未提供"))
                    LabeledContent("处理时间", value: Fmt.dateTime(r.processedAt))
                    if let ref = r.bankReference { LabeledContent("交易标识", value: ref) }
                    if let balance = r.balanceAfterMinor { LabeledContent("通知中的余额", value: Fmt.money(balance, r.currency)) }
                    if let fee = r.includedFeeMinor { LabeledContent("通知金额含手续费", value: Fmt.money(fee, r.currency)) }
                    ForEach(detail.evidence, id: \.ingestID) { e in
                        if e.source != .manual {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(e.source.displayName.loc) · \(Fmt.dateTime(e.processedAt))").font(.caption).foregroundStyle(.secondary)
                                Text(e.rawText ?? L("原文已按保留期限清理")).font(.footnote).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            Section {
                // 通知记上的、原文还在：「不记」删掉这笔并记住这种写法（朝朝宝这类余额的进出），以后同样的通知不记
                if detail.evidence.contains(where: { $0.source != .manual && $0.source != .screenshot && $0.rawText != nil }) {
                    Menu {
                        Button("以后这种通知都不记", systemImage: "nosign", role: .destructive) { Task { await skip() } }
                    } label: {
                        ActionLabel(title: "不记").foregroundStyle(Color.red)
                    }
                }
                // 确认的小菜单就在这个按钮旁边弹出
                Menu {
                    Section("删除后不能恢复") {
                        Button("删除这笔流水", systemImage: "trash", role: .destructive) { Task { await delete() } }
                    }
                } label: {
                    ActionLabel(title: "删除").foregroundStyle(Color.red)
                }
            }
        }
    }

    private func link(_ row: RecordRow) -> some View {
        NavigationLink {
            RecordDetailView(recordID: row.id)
        } label: {
            RecordRowView(row: row)
        }
    }

    /// 换成账户的另一个币种扣（卡里没有这个币种，或者这个币种不够，ADR 0018）：扣了多少（估算的写明用哪天的汇率）
    private func chargeRow(_ charge: RecordCharge, record: LedgerRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            let name = charge.currency.localizedName
            LabeledContent(record.direction == .inflow ? L("存入\(name)") : L("从\(name)扣款")) {
                Text(charge.amountMinor.map { Fmt.money($0, charge.currency) } ?? L("还没有汇率")).monospacedDigit()
            }
            Text(chargeNote(charge)).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func chargeNote(_ charge: RecordCharge) -> String {
        if charge.isActual { return L("你填写的实际金额") }
        guard let day = charge.rateDay else { return L("导入汇率后按交易当天的汇率估算") }
        return L("按 \(Fmt.rateDay(day)) 的汇率估算")
    }

    private func reload() async {
        detail = await store.detail(recordID: recordID)
        if !noteFocused, let detail { note = detail.row.record.note }
    }

    /// 备注写完（离开输入框或离开页面）就保存
    private func saveNote() async {
        guard let detail, note != detail.row.record.note else { return }
        do {
            try await store.updateNote(recordID: recordID, note: note)
            self.detail?.row.record.note = note
            saveError = nil
        } catch {
            saveError = L("备注保存失败：\(error.localizedDescription)")
        }
    }

    private func splitTransfer() async {
        do {
            try await store.splitTransfer(recordID: recordID)
            await reload()
            saveError = nil
        } catch {
            saveError = L("拆开失败：\(error.localizedDescription)")
        }
    }

    private func unlinkRefund() async {
        do {
            try await store.unlinkRefund(recordID)
            await reload()
            saveError = nil
        } catch {
            saveError = L("取消关联失败：\(error.localizedDescription)")
        }
    }

    private func reopenHold() async {
        do {
            try await store.reopenHold(id: recordID)
            await reload()
            saveError = nil
        } catch {
            saveError = L("取消了结失败：\(error.localizedDescription)")
        }
    }

    private func setTransferParty(_ party: TransferParty?) async {
        do {
            try await store.setTransferParty(recordID: recordID, party: party)
            await reload()
            saveError = nil
        } catch {
            saveError = L("保存失败：\(error.localizedDescription)")
        }
    }

    private func delete() async {
        do {
            try await store.deleteRecord(id: recordID)
            deleted = true
            dismiss()
        } catch {
            saveError = L("删除失败：\(error.localizedDescription)")
        }
    }

    private func skip() async {
        do {
            try await store.skipRecord(id: recordID)
            deleted = true
            dismiss()
        } catch {
            saveError = L("删除失败：\(error.localizedDescription)")
        }
    }
}

/// 详情里的操作按钮：只有文字，靠左；整行都能点
struct ActionLabel: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// 选几笔时的一行：左边圆圈，选中打勾
private struct OrderPickRow: View {
    let row: RecordRow
    let chosen: Bool
    var hint: String?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
                VStack(alignment: .leading, spacing: 4) {
                    RecordRowView(row: row)
                    if let hint {
                        Text(hint).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// 了结冻结（手动）：和「合成一单」一样的面板。上面是这笔冻结，下面选完成扣款的那一笔（只能选一笔），
/// 或者「没有扣款（已撤销）」，右上角确定。金额和冻结时写的实扣一样的排在前面并标出来，但不替用户选：金额一样也可能不是同一单
struct HoldCloseView: View {
    let row: RecordRow
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [RecordRow] = []
    @State private var loaded = false
    @State private var choice: Choice?
    @State private var errorText: String?

    enum Choice: Hashable {
        case charge(String)
        /// 没有扣款：预授权撤销了
        case noCharge
    }

    var body: some View {
        NavigationStack {
            List {
                Section("这一笔") { RecordRowView(row: row) }
                Section("完成扣款") {
                    if loaded, candidates.isEmpty {
                        Text("之后 45 天里这个账户没有扣款").foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { candidate in
                        OrderPickRow(
                            row: candidate, chosen: choice == .charge(candidate.id),
                            hint: matchesHold(candidate.record) ? L("和实扣金额一样") : nil
                        ) { choice = .charge(candidate.id) }
                    }
                }
                Section {
                    Button { choice = .noCharge } label: {
                        HStack(spacing: 10) {
                            Image(systemName: choice == .noCharge ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(choice == .noCharge ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
                            Text("没有扣款（已撤销）")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("了结冻结")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("了结", systemImage: "checkmark") { Task { await close() } }
                        .disabled(choice == nil)
                }
            }
            .task {
                candidates = await store.holdCaptureCandidates(holdID: row.id)
                loaded = true
            }
        }
    }

    /// 和冻结时通知里写的实扣（「JPY3000（人民币126.84）」的 126.84）一样，或者和冻结的金额、币种一样
    private func matchesHold(_ charge: LedgerRecord) -> Bool {
        let hold = row.record
        if let currency = hold.chargeCurrency, let minor = hold.settlementMinor, charge.currency == currency, charge.amountMinor == minor { return true }
        return charge.currency == hold.currency && charge.amountMinor == hold.amountMinor
    }

    private func close() async {
        guard let choice else { return }
        do {
            switch choice {
            case .charge(let id): try await store.closeHold(id: row.id, chargeID: id)
            case .noCharge: try await store.closeHold(id: row.id, chargeID: nil)
            }
            dismiss()
        } catch {
            errorText = L("了结失败：\(error.localizedDescription)")
        }
    }
}

/// 拆开合成的一单：选要拆出去的几笔，没选的还是一单，只剩一笔时就不再是一单
struct OrderSplitView: View {
    let detail: RecordDetail
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []
    @State private var errorText: String?

    /// 这一单的每一笔：写它自己的金额和账户，不写整单
    private var parts: [RecordRow] {
        ([detail.row] + detail.orderMembers).map { row in
            var single = row
            single.orderParts = []
            return single
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(parts) { part in
                        OrderPickRow(row: part, chosen: chosen.contains(part.id)) {
                            if chosen.contains(part.id) { chosen.remove(part.id) } else { chosen.insert(part.id) }
                        }
                    }
                } header: {
                    Text("选要拆出去的几笔")
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("拆开")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("拆开", systemImage: "checkmark") { Task { await split() } }
                        .disabled(chosen.isEmpty)
                }
            }
        }
    }

    private func split() async {
        do {
            try await store.splitOrder(recordIDs: Array(chosen))
            dismiss()
        } catch {
            errorText = L("拆开失败：\(error.localizedDescription)")
        }
    }
}

/// 合并：
/// - 一单用了几张卡：选同一单的其他几笔，合成一单。离得近、别的卡付的标上「可能是同一单」，只是提示，不自动合并；
/// - 合成转帐：这一笔支出（收入）和别的账户的一笔收入（支出）合成一笔转帐，例如微信提现到银行卡，只选一笔。
///   支出、收入（不是退款）才能选，在上面的分段控件里换；
/// - 退款：退款关联到原交易（只选一笔），支出关联它的退款（可以选几笔，分几次退的）。两笔都留着，
///   原交易下面写「已退」，退款跟着原交易的分类。退款只有这一种，不显示分段控件
struct OrderMergeView: View {
    let row: RecordRow
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode
    @State private var candidates: [RecordRow] = []
    @State private var chosen: Set<String> = []
    @State private var loaded = false
    @State private var errorText: String?

    enum Mode: Hashable {
        case order
        case transfer
        /// 退款和原交易关联
        case refund
    }

    init(row: RecordRow) {
        self.row = row
        _mode = State(initialValue: row.record.isRefund ? .refund : .order)
    }

    /// 这一笔能怎么合：退款只能关联到原交易；支出（流出）可以合成一单、合成转帐、关联它的退款；收入合成一单、合成转帐
    private var modes: [Mode] {
        let r = row.record
        if r.isRefund { return [.refund] }
        var modes: [Mode] = [.order]
        if r.canMergeIntoTransfer { modes.append(.transfer) }
        if r.entryType == .expense, r.direction == .outflow { modes.append(.refund) }
        return modes
    }

    private var isRefund: Bool { row.record.isRefund }

    var body: some View {
        NavigationStack {
            List {
                if modes.count > 1 {
                    Section {
                        Picker("合并成", selection: $mode) {
                            ForEach(modes, id: \.self) { mode in
                                switch mode {
                                case .order: Text("一单").tag(mode)
                                case .transfer: Text("转帐").tag(mode)
                                case .refund: Text("退款").tag(mode)
                                }
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section("这一笔") { RecordRowView(row: row) }
                Section(candidatesTitle) {
                    if loaded, candidates.isEmpty {
                        Text(emptyText).foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { candidate in
                        OrderPickRow(
                            row: candidate, chosen: chosen.contains(candidate.id),
                            hint: mode == .order && LedgerBackend.likelySameOrder(row.record, candidate.record) ? L("可能是同一单") : nil
                        ) { toggle(candidate.id) }
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("合并", systemImage: "checkmark") { Task { await merge() } }
                        .disabled(chosen.isEmpty)
                }
            }
            .task(id: mode) {
                loaded = false
                chosen = []
                errorText = nil
                switch mode {
                case .order:
                    candidates = await store.orderCandidates(recordID: row.id)
                case .transfer:
                    candidates = await store.transferMergeCandidates(recordID: row.id)
                case .refund:
                    candidates = await store.refundLinkCandidates(recordID: row.id)
                    // 已经关联了原交易的退款：先选上它，换一笔就是改关联
                    if isRefund, let origin = row.record.relatedRecordID, candidates.contains(where: { $0.id == origin }) {
                        chosen = [origin]
                    }
                }
                loaded = true
            }
        }
    }

    private var navigationTitle: LocalizedStringKey {
        switch mode {
        case .order: "合成一单"
        case .transfer: "合成转帐"
        case .refund: "关联退款"
        }
    }

    private var candidatesTitle: LocalizedStringKey {
        switch mode {
        case .order: "同一单的其他几笔"
        case .transfer: "转帐的另一边"
        case .refund: isRefund ? "原交易" : "这笔的退款"
        }
    }

    private var emptyText: LocalizedStringKey {
        switch mode {
        case .order: "前后一天里没有可以合并的记录"
        case .transfer: "前后三天里没有可以合成转帐的记录"
        case .refund: isRefund ? "之前半年里没有金额够退这笔的支出" : "之后半年里没有还没关联的退款"
        }
    }

    /// 合成一单、关联几笔退款可以选几笔；转帐的另一边、退款的原交易只有一笔，选了别的就换成它
    private func toggle(_ id: String) {
        if chosen.contains(id) {
            chosen.remove(id)
        } else if mode == .transfer || (mode == .refund && isRefund) {
            chosen = [id]
        } else {
            chosen.insert(id)
        }
    }

    private func merge() async {
        do {
            switch mode {
            case .order:
                try await store.mergeOrder(recordIDs: [row.id] + candidates.map(\.id).filter(chosen.contains))
            case .transfer:
                guard let other = chosen.first else { return }
                try await store.mergeTransfer(recordID: row.id, with: other)
            case .refund:
                if isRefund {
                    guard let origin = chosen.first else { return }
                    try await store.linkRefunds([row.id], to: origin)
                } else {
                    try await store.linkRefunds(candidates.map(\.id).filter(chosen.contains), to: row.id)
                }
            }
            dismiss()
        } catch {
            errorText = L("合并失败：\(error.localizedDescription)")
        }
    }
}
