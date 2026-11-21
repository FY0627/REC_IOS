import SwiftUI
import UIKit
import BKBackend
import BKModel

/// 截图模板的编辑页（ADR 0028）：打开一张留着的截图，识别出的每段字画成框，点框选「金额」「卡号」「对方」，
/// 再和记账一样选支出 / 收入 / 转帐、记到哪个账户，保存。以后同样的页面按这个模板认。
///
/// 模板只保存页面上固定的字和每样东西挨着哪段字（`ScreenTemplates.build`），不保存截图和截图上的数字。
/// 保存后这张截图删掉；没进待处理的这张按模板再记一遍，待处理里同样的截图也按它重新识别。
/// 记到选了账户时，截图上的卡号是转帐的另一边（银行卡转进余额宝这类）
struct ScreenTemplateEditorView: View {
    let entry: ScreenshotInbox.Entry
    /// 保存后按模板把这张截图记上：留着的认不出的截图要记，从相册选来只做模板的不记
    let record: Bool
    private let grid: [[ScreenTextLine]]
    private let text: String

    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var picks: [ScreenTemplateField.Role: ScreenTemplates.Cell] = [:]
    @State private var choosing: ScreenTemplates.Cell?
    @State private var type: EntryType = .expense
    @State private var refund = false
    @State private var transferDirection: FlowDirection = .outflow
    @State private var accountID: String?
    @State private var name = ""
    @State private var errorText: String?
    @State private var saving = false
    @State private var savedCount: Int?

    init(entry: ScreenshotInbox.Entry, record: Bool = true) {
        self.entry = entry
        self.record = record
        grid = ScreenLayout.grid(entry.lines)
        text = ScreenLayout.text(entry.lines)
    }

