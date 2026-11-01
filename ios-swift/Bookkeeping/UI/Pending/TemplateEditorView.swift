import SwiftUI
import UIKit
import BKBackend
import BKModel

/// 识别模板的编辑页（和记一笔一样是弹出的表单）：新添加、改已有的、或用一条待处理的通知做。
/// 原文可以粘贴或手动改；在原文里选中金额（必选）、尾号、对方，和记账一样选支出 / 收入 / 转帐，保存。
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
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var sample = ""
    @State private var editingText = false
    @State private var draftText = ""
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var amount: NSRange?
    @State private var cardTail: NSRange?
    @State private var counterparty: NSRange?
    @State private var type: EntryType = .expense
    @State private var refund = false
    @State private var transferDirection: FlowDirection = .outflow
    /// 原来的交易性质（改已有的模板、用通知猜的）
    @State private var originalKind: TransactionKind?
    @State private var name = ""
    @State private var errorText: String?
    @State private var saving = false
    @State private var savedCount: Int?
    @State private var loaded = false

    init(item: PendingItem) { origin = .pending(item) }
    init(template: MessageTemplate?) { origin = template.map(Origin.existing) ?? .new }

    private enum Mark {
        case amount, cardTail, counterparty
    }

    private var existing: MessageTemplate? {
        if case .existing(let template) = origin { return template }
        return nil
    }

    private var title: String {
        switch origin {
        case .new: "添加识别模板"
        case .existing: "编辑识别模板"
        case .pending: "做成识别模板"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("模板名称", text: $name)
                }

                Section {
                    Picker("类型", selection: $type) {
                        ForEach(EntryType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if type == .expense {
                        Toggle("退款（从支出里减掉）", isOn: $refund)
                    }
                    if type == .transfer {
                        Picker("这张卡", selection: $transferDirection) {
                            Text("转出").tag(FlowDirection.outflow)
                            Text("转入").tag(FlowDirection.inflow)
                        }
                    }
                }

                Section("通知原文") {
                    if editingText {
                        TextEditor(text: $draftText)
                            .frame(minHeight: 160)
                        Button("完成") { applyText(draftText) }
                    } else {
                        if sample.isEmpty {
                            Text("粘贴一条收到的短信或邮件").foregroundStyle(.secondary)
                        } else {
                            SelectableText(text: sample, highlights: highlights, selection: $selection)
                                .frame(height: 200)
                        }
                        HStack {
                            PasteButton(payloadType: String.self) { strings in
                                guard let text = strings.first else { return }
                                Task { @MainActor in applyText(text) }
                            }
                            .labelStyle(.titleAndIcon)
                            Spacer()
                            Button("手动输入") {
                                draftText = sample
                                editingText = true
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                if !sample.isEmpty, !editingText {
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
                if let existing {
                    Section {
                        Menu {
                            Button("删除这个模板", systemImage: "trash", role: .destructive) { Task { await delete(existing) } }
                        } label: {
                            ActionLabel(title: "删除").foregroundStyle(Color.red)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") { Task { await save() } }
                        .disabled(amount == nil || saving || editingText)
                }
            }
            .onAppear(perform: setup)
            .alert("已保存", isPresented: Binding(get: { savedCount != nil }, set: { if !$0 { savedCount = nil } })) {
                Button("好") { dismiss() }
            } message: {
                Text(savedCount.map { "待处理里有 \($0) 条通知按这个模板重新识别。" } ?? "")
            }
        }
    }

    private func markRow(_ title: String, mark: Mark, range: NSRange?, tint: Color, required: Bool) -> some View {
        HStack(spacing: 12) {
            Circle().fill(tint.opacity(0.6)).frame(width: 10, height: 10).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(range.map(substring) ?? (required ? "必选" : "可不选"))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if range != nil {
                Button("清除", systemImage: "xmark.circle.fill") { set(mark, nil) }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
            }
            Button("用选中的") { set(mark, selection) }
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
            name = template.name
        case .pending(let item):
            sample = MessageParser.cleaned(item.rawText ?? "", source: item.source)
            if let draft = item.draft { guess(draft) }
            let bank = item.draft?.bankHint.flatMap { BankDirectory.profile(id: $0)?.name }
            name = [bank, fields.kind.displayName + "通知"].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// 换了原文（粘贴或手动输入）：整理成识别用的写法，原来选中的位置清掉，再用 App 自带的读法猜一下金额和性质
    private func applyText(_ text: String) {
        editingText = false
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

    /// 用通用读法对这条通知的猜测预先填好：金额位置、支出 / 收入 / 转帐
    private func guess(_ draft: EventDraft) {
        let found = NSString(string: sample).range(of: draft.amount.digits)
        if found.location != NSNotFound { amount = found }
        let kind = draft.kind == .other ? nil : draft.kind
        show(kind: kind, direction: draft.direction ?? Self.defaultDirection(draft.kind) ?? transferDirection)
    }

    private func save() async {
        guard case .success(let pieces)? = built else {
            if case .failure(let error)? = built { errorText = error.message }
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let (kind, direction) = fields
        let template = MessageTemplate(
            id: existing?.id ?? UUID().uuidString, name: trimmedName.isEmpty ? kind.displayName + "通知" : trimmedName,
            pieces: pieces, kind: kind, direction: direction, createdAt: existing?.createdAt ?? Date()
        )
        // 模板至少要认得出原文这条通知
        guard MessageTemplates.match(template, in: sample) != nil else {
            errorText = "用这个模板认不出这条通知，请换一种选法"
            return
        }
        saving = true
        defer { saving = false }
        do {
            let count = try await store.saveTemplate(template)
            if count > 0 { savedCount = count } else { dismiss() }
        } catch {
            errorText = "保存失败：\(error)"
        }
    }

    private func delete(_ template: MessageTemplate) async {
        do {
            try await store.deleteTemplate(id: template.id)
            dismiss()
        } catch {
            errorText = "删除失败：\(error)"
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

/// 只读、可以用系统选择手柄选中的原文。选中范围按 UTF-16 计，与 `NSString` 一致。
struct SelectableText: UIViewRepresentable {
    let text: String
    let highlights: [(range: NSRange, color: UIColor)]
    @Binding var selection: NSRange

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
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
        var parent: SelectableText

        init(parent: SelectableText) {
            self.parent = parent
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            if parent.selection != range { parent.selection = range }
        }
    }
}
