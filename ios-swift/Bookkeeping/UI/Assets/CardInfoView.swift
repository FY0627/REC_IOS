import SwiftUI
import UIKit
import BKModel
import BKBackend

/// 卡片信息：银行、卡类型、币种、每个币种的余额和校准余额、完整卡号（选填，默认遮住）、账号。
/// 编辑时可以改账户名称、卡类型、主币种、多币种账户的其他币种、校准余额、卡号和账号（银行和尾号不能改）；
/// 也可以停用 / 启用这张卡，停用的卡可以删除（流水留着，账户名称后面写「已删除」）。
/// 校准余额（参考 MOZE 的余额调整）：App 里的余额和实际对不上时，填「现在」实际有多少，之后的流水从这里接着算。
/// 放在这里不显眼的地方，平时用不到。现金、电子钱包没有银行和卡号。
struct CardInfoView: View {
    let accountID: String

    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var name = ""
    @State private var cardType: CardType = .debit
    @State private var currency: CurrencyCode?
    @State private var multiCurrency = false
    @State private var extras: [CurrencyCode] = []
    @State private var balances: [CurrencyCode: BalanceInput] = [:]
    @State private var number = ""
    @State private var accountNumber = ""
    @State private var revealed = false
    @State private var copied = false
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            if let account = store.account(id: accountID) {
                form(account)
            }
        }
    }

    private func form(_ account: Account) -> some View {
        Form {
            if editing {
                editFields(account)
            } else {
                infoFields(account)
            }

            if account.isCard {
                Section {
                    if editing {
                        TextField("完整卡号（选填）", text: $number)
                            .keyboardType(.numberPad)
                            .font(.body.monospacedDigit())
                            .onChange(of: number) { _, value in
                                let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(19))
                                if digits != value { number = digits }
                            }
                    } else if let full = account.cardNumber {
                        numberRow(full)
                        Button(copied ? "已复制" : "复制卡号", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            UIPasteboard.general.string = full
                            copied = true
                        }
                    } else {
                        LabeledContent("卡号", value: "尾号 \(account.last4)")
                    }
                    // 只写账号不写卡号尾号的通知（例如转账邮件）靠账号匹配；可以直接粘贴通知里打码的账号
                    if editing {
                        TextField("账号（选填，可粘贴打码的账号）", text: $accountNumber)
                            .font(.body.monospacedDigit())
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    } else if let value = account.accountNumber {
                        LabeledContent("账号") { Text(value).monospacedDigit() }
                    }
                } header: {
                    Text("卡号")
                }
            }

            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }

            if !editing {
                // 停用后详情页保持打开，卡片变灰并移到资产页最下方的「已停用」
                // 只有文字，靠左（和流水详情的操作一样）
                Section {
                    if account.archived {
                        Button { setArchived(account, false) } label: { ActionLabel(title: "启用") }
                    } else {
                        Button(role: .destructive) { setArchived(account, true) } label: { ActionLabel(title: "停用") }
                    }
                }
                // 停用的卡才能删除；确认的小菜单就在这个按钮旁边弹出
                if account.archived {
                    Section {
                        Menu {
                            Section("删除后不能恢复，流水会保留") {
                                Button(account.isCard ? "删除这张卡" : "删除这个账户", systemImage: "trash", role: .destructive) { delete(account) }
                            }
                        } label: {
                            ActionLabel(title: "删除").foregroundStyle(Color.red)
                        }
                    }
                }
            }
        }
        .navigationTitle(account.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: cardType) { old, new in
            // 名称还是默认的（例如「招商银行借记卡」）：跟着卡类型改
            if editing, name.trimmingCharacters(in: .whitespaces) == Account.defaultName(bankName: account.bankName, cardType: old) {
                name = Account.defaultName(bankName: account.bankName, cardType: new)
            }
        }
        .toolbar {
            // 左上角一直是返回：编辑时回到查看（不保存），查看时关掉卡片信息
            ToolbarItem(placement: .topBarLeading) {
                Button("返回", systemImage: "chevron.left") {
                    if editing {
                        withAnimation(Self.modeChange) {
                            editing = false
                            errorText = nil
                        }
                    } else {
                        dismiss()
                    }
                }
            }
            // 右上角：查看时是「编辑」，编辑时换成勾（保存）；在动画里切换，按钮跟着变
            if editing {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") { Task { await save(account) } }
                        .disabled(saving || currency == nil)
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button("编辑") { startEditing(account) }
                }
            }
        }
    }

    // MARK: 查看

    @ViewBuilder
    private func infoFields(_ account: Account) -> some View {
        Section {
            LabeledContent("账户名称", value: account.name)
            if account.isCard {
                LabeledContent("银行", value: account.bankName)
            }
            LabeledContent(account.isCard ? "卡类型" : "类型", value: account.cardType.displayName)
            LabeledContent(account.isMultiCurrency ? "主币种" : "币种", value: Self.title(account.currency))
            if account.isMultiCurrency {
                LabeledContent("其他币种", value: account.extraCurrencies.map(\.chineseName).joined(separator: "、"))
            }
            LabeledContent("添加时间", value: Fmt.dateTime(account.createdAt))
        }
        Section("余额") {
            ForEach(account.currencies, id: \.self) { code in
                let summary = store.balances[account.id]?.item(code)
                let prefix = account.isMultiCurrency ? code.chineseName : ""
                LabeledContent("\(prefix)余额") {
                    Text(summary?.ledgerDerivedMinor.map { Fmt.money($0, code) } ?? "未知").monospacedDigit()
                }
                LabeledContent("\(prefix)上次校准") {
                    Text(account.openingBalance(code).map { Fmt.money($0.amountMinor, code) } ?? "未填写").monospacedDigit()
                }
                if let unconverted = summary?.unconvertedCount, unconverted > 0 {
                    Text("另有 \(unconverted) 笔外币交易还没有汇率，没算进余额").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 编辑

    @ViewBuilder
    private func editFields(_ account: Account) -> some View {
        Section {
            TextField("账户名称", text: $name)
            if account.isCard {
                LabeledContent("银行", value: account.bankName)
                Picker("卡类型", selection: $cardType) {
                    ForEach(CardType.cardCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
        }
        Section {
            CurrencyLink(title: multiCurrency ? "主币种" : "币种", currency: primaryCurrency)
            if let currency {
                OpeningBalanceRow(currency: currency, label: multiCurrency ? currency.chineseName : nil, input: balance(currency), placeholderTitle: "校准余额", emptyPlaceholder: "校准余额（选填）")
            }
            if account.isCard {
                Toggle("多币种账户", isOn: $multiCurrency)
            }
            if multiCurrency {
                NavigationLink {
                    CurrencyPicker(title: "其他币种", selection: $extras, multiple: true, fixed: currency)
                } label: {
                    LabeledContent("其他币种", value: heldExtras.isEmpty ? "请选择" : heldExtras.map(\.chineseName).joined(separator: "、"))
                }
                ForEach(heldExtras, id: \.self) { code in
                    OpeningBalanceRow(currency: code, label: code.chineseName, input: balance(code), placeholderTitle: "校准余额", emptyPlaceholder: "校准余额（选填）")
                }
            }
        } header: {
            Text("币种与校准余额")
        } footer: {
            Text("余额对不上时，填现在实际有多少。")
        }
    }

    private var heldExtras: [CurrencyCode] {
        multiCurrency ? extras.filter { $0 != currency } : []
    }

    /// 选主币种：选的是其他币种之一时，和原来的主币种互换
    private var primaryCurrency: Binding<CurrencyCode?> {
        Binding { currency } set: { newValue in
            guard let newValue, newValue != currency else { return }
            if let index = extras.firstIndex(of: newValue) {
                if let old = currency { extras[index] = old } else { extras.remove(at: index) }
            }
            currency = newValue
        }
    }

    /// 没填过初始余额的币种：信用卡默认是欠款
    private func balance(_ code: CurrencyCode) -> Binding<BalanceInput> {
        Binding { balances[code] ?? BalanceInput(isDebt: cardType == .credit) } set: { balances[code] = $0 }
    }

    private func startEditing(_ account: Account) {
        name = account.name
        cardType = account.cardType
        currency = account.currency
        multiCurrency = account.isMultiCurrency
        extras = account.extraCurrencies
        var inputs: [CurrencyCode: BalanceInput] = [:]
        for opening in account.openingBalances {
            inputs[opening.currency] = .existing(opening.amountMinor)
        }
        balances = inputs
        number = account.cardNumber ?? ""
        accountNumber = account.accountNumber ?? ""
        errorText = nil
        withAnimation(Self.modeChange) { editing = true }
    }

    /// 查看 ↔ 编辑：右上角的按钮和下面的内容一起变
    private static let modeChange: Animation = .smooth(duration: 0.35)

    private func setArchived(_ account: Account, _ archived: Bool) {
        dismiss()
        Task { await store.setArchived(accountID: account.id, archived: archived) }
    }

    /// 先关掉页面：卡没了以后资产页会直接关闭详情
    private func delete(_ account: Account) {
        dismiss()
        Task {
            guard (try? await store.deleteAccount(id: account.id)) != nil else { return }
            if let image = account.face.imageID { CardFaceImages.shared.discard([image]) }
        }
    }

    /// 默认只露出尾号；点眼睛显示完整卡号（每 4 位一组）。
    private func numberRow(_ full: String) -> some View {
        HStack {
            Text(revealed ? Self.grouped(full) : Self.masked(full))
                .font(.body.monospacedDigit())
                .textSelection(.enabled)
            Spacer()
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(revealed ? "遮住卡号" : "显示完整卡号")
        }
    }

    static func title(_ code: CurrencyCode) -> String { "\(code.chineseName) \(code.rawValue)" }

    static func grouped(_ digits: String) -> String {
        var result = ""
        for (index, char) in digits.enumerated() {
            if index > 0, index % 4 == 0 { result.append(" ") }
            result.append(char)
        }
        return result
    }

    static func masked(_ digits: String) -> String {
        grouped(String(repeating: "•", count: max(0, digits.count - 4)) + digits.suffix(4))
    }

    private func save(_ account: Account) async {
        guard let currency else { return }
        let held = [currency] + heldExtras
        // 只有改过的初始余额才重新记（记为「现在」的余额）；没动的保持原来的时间点。
        // 输入框空着表示保持原来的金额，只换了余额 / 欠款就按原来的金额换方向
        var changes: [OpeningBalanceChange] = []
        for code in held {
            let value = balance(code).wrappedValue.value(code)
            let entered: Int64?
            switch value {
            case .invalid:
                errorText = "\(code.chineseName)的校准余额格式不对，例如 1234.56"
                return
            case .empty: entered = nil
            case .valid(let minor): entered = minor
            }
            if entered != account.openingBalance(code)?.amountMinor {
                changes.append(OpeningBalanceChange(currency: code, amountMinor: entered))
            }
        }
        saving = true
        defer { saving = false }
        do {
            try await store.updateAccount(id: account.id, AccountEdit(
                name: name, cardType: cardType, currency: currency, extraCurrencies: Array(held.dropFirst()),
                cardNumber: number, accountNumber: accountNumber, openingBalanceChanges: changes
            ))
            errorText = nil
            revealed = false
            withAnimation(Self.modeChange) { editing = false }
        } catch BackendError.invalidAccount(.duplicateAccount) {
            errorText = "已经有一张同一银行、同一尾号的\(cardType.displayName)。"
        } catch BackendError.invalidAccount(.invalidAccountNumber) {
            errorText = "账号只能包含数字、X 和短横线，至少 6 位。"
        } catch BackendError.invalidAccount(.invalidCardNumber) {
            errorText = "卡号必须是 12–19 位数字，末四位是 \(account.last4)。"
        } catch {
            errorText = "保存失败：\(error)"
        }
    }
}