    var body: some View {
        NavigationStack {
            Form {
                // 和通知模板一样像写邮件：名称、类型、记到排在上面，下面是截图，空着的地方直接点上去填、选
                Section {
                    MailRow("名称") {
                        TextField("模板名称", text: $name)
                    }
                    MailRow("类型") {
                        Picker("类型", selection: TemplateEntryChoice.binding(type: $type, refund: $refund, transferDirection: $transferDirection)) {
                            ForEach(TemplateEntryChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        Spacer(minLength: 0)
                    }
                    MailRow("记到") {
                        Picker("记到", selection: $accountID) {
                            Text(picks[.cardTail] == nil ? L("自动") : L("按截图上的卡号")).tag(String?.none)
                            ForEach(accounts) { account in
                                Text(account.localizedTitle).tag(Optional(account.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        Spacer(minLength: 0)
                    }
                    if let image {
                        ScreenshotBoxes(image: image, grid: grid, picks: picks) { choosing = $0 }
                            .listRowInsets(EdgeInsets())
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    }
                }

                Section("点到的内容") {
                    pickRow(.amount)
                    pickRow(.cardTail)
                    pickRow(.counterparty)
                }

                if let hit = preview {
                    Section("试读") {
                        Text(summary(hit)).font(.footnote)
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .disabled(saving)
            .navigationTitle("做成识别模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") { Task { await save() } }
                        .disabled(picks[.amount] == nil || saving)
                }
            }
            .confirmationDialog(
                choosing.map(cellText) ?? "", isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                titleVisibility: .visible
            ) {
                ForEach(ScreenTemplateField.Role.allCases, id: \.self) { role in
                    Button(Self.title(role)) { assign(role) }
                }
                if let choosing, picks.values.contains(choosing) {
                    Button("不选", role: .destructive) { unassign(choosing) }
                }
            }
            .alert("已保存", isPresented: Binding(get: { savedCount != nil }, set: { if !$0 { savedCount = nil } })) {
                Button("好") { dismiss() }
            } message: {
                Text(savedCount.map { L("有 \($0) 张截图按这个模板重新识别。") } ?? "")
            }
            .task {
                guard image == nil else { return }
                image = await Self.loadImage(entry.id)
                if image == nil { errorText = L("读不出这张图片") }
            }
        }
    }

    // MARK: 点到的内容

    static func title(_ role: ScreenTemplateField.Role) -> LocalizedStringKey {
        switch role {
        case .amount: "金额"
        case .cardTail: "卡号"
        case .counterparty: "对方"
        }
    }

    static func tint(_ role: ScreenTemplateField.Role) -> Color {
        switch role {
        case .amount: .green
        case .cardTail: .blue
        case .counterparty: .orange
        }
    }

    private func pickRow(_ role: ScreenTemplateField.Role) -> some View {
        HStack(spacing: 12) {
            Circle().fill(Self.tint(role).opacity(0.6)).frame(width: 10, height: 10).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(role))
                Text(picks[role].map(cellText) ?? (role == .amount ? L("必选") : L("可不选")))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let cell = picks[role] {
                Button("清除", systemImage: "xmark.circle.fill") { unassign(cell) }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
            }
        }
    }

    private func cellText(_ cell: ScreenTemplates.Cell) -> String {
        guard grid.indices.contains(cell.row), grid[cell.row].indices.contains(cell.column) else { return "" }
        return grid[cell.row][cell.column].text
    }

    /// 一段只能是一样东西；同一样东西换到新点的这段
    private func assign(_ role: ScreenTemplateField.Role) {
        guard let cell = choosing else { return }
        for (other, picked) in picks where picked == cell { picks[other] = nil }
        picks[role] = cell
        choosing = nil
        check()
        if role == .amount { guessType() }
    }

    private func unassign(_ cell: ScreenTemplates.Cell) {
        for (role, picked) in picks where picked == cell { picks[role] = nil }
        choosing = nil
        check()
    }

    private func check() {
        errorText = nil
        if case .failure(let error)? = built, error != .missingAmount { errorText = error.message.loc }
    }

    /// 点到的金额前面写了「+」是收进来的，「-」是付出去的
    private func guessType() {
        guard let cell = picks[.amount] else { return }
        let text = cellText(cell).trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("+") { type = .income } else if text.hasPrefix("-") || text.hasPrefix("−") { type = .expense }
    }

    // MARK: 模板

    private var accounts: [Account] {
        store.accounts.filter { !$0.archived && ($0.isCard || $0.cardType == .wallet) }
    }

    private var built: Result<(anchors: [String], fields: [ScreenTemplateField]), ScreenTemplates.BuildError>? {
        guard !picks.isEmpty else { return nil }
        return ScreenTemplates.build(text: text, picks: picks)
    }

    private var template: ScreenTemplate? {
        guard case .success(let parts)? = built else { return nil }
        let (kind, direction) = MessageTemplate.fields(type: type, refund: refund, transferDirection: transferDirection, keeping: nil)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScreenTemplate(
            id: entry.id, name: trimmed.isEmpty ? L("截图模板") : trimmed, anchors: parts.anchors, fields: parts.fields,
            kind: kind, direction: direction, accountID: accountID, createdAt: Date()
        )
    }

    /// 用这个模板读这张截图读出来的
    private var preview: ScreenTemplates.Hit? {
        template.flatMap { ScreenTemplates.match($0, text: text) }
    }

    private func summary(_ hit: ScreenTemplates.Hit) -> String {
        var parts = [L("金额 \(hit.amount.digits)")]
        if let tail = hit.cardTail { parts.append(L("尾号 \(tail)")) }
        if let counterparty = hit.counterparty { parts.append(counterparty) }
        return parts.joined(separator: " · ")
    }

    private func save() async {
        if case .failure(let error)? = built {
            errorText = error.message.loc
            return
        }
        guard let template, preview != nil else {
            errorText = L("用这个模板认不出这张截图，请换一种点法")
            return
        }
        saving = true
        defer { saving = false }
        do {
            let count = try await store.saveScreenTemplate(template, from: entry, record: record)
            if count > 0 { savedCount = count } else { dismiss() }
        } catch {
            errorText = L("保存失败：\(error.localizedDescription)")
        }
    }

    /// 长边解到 2400 像素就够看清字，不按原尺寸读进内存
    private static func loadImage(_ id: String) async -> UIImage? {
        await ScreenshotInbox.thumbnail(id, maxPixel: 2400)
    }
}

/// 截图和上面识别出的每段字的框：点到的按颜色填上，点框交回第几行第几段
private struct ScreenshotBoxes: View {
    let image: UIImage
    let grid: [[ScreenTextLine]]
    let picks: [ScreenTemplateField.Role: ScreenTemplates.Cell]
    let tap: (ScreenTemplates.Cell) -> Void

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .overlay {
                GeometryReader { geometry in
                    let size = geometry.size
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, item in
                        let line = item.line
                        let role = picks.first { $0.value == item.cell }?.key
                        RoundedRectangle(cornerRadius: 3)
                            .fill(role.map { ScreenTemplateEditorView.tint($0).opacity(0.35) } ?? Color.clear)
                            .overlay {
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(role.map { ScreenTemplateEditorView.tint($0) } ?? Color.accentColor.opacity(0.5), lineWidth: 1)
                            }
                            .frame(width: max(line.width * size.width, 12) + 4, height: max(line.height * size.height, 12) + 4)
                            .contentShape(Rectangle())
                            .position(x: (line.x + line.width / 2) * size.width, y: (line.y + line.height / 2) * size.height)
                            .onTapGesture { tap(item.cell) }
                            .accessibilityLabel(line.text)
                            .accessibilityAddTraits(.isButton)
                    }
                }
            }
    }

    private var cells: [(cell: ScreenTemplates.Cell, line: ScreenTextLine)] {
        grid.enumerated().flatMap { r, row in
            row.enumerated().map { c, line in (ScreenTemplates.Cell(row: r, column: c), line) }
        }
    }
}
