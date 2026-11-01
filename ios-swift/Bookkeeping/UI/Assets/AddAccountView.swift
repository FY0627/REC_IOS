import SwiftUI
import PhotosUI
import BKModel
import BKBackend

/// 添加账户：银行卡、现金或电子钱包（微信零钱、支付宝余额这种自己有余额的）。
/// 银行卡：银行（直接输入，下面列出对得上的银行全称，什么语言都能搜）、后四位、卡类型、
/// 币种（可设为多币种账户）和每个币种的初始余额（选填，不填从 0 开始，紧跟在选好的币种下面）。不收集完整卡号、密码或邮箱凭据。
/// 现金、电子钱包：名称、币种和初始余额；没有卡号。现金用「记一笔」手动记；
/// 电子钱包选了是哪个钱包（支付宝、微信支付……），它发来的、没写银行卡号的通知自动记到这里（`WalletDirectory`）。
struct AddAccountView: View {
    enum Kind: Hashable, CaseIterable {
        case card, cash, wallet

        var title: String {
            switch self {
            case .card: "银行卡"
            case .cash: "现金"
            case .wallet: "电子钱包"
            }
        }

        var cardType: CardType? {
            switch self {
            case .card: nil
            case .cash: .cash
            case .wallet: .wallet
            }
        }
    }

    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind = .card
    @State private var bankText = ""
    /// 从列表里选中的银行；改了名称就不算选中
    @State private var bank: BankEntry?
    @FocusState private var bankFocused: Bool
    @State private var name = ""
    /// 电子钱包是哪个钱包；nil 是「其他」（按名称猜，猜不出就只能手动记）
    @State private var walletID: String?
    @State private var last4 = ""
    @State private var cardType: CardType = .debit
    @State private var currency: CurrencyCode?
    @State private var multiCurrency = false
    @State private var extraCurrencies: [CurrencyCode] = []
    @State private var balances: [CurrencyCode: BalanceInput] = [:]
    @State private var paletteID = "ocean"
    @State private var paletteTouched = false
    /// 卡面用自己的照片（默认不用，选配色）
    @State private var useOwnPhoto = false
    @State private var photoItem: PhotosPickerItem?
    @State private var photoID: String?
    @State private var importingPhoto = false
    /// 这次选过的图片；没保存或换掉的在离开时删除
    @State private var importedPhotoIDs: [String] = []
    @State private var keptPhotoID: String?
    @State private var saving = false
    @State private var errorText: String?
    @State private var created: Account?

    private var bankName: String { bankText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 这张卡的币种，主币种在前
    private var currencies: [CurrencyCode] {
        guard let currency else { return [] }
        return [currency] + (multiCurrency ? extraCurrencies.filter { $0 != currency } : [])
    }

    /// 现金、电子钱包的名称；没填时现金叫「现金」，电子钱包叫钱包的名称
    private var pocketName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        switch kind {
        case .cash: return "现金"
        case .wallet: return WalletDirectory.profile(id: walletID)?.name ?? ""
        case .card: return ""
        }
    }

    /// 选钱包时列出的顺序
    private static let wallets = ["alipay", "wechatpay", "alipayhk", "wechatpayhk"].compactMap(WalletDirectory.profile)

    private var isValid: Bool {
        let named = kind == .card ? !bankName.isEmpty && Account.isValidLast4(last4) : !pocketName.isEmpty
        return named && currency != nil && currencies.allSatisfy { balance($0).wrappedValue.value($0) != .invalid }
    }

    private var suggestions: [BankEntry] {
        bank == nil ? BankCatalog.search(bankText) : []
    }

