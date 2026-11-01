import SwiftUI
import BKModel
import BKBackend

/// 修改一笔流水：支出 / 收入 / 转帐、金额、币种、分类、账户、交易对方、时间、备注。
/// 支出可以标成退款（从支出里减掉）；转帐选这张卡是转出还是转入、另一边是哪个账户（转到 / 来自），
/// 以及另一边的币种和金额（到账多少，见 `TransferSideFields`）。交易性质和方向按选的类型换，尽量保留原来的。
/// 币种可以选任何一种；卡里没有这笔流水的币种时（银行按主币种结汇扣款），
/// 还可以填实际扣了多少主币种，不填就按交易当天的汇率估算（空着时提示大概多少）。
/// 余额从「校准余额」那一刻算起：比它早的流水换账户、改金额，卡上的余额不变，这时在账户下面写明。
struct RecordEditor: View {
    let detail: RecordDetail
    let onSaved: () -> Void

    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var type: EntryType
    @State private var refund: Bool
    @State private var transferDirection: FlowDirection
    @State private var amountText: String
    @State private var currency: CurrencyCode?
    @State private var categoryID: String?
    @State private var accountID: String
    @State private var counterparty: String
    @State private var time: Date
    @State private var timeChanged = false
    @State private var note: String
    @State private var settlementText: String
    @State private var estimate: RecordCharge?
    @State private var peer: PeerChoice
    /// 另一边的币种和金额；空着表示和这一笔一样多
    @State private var peerCurrency: CurrencyCode?
    @State private var peerAmountText: String
    @State private var saving = false
    @State private var errorText: String?

    /// 转帐的另一边
    enum PeerChoice: Hashable {
        /// 自己的、没添加到 App 的账户
        case untracked
        case account(String)
    }

    private let initialPeer: PeerChoice

    init(detail: RecordDetail, onSaved: @escaping () -> Void) {
        self.detail = detail
        self.onSaved = onSaved
        let r = detail.row.record
        _type = State(initialValue: r.entryType)
        _refund = State(initialValue: r.isRefund)
        _transferDirection = State(initialValue: r.direction)
        _amountText = State(initialValue: MoneyInput.editingText(r.amountMinor, currency: r.currency))
        _currency = State(initialValue: r.currency)
        _categoryID = State(initialValue: r.categoryID)
        _accountID = State(initialValue: r.accountID)
        _counterparty = State(initialValue: r.counterparty ?? "")
        _time = State(initialValue: Self.initialTime(r))
        _note = State(initialValue: r.note)
        _settlementText = State(initialValue: r.settlement.map { MoneyInput.editingText($0.minorUnits, currency: $0.currency) } ?? "")
        let peer = detail.transferPeer.map { PeerChoice.account($0.record.accountID) } ?? PeerChoice.untracked
        _peer = State(initialValue: peer)
        initialPeer = peer
        // 手动补记的另一边金额一样时空着（跟着这一笔改）；银行记的、或者本来就不一样的把金额写出来
        let other = detail.transferPeer?.record
        _peerCurrency = State(initialValue: other?.currency)
        let showsAmount = other.map { $0.source != .manual || $0.money != r.money } ?? false
        _peerAmountText = State(initialValue: showsAmount ? other.map { MoneyInput.editingText($0.amountMinor, currency: $0.currency) } ?? "" : "")
    }

