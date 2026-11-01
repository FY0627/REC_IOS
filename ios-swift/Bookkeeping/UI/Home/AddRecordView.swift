import SwiftUI
import BKModel
import BKBackend

/// 手动记一笔：现金、电子钱包，或者通知还没接上的消费。
/// 顺序：金额和币种 → 账户（默认上次用的）→ 分类 → 备注（选填）→ 保存。转帐选从哪个账户转到哪个账户，转进信用卡算还款。
/// 转帐还要填到账的币种和金额（有手续费、换汇时和转出不一样，见 `TransferSideFields`），同一个账户的两个币种之间也可以转。
/// 先选币种再选账户：币种可以选任何一种（默认「我的」里的主要币种）。账户没有这个币种时按账户的主币种扣款（入账），
/// 默认按当天的汇率估算，银行实际扣了多少可以直接填。
/// 保存前查一下同一个账户前后 3 小时有没有同样金额的记录（多半是自动记账已经记过了），有就先问一句。
struct AddRecordView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var type: EntryType = .expense
    @State private var amountText = ""
    @State private var currency: CurrencyCode? = ExchangeRateStore.primaryCurrency
    @State private var categoryID: String?
    @State private var note = ""
    @State private var accountID: String?
    @State private var toAccountID: String?
    /// 账户没有这个币种时，实际扣款（入账）多少账户主币种；空着按汇率估算
    @State private var settlementText = ""
    @State private var estimate: RecordCharge?
    /// 转帐到账的币种和金额
    @State private var toCurrency: CurrencyCode?
    @State private var toAmountText = ""
    @State private var counterparty = ""
    @State private var time = Date()
    @State private var saving = false
    @State private var errorText: String?
    @State private var similar: [RecordRow] = []
    @State private var confirmSimilar = false
    @FocusState private var amountFocused: Bool

    private var accounts: [Account] { store.accounts }

    /// 可以转到的账户：别的账户，或者这个账户的另一个币种（换汇）
    private var transferTargets: [Account] {
        accounts.filter { $0.id != accountID || $0.currencies.count > 1 }
    }

    private var transferTarget: Account? { accounts.first { $0.id == toAccountID } }

    /// 账户没有选的币种：按它的主币种记
    private func chargeCurrency(_ id: String?) -> CurrencyCode? {
        guard let currency, let account = accounts.first(where: { $0.id == id }), !account.currencies.contains(currency) else { return nil }
        return account.currency
    }

    private var amount: Int64? {
        guard let currency, case .valid(let minor) = MoneyInput.parse(amountText, negative: false, currency: currency), minor > 0 else { return nil }
        return minor
    }

    var body: some View {
        NavigationStack {
            Form {
                if accounts.isEmpty {
                    Section {
                        Text("先在资产页添加一个账户（银行卡、现金或电子钱包）。").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker("类型", selection: $type) {
                        ForEach(EntryType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField(MoneyInput.placeholder(currency), text: $amountText)
                        .keyboardType(currency?.minorUnitExponent == 0 ? .numberPad : .decimalPad)
                        .font(.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit())
                        .focused($amountFocused)
                    CurrencyLink(title: type == .transfer ? "转出币种" : "币种", currency: $currency, suggested: store.heldCurrencies)
                }
                Section {
                    Picker(type == .transfer ? "从" : "账户", selection: $accountID) {
                        accountOptions(accounts)
                    }
                    if let charge = chargeCurrency(accountID) {
                        settlementRow(type == .income ? "实际入账" : "实际扣款", charge, text: $settlementText, estimate: estimate)
                    }
                    if type == .transfer {
                        Picker("转到", selection: $toAccountID) {
                            Text("请选择").tag(String?.none)
                            ForEach(transferTargets) { account in
                                Text(account.id == accountID ? "\(account.displayTitle)（换汇）" : account.displayTitle)
                                    .tag(String?.some(account.id))
                            }
                        }
                        if let transferTarget {
                            TransferSideFields(
                                account: transferTarget, sourceAccountID: accountID, sourceAmount: amount, sourceCurrency: currency, time: time,
                                currency: $toCurrency, amountText: $toAmountText
                            )
                        }
                    }
                } footer: {
                    if let chargeNote {
                        Text(chargeNote)
                    } else if type == .transfer, toAccountID != nil {
                        Text(TransferSideFields.note)
                    }
                }
                if type != .transfer {
                    Section("分类") {
                        CategoryGrid(type: CategoryType(type), selected: categoryID) { categoryID = $0 }
                    }
                }
                Section("备注") {
                    TextField("写点什么，比如买了什么（选填）", text: $note, axis: .vertical)
                        .lineLimit(1...5)
                }
                Section {
                    if type != .transfer {
                        TextField("商户或对方（选填）", text: $counterparty)
                    }
                    DatePicker("时间", selection: $time)
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("记一笔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") { Task { await check() } }
                        .disabled(saving || accountID == nil || currency == nil)
                }
            }
            .confirmationDialog("可能已经记过了", isPresented: $confirmSimilar, titleVisibility: .visible) {
                Button("仍然记一笔") { Task { await save() } }
                Button("不记了", role: .cancel) {}
            } message: {
                Text(similarMessage)
            }
            .onChange(of: accountID) {
                if let toAccountID, !transferTargets.contains(where: { $0.id == toAccountID }) { self.toAccountID = nil }
                settlementText = ""
                resetTransferSide()
            }
            .onChange(of: toAccountID) { resetTransferSide() }
            .onChange(of: currency) {
                settlementText = ""
                resetTransferSide()
            }
            .onChange(of: type) {
                if let category = store.categoryTree.category(categoryID), category.type != CategoryType(type) { categoryID = nil }
            }
            .task(id: estimateKey) { await updateEstimates() }
            .task {
                guard accountID == nil else { return }
                let last = await store.lastManualAccountID()
                accountID = accounts.first(where: { $0.id == last })?.id ?? accounts.first?.id
                amountFocused = true
            }
        }
    }

    /// 转出的账户、币种或转到的账户变了：到账的币种回到默认，金额清空
    private func resetTransferSide() {
        toAmountText = ""
        toCurrency = transferTarget.map {
            TransferSideFields.defaultCurrency(in: $0, sourceAccountID: accountID, sourceCurrency: currency)
        }
    }

    /// 账户选项：有这个币种的在前；没有的另起一组，写明按主币种记
    @ViewBuilder
    private func accountOptions(_ list: [Account]) -> some View {
        let holding = list.filter { account in currency.map { account.currencies.contains($0) } ?? true }
        let others = list.filter { account in !holding.contains(where: { $0.id == account.id }) }
        if holding.isEmpty || others.isEmpty {
            ForEach(list) { Text($0.displayTitle).tag(String?.some($0.id)) }
        } else {
            Section {
                ForEach(holding) { Text($0.displayTitle).tag(String?.some($0.id)) }
            }
            Section("没有\(currency?.chineseName ?? "")，按账户的主币种记") {
                ForEach(others) { Text("\($0.displayTitle)（\($0.currency.chineseName)）").tag(String?.some($0.id)) }
            }
        }
    }

    /// 实际扣款（入账）：空着时提示按汇率大概多少
    private func settlementRow(_ title: String, _ charge: CurrencyCode, text: Binding<String>, estimate: RecordCharge?) -> some View {
        HStack {
            Text("\(title)（\(charge.chineseName)）")
            TextField(estimate?.amountMinor.map { "约 " + Fmt.money($0, charge) } ?? "按汇率估算", text: text)
                .keyboardType(charge.minorUnitExponent == 0 ? .numberPad : .decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
        }
    }

    private var chargeNote: String? {
        guard let currency, chargeCurrency(accountID) != nil else { return nil }
        let head = "账户里没有\(currency.chineseName)，按账户的主币种记。"
        guard let day = estimate?.rateDay else {
            return head + "还没有汇率：可以直接填银行实际扣了多少，不填就等导入汇率后估算。"
        }
        return head + "不填按 \(Fmt.rateDay(day)) 的汇率估算；银行实际扣了多少可以直接填。"
    }

    /// 金额、币种、账户、日期变了就重新估算
    private var estimateKey: String {
        let day = Calendar.current.startOfDay(for: time).timeIntervalSince1970
        return "\(amount ?? 0)|\(currency?.rawValue ?? "")|\(chargeCurrency(accountID)?.rawValue ?? "")|\(day)"
    }

    private func updateEstimates() async {
        guard let currency, let amount else {
            estimate = nil
            return
        }
        var from: RecordCharge?
        if let charge = chargeCurrency(accountID) {
            from = await store.estimateCharge(amountMinor: amount, currency: currency, to: charge, at: time)
        }
        guard !Task.isCancelled else { return }
        estimate = from
    }

    private var similarMessage: String {
        guard let row = similar.first else { return "" }
        return "\(Fmt.dateTime(row.record.effectiveAt))「\(row.title)」\(row.amountText(inAccount: true))，同一个账户、同样的金额。"
    }

    /// 实际扣款（入账）：空着是 nil（按汇率估算）；格式不对时写错误提示并返回 false
    private func settlement(_ text: String, for id: String?) -> (ok: Bool, minor: Int64?) {
        guard let charge = chargeCurrency(id) else { return (true, nil) }
        switch MoneyInput.parse(text, negative: false, currency: charge) {
        case .empty: return (true, nil)
        case .valid(let minor) where minor > 0: return (true, minor)
        default:
            errorText = "实际金额：" + MoneyInput.invalidAmountMessage(charge)
            return (false, nil)
        }
    }

    private func entry() -> ManualEntry? {
        guard let accountID, let currency else { return nil }
        guard let amount else {
            errorText = MoneyInput.invalidAmountMessage(currency)
            return nil
        }
        var toAmount: Int64?
        if type == .transfer {
            guard let transferTarget, let toCurrency else {
                errorText = "请选择转到哪个账户"
                return nil
            }
            let side = TransferSideFields.resolve(
                text: toAmountText, currency: toCurrency, account: transferTarget, sourceAccountID: accountID,
                sourceAmount: amount, sourceCurrency: currency
            )
            if let error = side.error {
                errorText = error
                return nil
            }
            toAmount = side.minor
        }
        let from = settlement(settlementText, for: accountID)
        guard from.ok else { return nil }
        return ManualEntry(
            type: type, accountID: accountID, toAccountID: type == .transfer ? toAccountID : nil, amountMinor: amount, currency: currency,
            toAmountMinor: toAmount, toCurrency: type == .transfer ? toCurrency : nil,
            categoryID: type == .transfer ? nil : categoryID, counterparty: type == .transfer ? nil : counterparty, note: note, time: time,
            settlementMinor: from.minor
        )
    }

    /// 先查一下是不是已经记过
    private func check() async {
        guard let entry = entry() else { return }
        similar = await store.similarRecords(to: entry)
        if similar.isEmpty {
            await save()
        } else {
            confirmSimilar = true
        }
    }

    private func save() async {
        guard let entry = entry() else { return }
        saving = true
        defer { saving = false }
        do {
            try await store.addRecord(entry)
            dismiss()
        } catch {
            errorText = "保存失败：\(error.localizedDescription)"
        }
    }
}