    /// 没填过的币种：信用卡默认是欠款
    private func balance(_ code: CurrencyCode) -> Binding<BalanceInput> {
        Binding { balances[code] ?? BalanceInput(isDebt: kind == .card && cardType == .credit) } set: { balances[code] = $0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("账户类型", selection: $kind) {
                        ForEach(Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if kind == .card {
                    Section("银行") {
                        TextField("银行名称", text: $bankText)
                            .focused($bankFocused)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                        ForEach(suggestions) { entry in
                            Button { choose(entry) } label: { BankSuggestionRow(entry: entry) }
                        }
                    }
                    Section("卡片") {
                        TextField("卡号后四位", text: $last4)
                            .keyboardType(.numberPad)
                            .onChange(of: last4) { _, value in
                                let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(4))
                                if digits != value { last4 = digits }
                            }
                            .accessibilityHint("四位数字，保留开头的 0")
                        Picker("卡类型", selection: $cardType) {
                            ForEach(CardType.cardCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        TextField("账户名称（可选）", text: $name)
                    }
                } else {
                    Section {
                        if kind == .wallet {
                            Picker("钱包", selection: $walletID) {
                                ForEach(Self.wallets) { Text($0.name).tag(String?.some($0.id)) }
                                Text("其他").tag(String?.none)
                            }
                        }
                        TextField(kind == .cash ? "现金" : (WalletDirectory.profile(id: walletID)?.name ?? "例如 微信零钱、支付宝余额"), text: $name)
                    } header: {
                        Text("名称")
                    } footer: {
                        if kind == .wallet {
                            Text(walletID == nil
                                 ? "选了是哪个钱包，它发来的通知可以自动记到这里。"
                                 : "这个钱包发来的、没写银行卡号的通知会自动记到这里；同一个钱包有几个账户时，会让你选记到哪个。")
                        }
                    }
                }
                Section("币种与初始余额") {
                    CurrencyLink(title: multiCurrency ? "主币种" : "币种", currency: primaryCurrency)
                    if let currency {
                        OpeningBalanceRow(currency: currency, label: multiCurrency ? currency.chineseName : nil, input: balance(currency))
                    }
                    if kind == .card {
                        Toggle("多币种账户", isOn: $multiCurrency)
                    }
                    if multiCurrency, kind == .card {
                        NavigationLink {
                            CurrencyPicker(title: "其他币种", selection: $extraCurrencies, multiple: true, fixed: currency)
                        } label: {
                            LabeledContent("其他币种", value: extrasSummary)
                        }
                        ForEach(currencies.dropFirst(), id: \.self) { code in
                            OpeningBalanceRow(currency: code, label: code.chineseName, input: balance(code))
                        }
                    }
                }
                // 先选用不用自己的照片；不用（默认）才列出配色
                Section("卡面") {
                    Toggle("用自己的照片", isOn: $useOwnPhoto.animation())
                    if useOwnPhoto {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            HStack {
                                Label(photoID == nil ? "从相册选择图片" : "更换图片", systemImage: "photo")
                                Spacer()
                                if importingPhoto {
                                    ProgressView()
                                } else if let photoID, let image = CardFaceImages.shared.image(photoID) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .aspectRatio(AppLayout.cardAspect, contentMode: .fill)
                                        .frame(width: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                            }
                        }
                        .disabled(importingPhoto)
                    } else {
                        PaletteGrid(selection: Binding(get: { paletteID }, set: { paletteID = $0; paletteTouched = true }))
                            .padding(.vertical, 4)
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("添加账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") { Task { await save() } }.disabled(!isValid || saving)
                }
            }
            .onChange(of: bankText) { _, text in
                if let bank, text != bank.name { self.bank = nil }
            }
            .onChange(of: cardType) { _, type in
                for (code, input) in balances where input.text.isEmpty { balances[code]?.isDebt = type == .credit }
            }
            .onChange(of: kind) { _, kind in
                if kind != .card { multiCurrency = false }
                for (code, input) in balances where input.text.isEmpty { balances[code]?.isDebt = kind == .card && cardType == .credit }
            }
            .onChange(of: photoItem) { _, item in
                if let item { Task { await importPhoto(item) } }
            }
            .navigationDestination(item: $created) { account in
                AutoSetupGuideView(onDone: { dismiss() })
            }
            .task {
                // 银行和币种的搜索列表第一次要查系统名称、算拼音，先在后台准备好
                await CurrencyCatalog.prepare()
                await Task.detached(priority: .utility) { _ = BankCatalog.search("银行") }.value
            }
        }
        // 整个添加页关掉时（不是推进选币种页时）：删除没用上的图片
        .onDisappear {
            CardFaceImages.shared.discard(importedPhotoIDs.filter { $0 != keptPhotoID })
        }
    }

    /// 选主币种：选的是其他币种之一时，和原来的主币种互换
    private var primaryCurrency: Binding<CurrencyCode?> {
        Binding { currency } set: { newValue in
            guard let newValue, newValue != currency else { return }
            if let index = extraCurrencies.firstIndex(of: newValue) {
                if let old = currency { extraCurrencies[index] = old } else { extraCurrencies.remove(at: index) }
            }
            currency = newValue
        }
    }

    private var extrasSummary: String {
        let extras = currencies.dropFirst()
        return extras.isEmpty ? "请选择" : extras.map(\.chineseName).joined(separator: "、")
    }

    private func choose(_ entry: BankEntry) {
        bank = entry
        bankText = entry.name
        bankFocused = false
        if !paletteTouched, let palette = entry.paletteID { paletteID = palette }
    }

    /// 选好的照片缩小、裁成卡片比例存起来（和卡面编辑一样）
    private func importPhoto(_ item: PhotosPickerItem) async {
        importingPhoto = true
        defer {
            importingPhoto = false
            photoItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw CardFaceImages.ImportError.unreadable }
            let id = try await Task.detached(priority: .userInitiated) {
                try CardFaceImages.importImage(data, pixelWidth: 1080, aspect: AppLayout.cardAspect)
            }.value
            importedPhotoIDs.append(id)
            photoID = id
            errorText = nil
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "无法读取这张图片"
        }
    }

    /// 账户添加好以后换上自己的照片；文字用白色，在大多数照片上更清楚
    private func applyPhoto(to account: Account) async {
        guard useOwnPhoto, let photoID else { return }
        try? await store.updateCardFace(accountID: account.id, paletteID: paletteID, face: CardFace(imageID: photoID))
        keptPhotoID = photoID
    }

    private func save() async {
        guard let currency else { return }
        saving = true
        defer { saving = false }
        if let pocketType = kind.cardType {
            var opening: Int64?
            if case .valid(let minor) = balance(currency).wrappedValue.value(currency) { opening = minor }
            do {
                let account = try await store.addAccount(.pocket(
                    name: pocketName, type: pocketType, currency: currency, paletteID: paletteID, openingBalanceMinor: opening,
                    walletID: kind == .wallet ? walletID : nil
                ))
                await applyPhoto(to: account)
                dismiss()
            } catch BackendError.invalidAccount(.duplicateAccount) {
                errorText = "已经有一个叫「\(pocketName)」的\(pocketType.displayName)账户。"
            } catch {
                errorText = "保存失败：\(error)"
            }
            return
        }
        // 没点列表、但打的正好是某家银行的名称或叫法：也算选中它
        let entry = bank ?? BankCatalog.exactMatch(bankText)
        var openings: [CurrencyCode: Int64] = [:]
        for code in currencies {
            if case .valid(let minor) = balance(code).wrappedValue.value(code) { openings[code] = minor }
        }
        let draft = AccountDraft(
            name: name, bankID: entry?.id, bankName: entry?.name ?? bankName,
            last4: last4, cardType: cardType, currency: currency, paletteID: paletteID, openingBalanceMinor: openings[currency],
            extraCurrencies: Array(currencies.dropFirst()), extraOpeningBalances: openings.filter { $0.key != currency }
        )
        do {
            let alreadyAutomated = store.automationVerified
            let account = try await store.addAccount(draft)
            await applyPhoto(to: account)
            errorText = nil
            // 自动化已经在工作：一个自动化覆盖所有卡，新卡不用再设置
            if alreadyAutomated { dismiss() } else { created = account }
        } catch BackendError.invalidAccount(let reason) {
            switch reason {
            case .duplicateAccount: errorText = "已经添加过这张卡（同一银行、同一尾号、同一卡类型）。"
            case .invalidLast4: errorText = "后四位必须是 4 位数字。"
            case .emptyBank, .emptyName: errorText = "请填写银行。"
            case .invalidCardNumber: errorText = "卡号格式不正确。"
            case .invalidAccountNumber: errorText = "账号格式不正确。"
            }
        } catch {
            errorText = "保存失败：\(error)"
        }
    }
}

/// 输入银行名称时列出的一家银行：中文全称，下面是英文或当地名称和地区。
/// 颜色用 `Color.primary` / `Color.secondary`：按钮里的层级样式 `.primary` 会跟着强调色变成蓝色
private struct BankSuggestionRow: View {
    let entry: BankEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name).foregroundStyle(Color.primary)
            Text(entry.localName == entry.name ? entry.region : "\(entry.localName) · \(entry.region)")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
