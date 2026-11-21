import PhotosUI
import SwiftUI
import UIKit
import BKBackend
import BKModel

/// 识别模板的编辑页（和记一笔一样是弹出的表单）：新添加、改已有的、或用一条待处理的通知做。
/// 原文在一个像备忘录的输入框里，直接粘贴或打字，光标离开就按 App 自带的读法认一遍（圈好金额、猜好类型）；
/// 「导入」时输入框右下角的圆按钮从相册选截图，换成截图模板的编辑页（ADR 0028）。
/// 在原文里选中金额（必选）、尾号、对方，和记账一样选支出 / 收入 / 转帐，保存。
/// 交易性质按选的类型换（`MessageTemplate.fields`），原来的性质还在同一类里就保留，例如手续费、工资、还款。
///
/// 模板只保存在这台 iPhone；保存的是写法，选中的内容和原文里的其他数字都不保存。
/// 改已有的模板时没有原文，用 `MessageTemplates.sample` 还原成一条示例（金额 100.00、尾号 1234、其他数字 0）。
/// 收到通知时先用模板认（新做的在前），都认不出再用 App 自带的读法。
struct TemplateEditorView: View {
    enum Origin {
        case new
        case existing(MessageTemplate)
        case pending(PendingItem)
    }

    let origin: Origin
    /// 「识别模板 › 导入」：也能从相册选截图，选好交出去换成截图模板的编辑页（ADR 0028）
    var pickScreenshot: ((ScreenshotInbox.Entry) -> Void)?
    @Environment(LedgerStore.self) private var store
    @State private var photo: PhotosPickerItem?
    @State private var readingPhoto = false
    @Environment(\.dismiss) private var dismiss

    @State private var sample = ""
    /// 光标在输入框里：这时不画选中的颜色，离开时按新的原文重新认
    @State private var editingText = false
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var amount: NSRange?
    @State private var cardTail: NSRange?
    @State private var counterparty: NSRange?
    @State private var type: EntryType = .expense
    @State private var refund = false
    @State private var transferDirection: FlowDirection = .outflow
    /// 原来的交易性质（改已有的模板、用通知猜的）
    @State private var originalKind: TransactionKind?
    /// 记到哪个账户；nil 时按通知里的尾号、银行找
    @State private var accountID: String?
    @State private var name = ""
    @State private var errorText: String?
    @State private var saving = false
    @State private var savedCount: Int?
    @State private var loaded = false

    init(item: PendingItem) { origin = .pending(item) }
    init(template: MessageTemplate?, pickScreenshot: ((ScreenshotInbox.Entry) -> Void)? = nil) {
        origin = template.map(Origin.existing) ?? .new
        self.pickScreenshot = pickScreenshot
    }

    private enum Mark {
        case amount, cardTail, counterparty
    }

    private var entryChoice: Binding<TemplateEntryChoice> {
        TemplateEntryChoice.binding(type: $type, refund: $refund, transferDirection: $transferDirection)
    }

    private var existing: MessageTemplate? {
        if case .existing(let template) = origin { return template }
        return nil
    }