    /// 通知里写了完整的日期和时间就用它（按手机所在时区），否则用收到通知的时间
    private static func initialTime(_ r: LedgerRecord) -> Date {
        if let t = r.transactionTime, let year = t.year, let month = t.month, let day = t.day, let hour = t.hour, let minute = t.minute,
           let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) {
            return date
        }
        return r.effectiveAt
    }

    private var account: Account? { store.account(id: accountID) }

    /// 可以记到的账户：使用中的账户，加上这笔流水原来的账户（可能已停用）
    private var accounts: [Account] {
        var list = store.accounts
        if let current = store.account(id: detail.row.record.accountID), !list.contains(where: { $0.id == current.id }) {
            list.append(current)
        }
        return list
    }

    /// 转帐另一边可选的账户：别的账户，或者这个账户的另一个币种（换汇）；原来的另一边已停用也列出来
    private var peerOptions: [Account] {
        var list = accounts.filter { $0.id != accountID || $0.currencies.count > 1 }
        if case .account(let id) = initialPeer, !list.contains(where: { $0.id == id }), let old = store.account(id: id) {
            list.append(old)
        }
        return list
    }

    /// 转帐另一边选的账户
    private var peerAccount: Account? {
        guard type == .transfer, case .account(let id) = peer else { return nil }
        return store.account(id: id)
    }

    /// 输入框里现在的金额；格式不对时是 nil
    private var enteredAmount: Int64? {
        guard let currency, case .valid(let minor) = MoneyInput.parse(amountText, negative: false, currency: currency), minor > 0 else { return nil }
        return minor
    }

    /// 比账户的校准余额早、不影响余额的账户（换了账户时才提示）
    private var balanceNote: String? {
        let r = detail.row.record
        guard accountID != r.accountID else { return nil }
        let unaffected = [store.account(id: r.accountID), account].compactMap { $0 }.filter { a in
            guard let opening = a.openingBalance(a.currencies.contains(r.currency) ? r.currency : a.currency) else { return false }
            return (timeChanged ? time : r.effectiveAt) <= opening.at
        }
        guard !unaffected.isEmpty else { return nil }
        return "这笔比「\(unaffected.map(\.displayTitle).joined(separator: "」「"))」的校准余额早，换账户不会改变它的余额（余额从校准那一刻算起）。"
    }

    /// 钱进这个账户（收入、退款、转入）是入账，否则是扣款
    private var settlementTitle: String {
        let inflow = type == .income || (type == .expense && refund) || (type == .transfer && transferDirection == .inflow)
        return inflow ? "实际入账" : "实际扣款"
    }

    /// 卡里没有这个币种：要按主币种扣款
    private var settlementCurrency: CurrencyCode? {
        guard let account, let currency, !account.currencies.contains(currency) else { return nil }
        return account.currency
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("类型", selection: $type) {
                        ForEach(EntryType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if type == .expense {
                        Toggle("退款（从支出里减掉）", isOn: $refund)
                    }
                    HStack {
                        Text("金额")
                        TextField(MoneyInput.placeholder(currency), text: $amountText)
                            .keyboardType(currency?.minorUnitExponent == 0 ? .numberPad : .decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.title3.weight(.semibold).monospacedDigit())
                    }
                    CurrencyLink(title: "币种", currency: $currency, suggested: store.heldCurrencies)
                }
                // 先选币种再选账户：账户没有这个币种时，下面多一行实际扣款（入账）
                Section {
                    Picker("账户", selection: $accountID) {
                        ForEach(accounts) { Text($0.displayTitle).tag($0.id) }
                    }
                    if type == .transfer {
                        Picker("这张卡", selection: $transferDirection) {
                            Text("转出").tag(FlowDirection.outflow)
                            Text("转入").tag(FlowDirection.inflow)
                        }
                        Picker(transferDirection == .outflow ? "转到" : "来自", selection: $peer) {
                            ForEach(peerOptions) { option in
                                Text(option.id == accountID ? "\(option.displayTitle)（换汇）" : option.displayTitle)
                                    .tag(PeerChoice.account(option.id))
                            }
                            Text("没添加到 App 的账户").tag(PeerChoice.untracked)
                        }
                        if let peerAccount {
                            TransferSideFields(
                                account: peerAccount, sourceAccountID: accountID, sourceAmount: enteredAmount, sourceCurrency: currency,
                                time: timeChanged ? time : detail.row.record.effectiveAt, receiving: transferDirection == .outflow,
                                currency: $peerCurrency, amountText: $peerAmountText
                            )
                        }
                    }
                    if let settlementCurrency {
                        HStack {
                            Text("\(settlementTitle)（\(settlementCurrency.chineseName)）")
                            TextField(estimate?.amountMinor.map { "约 " + Fmt.money($0, settlementCurrency) } ?? "不填按汇率估算", text: $settlementText)
                                .keyboardType(settlementCurrency.minorUnitExponent == 0 ? .numberPad : .decimalPad)
                                .multilineTextAlignment(.trailing)
                                .font(.body.monospacedDigit())
                        }
                    }
                } footer: {
                    if let balanceNote {
                        Text(balanceNote)
                    } else if peerAccount != nil {
                        Text(TransferSideFields.note)
                    }
                }
                if type != .transfer {
                    Section("分类") {
                        CategoryGrid(type: CategoryType(type), selected: categoryID) { categoryID = $0 }
                    }
                }
                Section("备注") {
                    TextField("写点什么，比如买了什么", text: $note, axis: .vertical)
                        .lineLimit(1...5)
                }
                Section {
                    TextField("交易对方（选填）", text: $counterparty)
                    DatePicker("时间", selection: $time)
                        .onChange(of: time) { timeChanged = true }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("编辑流水")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") { Task { await save() } }
                        .disabled(saving || currency == nil)
                }
            }
            .onChange(of: type) {
                // 支出换成收入（或反过来）：原来的分类对不上了
                if let category = store.categoryTree.category(categoryID), category.type != CategoryType(type) { categoryID = nil }
            }
            .onChange(of: accountID) {
                // 换了账户：只有一个币种的账户不能转给自己；币种不变（新账户没有这个币种就按它的主币种扣款），原来填的实际扣款是旧账户的币种，清掉
                if peer == .account(accountID), !peerOptions.contains(where: { $0.id == accountID }) { peer = .untracked }
                if settlementCurrency != detail.row.record.settlement?.currency { settlementText = "" }
            }
            .onChange(of: peer) {
                // 换了另一边：币种回到默认，金额清空
                peerAmountText = ""
                peerCurrency = peerAccount.map {
                    TransferSideFields.defaultCurrency(in: $0, sourceAccountID: accountID, sourceCurrency: currency)
                }
            }
            .task(id: estimateKey) { await updateEstimate() }
        }
    }

    /// 金额、币种、账户、日期变了就重新估算
    private var estimateKey: String {
        let day = Calendar.current.startOfDay(for: timeChanged ? time : detail.row.record.effectiveAt).timeIntervalSince1970
        return "\(amountText)|\(currency?.rawValue ?? "")|\(settlementCurrency?.rawValue ?? "")|\(day)"
    }

    /// 空着的实际扣款提示按汇率大概多少：用交易那天的汇率（没改时间时和详情里显示的一样）
    private func updateEstimate() async {
        guard let currency, let settlementCurrency,
              case .valid(let amount) = MoneyInput.parse(amountText, negative: false, currency: currency), amount > 0 else {
            estimate = nil
            return
        }
        let r = detail.row.record
        let value: RecordCharge?
        if !timeChanged, currency == r.currency, amount == r.amountMinor, let charge = detail.row.charge, !charge.isActual,
           charge.currency == settlementCurrency {
            value = charge
        } else {
            value = await store.estimateCharge(amountMinor: amount, currency: currency, to: settlementCurrency, at: timeChanged ? time : r.effectiveAt)
        }
        guard !Task.isCancelled else { return }
        estimate = value
    }

    private func save() async {
        guard let currency else { return }
        guard case .valid(let amount) = MoneyInput.parse(amountText, negative: false, currency: currency), amount > 0 else {
            errorText = MoneyInput.invalidAmountMessage(currency)
            return
        }
        var settlement: Int64?
        if let settlementCurrency {
            switch MoneyInput.parse(settlementText, negative: false, currency: settlementCurrency) {
            case .empty: settlement = nil
            case .valid(let minor) where minor > 0: settlement = minor
            default:
                errorText = "实际金额：" + MoneyInput.invalidAmountMessage(settlementCurrency)
                return
            }
        }
        var peerAmount: Int64?
        if let peerAccount, let peerCurrency {
            let side = TransferSideFields.resolve(
                text: peerAmountText, currency: peerCurrency, account: peerAccount, sourceAccountID: accountID,
                sourceAmount: amount, sourceCurrency: currency, receiving: transferDirection == .outflow
            )
            if let error = side.error {
                errorText = error
                return
            }
            peerAmount = side.minor
        }
        let fields = RecordEdit.fields(
            for: type, refund: refund, transferDirection: transferDirection, original: detail.row.record,
            accountIsCredit: account?.cardType == .credit
        )
        let trimmed = counterparty.trimmingCharacters(in: .whitespacesAndNewlines)
        // 转帐的另一边：改了才传（没改时保持原来的配对，手动补记的那边跟着改金额）
        var peerChange = TransferPeerChange.keep
        if type == .transfer, peer != initialPeer || detail.row.entryType != .transfer {
            switch peer {
            case .untracked: peerChange = .untracked
            case .account(let id): peerChange = .account(id)
            }
        }
        let edit = RecordEdit(
            accountID: accountID, amountMinor: amount, currency: currency, direction: fields.direction, kind: fields.kind,
            counterparty: trimmed.isEmpty ? nil : trimmed, time: timeChanged ? time : nil, note: note,
            settlementMinor: settlement, categoryID: type == .transfer ? nil : categoryID, keepsCategory: false, transferParty: fields.party,
            peer: peerChange, peerAmountMinor: peerAmount, peerCurrency: peerAmount == nil ? nil : peerCurrency
        )
        saving = true
        defer { saving = false }
        do {
            try await store.updateRecord(id: detail.row.record.id, edit)
            onSaved()
            dismiss()
        } catch {
            errorText = "保存失败：\(error.localizedDescription)"
        }
    }
}
