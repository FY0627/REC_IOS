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
                    if r.status != .posted { badge(r.status.displayName) }
                    if r.isRefund { badge("退款") }
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
        if row.title != row.category?.name || row.category == nil { parts.append(row.categoryText) }
        if inAccount {
            if let side = row.transferSideText { parts.append(side) }
        } else if let order = row.orderText {
            parts.append(order)
        } else if let route = row.transferRoute {
            parts.append(route)
        } else {
            parts.append(row.account.text)
        }
        return parts.joined(separator: " · ")
    }

    /// 金额下面的小字：外币按主币种扣了多少、同一条通知的手续费、已退款
    private var trailingDetail: String? {
        if let charge = row.charge { return Fmt.charge(charge) }
        if let fee = row.feeMinor { return "手续费 " + Fmt.money(fee, row.record.currency) }
        if let refunded = row.refundedMinor, refunded > 0 { return "已退 " + Fmt.money(refunded, row.record.currency) }
        return nil
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: Capsule())
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
                LabeledContent("类型", value: r.isRefund ? "支出（退款，从支出里减掉）" : row.entryType.displayName)
                // 只显示；改分类在右上角「编辑」里
                if row.entryType != .transfer {
                    LabeledContent("分类") {
                        Text(row.categoryText).foregroundStyle(row.isUncategorized ? AppTheme.debt : Color.secondary)
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
                    LabeledContent("账户", value: row.account.text)
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
            if let related = detail.related {
                Section(r.isRefund ? "原交易" : "关联的交易") { link(related) }
            }
            if !detail.orderMembers.isEmpty {
                Section {
                    LabeledContent("整单", value: Fmt.money(row.record.amountMinor + detail.orderMembers.map(\.record.amountMinor).reduce(0, +), r.currency))
                    ForEach(detail.orderMembers) { member in link(member) }
                    Button { splitting = true } label: { ActionLabel(title: "拆开") }
                } header: {
                    Text("同一单")
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
                    LabeledContent("方向", value: r.direction.displayName)
                    LabeledContent("交易性质", value: r.kind.displayName)
                    LabeledContent("状态", value: r.status.displayName)
                    LabeledContent("来源", value: Set(detail.evidence.map(\.source)).map(\.displayName).sorted().joined(separator: " + "))
                    LabeledContent("交易时间（通知内）", value: r.transactionTime?.displayText ?? "通知未写明")
                    LabeledContent("接收时间（系统）", value: r.receivedAt.map { Fmt.dateTime($0) } ?? "系统未提供")
                    LabeledContent("处理时间", value: Fmt.dateTime(r.processedAt))
                    if let ref = r.bankReference { LabeledContent("交易标识", value: ref) }
                    if let balance = r.balanceAfterMinor { LabeledContent("通知中的余额", value: Fmt.money(balance, r.currency)) }
                    if let fee = r.includedFeeMinor { LabeledContent("通知金额含手续费", value: Fmt.money(fee, r.currency)) }
                    ForEach(detail.evidence, id: \.ingestID) { e in
                        if e.source != .manual {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(e.source.displayName) · \(Fmt.dateTime(e.processedAt))").font(.caption).foregroundStyle(.secondary)
                                Text(e.rawText ?? "原文已按保留期限清理").font(.footnote).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            Section {
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

    /// 卡里没有这个币种：按主币种扣了多少（估算的写明用哪天的汇率）
    private func chargeRow(_ charge: RecordCharge, record: LedgerRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(record.direction == .inflow ? "存入\(charge.currency.chineseName)" : "从\(charge.currency.chineseName)扣款") {
                Text(charge.amountMinor.map { Fmt.money($0, charge.currency) } ?? "还没有汇率").monospacedDigit()
            }
            Text(chargeNote(charge)).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func chargeNote(_ charge: RecordCharge) -> String {
        if charge.isActual { return "你填写的实际金额" }
        guard let day = charge.rateDay else { return "导入汇率后按交易当天的汇率估算，可以在编辑里改成实际金额" }
        return "按 \(Fmt.rateDay(day)) 的汇率估算，可以在编辑里改成实际金额"
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
            saveError = "备注保存失败：\(error.localizedDescription)"
        }
    }

    private func setTransferParty(_ party: TransferParty?) async {
        do {
            try await store.setTransferParty(recordID: recordID, party: party)
            await reload()
            saveError = nil
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
        }
    }

    private func delete() async {
        do {
            try await store.deleteRecord(id: recordID)
            deleted = true
            dismiss()
        } catch {
            saveError = "删除失败：\(error.localizedDescription)"
        }
    }
}

/// 详情里的操作按钮：只有文字，靠左；整行都能点
struct ActionLabel: View {
    let title: String

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
                } footer: {
                    Text("拆出去的单独显示，分类保留。没选的还是一单，只剩一笔时就不再是一单了。")
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
            errorText = "拆开失败：\(error.localizedDescription)"
        }
    }
}

/// 一单用了几张卡：选同一单的其他几笔，合成一单。离得近、别的卡付的标上「可能是同一单」，只是提示，不自动合并
struct OrderMergeView: View {
    let row: RecordRow
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [RecordRow] = []
    @State private var chosen: Set<String> = []
    @State private var loaded = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section("这一笔") { RecordRowView(row: row) }
                Section("同一单的其他几笔") {
                    if loaded, candidates.isEmpty {
                        Text("前后一天里没有可以合并的记录").foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { candidate in
                        OrderPickRow(
                            row: candidate, chosen: chosen.contains(candidate.id),
                            hint: LedgerBackend.likelySameOrder(row.record, candidate.record) ? "可能是同一单" : nil
                        ) { toggle(candidate.id) }
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("合成一单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("合并", systemImage: "checkmark") { Task { await merge() } }
                        .disabled(chosen.isEmpty)
                }
            }
            .task {
                candidates = await store.orderCandidates(recordID: row.id)
                loaded = true
            }
        }
    }

    private func toggle(_ id: String) {
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
    }

    private func merge() async {
        do {
            try await store.mergeOrder(recordIDs: [row.id] + candidates.map(\.id).filter(chosen.contains))
            dismiss()
        } catch {
            errorText = "合并失败：\(error.localizedDescription)"
        }
    }
}