    private var title: String {
        switch origin {
        case .new: L("添加识别模板")
        case .existing: L("编辑识别模板")
        case .pending: L("做成识别模板")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // 像写邮件：名称、类型、原文排在一张卡片上，空着的地方直接点上去填、选
                Section {
                    MailRow("名称") {
                        TextField("模板名称", text: $name)
                    }
                    MailRow("类型") {
                        Picker("类型", selection: entryChoice) {
                            ForEach(TemplateEntryChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        Spacer(minLength: 0)
                    }
                    // 和截图模板一样：选了账户就记到它，通知里圈的尾号是转帐的另一边
                    MailRow("记到") {
                        Picker("记到", selection: $accountID) {
                            Text(cardTail == nil ? L("自动") : L("按通知里的尾号")).tag(String?.none)
                            ForEach(accounts) { account in
                                Text(account.localizedTitle).tag(Optional(account.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        Spacer(minLength: 0)
                    }
                    // 像备忘录：直接粘贴或打字，离开输入框就按通用读法认一遍；右下角的圆按钮从相册插一张截图
                    TemplateTextBox(text: sample, highlights: editingText ? [] : highlights, selection: $selection, editing: $editingText) { text in
                        applyText(text)
                    }
                    .frame(height: 240)
                    .overlay(alignment: .topLeading) {
                        if sample.isEmpty, !editingText {
                            Text(pickScreenshot == nil ? "粘贴一条收到的短信或邮件" : "粘贴一条通知，或者选一张截图")
                                .foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if pickScreenshot != nil {
                            PhotosPicker(selection: $photo, matching: .screenshots) {
                                Group {
                                    if readingPhoto {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "photo")
                                    }
                                }
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Color(.tertiarySystemFill)))
                            }
                            .buttonStyle(.borderless)
                            .disabled(readingPhoto)
                            .accessibilityLabel("从相册选截图")
                        }
                    }
                }

                if !sample.isEmpty {
                    Section("选中的内容") {
                        markRow("金额", mark: .amount, range: amount, tint: .green, required: true)
                        markRow("尾号", mark: .cardTail, range: cardTail, tint: .blue, required: false)
                        markRow("对方", mark: .counterparty, range: counterparty, tint: .orange, required: false)
                    }
                }

                if case .success(let pieces)? = built {
                    Section("写法") {
                        Text(pieces.map(\.preview).joined()).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // 不在键盘上方加「完成」：点页面空白处收起键盘（`dismissesKeyboardOnTapOutside`，装在根视图上）
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") { Task { await save() } }
                        .disabled((amount == nil && !editingText) || saving)
                }
            }
            .onAppear(perform: setup)
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                Task { await readPhoto(item) }
            }
            .alert("已保存", isPresented: Binding(get: { savedCount != nil }, set: { if !$0 { savedCount = nil } })) {
                Button("好") { dismiss() }
            } message: {
                Text(savedCount.map { L("待处理里有 \($0) 条通知按这个模板重新识别。") } ?? "")
            }
        }
    }

    private func markRow(_ title: LocalizedStringKey, mark: Mark, range: NSRange?, tint: Color, required: Bool) -> some View {
        HStack(spacing: 12) {
            Circle().fill(tint.opacity(0.6)).frame(width: 10, height: 10).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(range.map(substring) ?? (required ? L("必选") : L("可不选")))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if range != nil {
                Button("清除", systemImage: "xmark.circle.fill") { set(mark, nil) }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
            }
            Button("用选中的") {
                // 先离开输入框：原文没改时选中的位置不变
                let picked = selection
                let before = sample
                endEditing()
                if sample == before, picked.length > 0, NSMaxRange(picked) <= NSString(string: sample).length { set(mark, picked) }
            }
                .buttonStyle(.bordered)
                .disabled(selection.length == 0)
        }
    }

    private var highlights: [(range: NSRange, color: UIColor)] {
        var result: [(range: NSRange, color: UIColor)] = []
        if let amount { result.append((range: amount, color: UIColor.systemGreen.withAlphaComponent(0.3))) }
        if let cardTail { result.append((range: cardTail, color: UIColor.systemBlue.withAlphaComponent(0.3))) }
        if let counterparty { result.append((range: counterparty, color: UIColor.systemOrange.withAlphaComponent(0.3))) }
        return result
    }

    /// 选的类型对应的交易性质和方向
    private var fields: (kind: TransactionKind, direction: FlowDirection) {
        MessageTemplate.fields(type: type, refund: refund, transferDirection: transferDirection, keeping: originalKind)
    }

    private func show(kind: TransactionKind?, direction: FlowDirection) {
        let entry = MessageTemplate.entry(kind: kind ?? .other, direction: direction)
        type = entry.type
        refund = entry.refund
        transferDirection = direction
        originalKind = kind
    }

    private var built: Result<[TemplatePiece], MessageTemplates.BuildError>? {
        guard let amount else { return nil }
        return MessageTemplates.build(sample: sample, amount: amount, cardTail: cardTail, counterparty: counterparty)
    }

    private func substring(_ range: NSRange) -> String {
        let ns = NSString(string: sample)
        guard NSMaxRange(range) <= ns.length else { return "" }
        return ns.substring(with: range)
    }

    private func set(_ mark: Mark, _ range: NSRange?) {
        switch mark {
        case .amount: amount = range
        case .cardTail: cardTail = range
        case .counterparty: counterparty = range
        }
        errorText = nil
        if case .failure(let error)? = built { errorText = error.message }
    }

    private func setup() {
        guard !loaded else { return }
        loaded = true
        switch origin {
        case .new:
            break
        case .existing(let template):
            let restored = MessageTemplates.sample(template.pieces)
            sample = restored.text
            amount = restored.amount
            cardTail = restored.cardTail
            counterparty = restored.counterparty
            show(kind: template.kind, direction: template.direction)
            accountID = template.accountID
            name = template.name
        case .pending(let item):
            sample = MessageParser.cleaned(item.rawText ?? "", source: item.source)
            if let draft = item.draft { guess(draft) }
            let bank = item.draft?.bankHint.flatMap { BankDirectory.profile(id: $0)?.name }
            name = [bank, L("\(fields.kind.displayName.loc)通知")].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// 换了原文（粘贴或手动输入）：整理成识别用的写法，原来选中的位置清掉，再用 App 自带的读法猜一下金额和性质
    private func applyText(_ text: String) {
        // 只是选了字、没改原文：选中的位置和圈好的都不动
        guard text != sample else { return }
        let cleaned = MessageParser.cleaned(text, source: .auto)
        guard cleaned != sample else { return }
        sample = cleaned
        selection = NSRange(location: 0, length: 0)
        amount = nil
        cardTail = nil
        counterparty = nil
        errorText = nil
        let parsed = MessageParser.parse(MessageContext(
            text: text, source: .auto, sender: nil, subject: nil, referenceDate: Date(), calendar: .current
        ))
        if let draft = parsed.events.first?.draft { guess(draft) }
    }

    /// 「记到」能选的账户：和截图模板一样，卡和电子钱包
    private var accounts: [Account] {
        store.accounts.filter { !$0.archived && ($0.isCard || $0.cardType == .wallet) }
    }

    /// 收起键盘、离开输入框（输入框交出原文，`applyText`）
    private func endEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// 用通用读法对这条通知的猜测预先填好：金额位置、支出 / 收入 / 转帐
    private func guess(_ draft: EventDraft) {
        let found = NSString(string: sample).range(of: draft.amount.digits)
        if found.location != NSNotFound { amount = found }
        let kind = draft.kind == .other ? nil : draft.kind
        show(kind: kind, direction: draft.direction ?? Self.defaultDirection(draft.kind) ?? transferDirection)
    }

    private func save() async {
        // 光标还在输入框里：先按刚打的原文认一遍
        endEditing()
        guard case .success(let pieces)? = built else {
            if case .failure(let error)? = built { errorText = error.message }
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let (kind, direction) = fields
        let template = MessageTemplate(
            id: existing?.id ?? UUID().uuidString, name: trimmedName.isEmpty ? L("\(kind.displayName.loc)通知") : trimmedName,
            pieces: pieces, kind: kind, direction: direction, createdAt: existing?.createdAt ?? Date(), accountID: accountID
        )
        // 模板至少要认得出原文这条通知
        guard MessageTemplates.match(template, in: sample) != nil else {
            errorText = L("用这个模板认不出这条通知，请换一种选法")
            return
        }
        saving = true
        defer { saving = false }
        do {
            let count = try await store.saveTemplate(template)
            if count > 0 { savedCount = count } else { dismiss() }
        } catch {
            errorText = L("保存失败：\(error.localizedDescription)")
        }
    }

    /// 选来的截图：识别出字，先放进留着的截图里给截图模板的编辑页用（编辑页关掉后删掉，`TemplateImportView`）
    private func readPhoto(_ item: PhotosPickerItem) async {
        readingPhoto = true
        defer { readingPhoto = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw ScreenshotReader.ReadError.unreadable }
            let reading = try await ScreenshotReader.read(data)
            guard let entry = await ScreenshotInbox.save(image: data, reading: reading, ingestID: nil) else { throw ScreenshotReader.ReadError.unreadable }
            errorText = nil
            pickScreenshot?(entry)
        } catch {
            errorText = L("读不出这张图片")
        }
    }

    /// 通知没写明方向时按性质猜；还款、其他猜不出
    private static func defaultDirection(_ kind: TransactionKind) -> FlowDirection? {
        switch kind {
        case .purchase, .transferOut, .interestCharge, .fee, .withdrawal: .outflow
        case .income, .salary, .transferIn, .refund, .deposit, .interestIncome, .reversal: .inflow
        case .repayment, .other: nil
        }
    }
}

/// 识别模板编辑页（通知、截图）类型那一行的选项：支出（可以是退款）、收入、转帐（这张卡转出、转入）合在一个菜单里
enum TemplateEntryChoice: CaseIterable, Hashable {
    case expense, refund, income, transferOut, transferIn

    var title: LocalizedStringKey {
        switch self {
        case .expense: "支出"
        case .refund: "退款（从支出里减掉）"
        case .income: "收入"
        case .transferOut: "转帐 · 这张卡转出"
        case .transferIn: "转帐 · 这张卡转入"
        }
    }

    /// 菜单选的和编辑页的类型、退款、转帐方向互相换算
    static func binding(type: Binding<EntryType>, refund: Binding<Bool>, transferDirection: Binding<FlowDirection>) -> Binding<TemplateEntryChoice> {
        Binding {
            switch type.wrappedValue {
            case .expense: refund.wrappedValue ? .refund : .expense
            case .income: .income
            case .transfer: transferDirection.wrappedValue == .outflow ? .transferOut : .transferIn
            }
        } set: { choice in
            switch choice {
            case .expense: (type.wrappedValue, refund.wrappedValue) = (.expense, false)
            case .refund: (type.wrappedValue, refund.wrappedValue) = (.expense, true)
            case .income: (type.wrappedValue, refund.wrappedValue) = (.income, false)
            case .transferOut: (type.wrappedValue, transferDirection.wrappedValue) = (.transfer, .outflow)
            case .transferIn: (type.wrappedValue, transferDirection.wrappedValue) = (.transfer, .inflow)
            }
        }
    }
}

/// 识别模板编辑页像写邮件的一行：左边灰色的名字，右边直接填、选
struct MailRow<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(minWidth: 44, alignment: .leading)
            content
        }
    }
}

/// 识别模板的原文输入框：像备忘录，直接粘贴、打字。光标离开时把原文交出去（`commit`）重新认；
/// 不在输入时画出圈好的颜色，也能用系统选择手柄选中一段（「用选中的」）。选中范围按 UTF-16 计，与 `NSString` 一致
struct TemplateTextBox: UIViewRepresentable {
    let text: String
    let highlights: [(range: NSRange, color: UIColor)]
    @Binding var selection: NSRange
    @Binding var editing: Bool
    let commit: (String) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = true
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.font = UIFont.preferredFont(forTextStyle: .callout)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        // 正在输入时不动：用户打的字不能被换掉
        guard !view.isFirstResponder else { return }
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: UIFont.preferredFont(forTextStyle: .callout), .foregroundColor: UIColor.label]
        )
        for highlight in highlights where NSMaxRange(highlight.range) <= attributed.length {
            attributed.addAttribute(.backgroundColor, value: highlight.color, range: highlight.range)
        }
        guard view.attributedText != attributed else { return }
        let selected = view.selectedRange
        view.attributedText = attributed
        if NSMaxRange(selected) <= attributed.length { view.selectedRange = selected }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TemplateTextBox

        init(parent: TemplateTextBox) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            // 输入时去掉圈好的颜色，新打的字不会带上底色
            textView.textStorage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: textView.textStorage.length))
            textView.typingAttributes = [.font: UIFont.preferredFont(forTextStyle: .callout), .foregroundColor: UIColor.label]
            parent.editing = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.editing = false
            parent.commit(textView.text)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            if parent.selection != range { parent.selection = range }
        }
    }
}
