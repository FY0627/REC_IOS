import SwiftUI
import UIKit
import BKBackend
import BKModel

/// 截图模板的编辑页（ADR 0028）：打开一张留着的截图，识别出的每段字画成框，点框选「金额」「卡号」「对方」，
/// 再和记账一样选支出 / 收入 / 转帐、记到哪个账户，保存。以后同样的页面按这个模板认。
///
/// 模板只保存页面上固定的字和每样东西挨着哪段字（`ScreenTemplates.build`），不保存截图和截图上的数字。
/// 另存一份版面骨架（每段字和位置，数字换成示例，`ScreenTemplates.skeleton`），之后照着它画出页面来改这个模板。
/// 保存后这张截图删掉；没进待处理的这张按模板再记一遍，待处理里同样的截图也按它重新识别。
/// 记到选了账户时，截图上的卡号是转帐的另一边（银行卡转进余额宝这类）
struct ScreenTemplateEditorView: View {
    /// 打开的是什么：留着的截图做新模板，或者照版面骨架改一个做好的模板（「开发与调试」里打开）
    enum Source {
        /// `record`：保存后按模板把这张截图记上。留着的认不出的截图要记，从相册选来只做模板的不记
        case screenshot(ScreenshotInbox.Entry, record: Bool)
        case template(ScreenTemplate, ScreenTemplateLayout)
    }

    /// 「开发与调试」里的开关：打开后点识别模板列表里的截图模板可以编辑
    static let editingEnabledKey = "devEditScreenTemplates"

    let source: Source
    private let lines: [ScreenTextLine]
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
    @State private var loaded = false
    /// 改做好的模板时原来的交易性质：类型没换就保留（和通知模板一样）
    @State private var originalKind: TransactionKind?

    init(entry: ScreenshotInbox.Entry, record: Bool = true) {
        self.init(source: .screenshot(entry, record: record), lines: entry.lines)
    }

    init(template: ScreenTemplate, layout: ScreenTemplateLayout) {
        self.init(source: .template(template, layout), lines: layout.lines)
    }

    private init(source: Source, lines: [ScreenTextLine]) {
        self.source = source
        self.lines = lines
        grid = ScreenLayout.grid(lines)
        text = ScreenLayout.text(lines)
    }

    private var existing: ScreenTemplate? {
        if case .template(let template, _) = source { return template }
        return nil
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
                    switch source {
                    case .screenshot:
                        if let image {
                            boxes(.image(image))
                        } else {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                        }
                    case .template(_, let layout):
                        boxes(.skeleton(aspect: layout.aspect))
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
            .navigationTitle(existing == nil ? "做成识别模板" : "编辑识别模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") { Task { await save() } }
                        .disabled(picks[.amount] == nil || saving)
                }
            }
            .alert("已保存", isPresented: Binding(get: { savedCount != nil }, set: { if !$0 { savedCount = nil } })) {
                Button("好") { dismiss() }
            } message: {
                Text(savedCount.map { L("有 \($0) 张截图按这个模板重新识别。") } ?? "")
            }
            .onAppear(perform: setup)
            .task {
                guard case .screenshot(let entry, _) = source, image == nil else { return }
                image = await Self.loadImage(entry.id)
                if image == nil { errorText = L("读不出这张图片") }
            }
        }
    }

    // MARK: 点到的内容

    /// 截图（或版面骨架）和上面的框；点框弹出的菜单挂在这个框上，从它旁边弹出
    private func boxes(_ page: ScreenshotBoxes.Page) -> some View {
        ScreenshotBoxes(page: page, grid: grid, picks: picks, choosing: $choosing, assign: assign, unassign: unassign)
            .listRowInsets(EdgeInsets())
    }

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
        let (kind, direction) = MessageTemplate.fields(type: type, refund: refund, transferDirection: transferDirection, keeping: originalKind)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = switch source {
        case .screenshot(let entry, _): entry.id
        case .template(let template, _): template.id
        }
        return ScreenTemplate(
            id: id, name: trimmed.isEmpty ? L("截图模板") : trimmed, anchors: parts.anchors, fields: parts.fields,
            kind: kind, direction: direction, accountID: accountID, createdAt: existing?.createdAt ?? Date()
        )
    }

    /// 存进模板的版面骨架（保存时才算）：截图按原图的宽高比，改模板时照旧
    private func layout(for template: ScreenTemplate) -> ScreenTemplateLayout? {
        let aspect: Double? = switch source {
        case .screenshot: image.flatMap { $0.size.height > 0 ? $0.size.width / $0.size.height : nil }
        case .template(_, let layout): layout.aspect
        }
        return aspect.map { ScreenTemplates.skeleton(lines, picks: picks, fields: template.fields, aspect: $0) }
    }

    /// 改做好的模板：照骨架找回原来点的几段，类型、记到、名称照旧
    private func setup() {
        guard !loaded, let existing else { return }
        loaded = true
        picks = ScreenTemplates.picks(for: existing, in: text)
        let entry = MessageTemplate.entry(kind: existing.kind, direction: existing.direction)
        type = entry.type
        refund = entry.refund
        transferDirection = existing.direction
        originalKind = existing.kind
        accountID = existing.accountID
        name = existing.name
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
        guard var template, preview != nil else {
            errorText = L("用这个模板认不出这张截图，请换一种点法")
            return
        }
        template.layout = layout(for: template)
        saving = true
        defer { saving = false }
        do {
            let count: Int
            switch source {
            case .screenshot(let entry, let record): count = try await store.saveScreenTemplate(template, from: entry, record: record)
            case .template: count = try await store.updateScreenTemplate(template)
            }
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

/// 截图和上面识别出的每段字的框：点到的按颜色填上，点框交回第几行第几段。
/// 改做好的模板时没有截图，画一张空白的页面，每个框里写上骨架里的字
private struct ScreenshotBoxes: View {
    enum Page {
        case image(UIImage)
        /// 版面骨架：截图的宽 / 高
        case skeleton(aspect: Double)
    }

    let page: Page
    let grid: [[ScreenTextLine]]
    let picks: [ScreenTemplateField.Role: ScreenTemplates.Cell]
    /// 点了哪个框、正在选它是什么
    @Binding var choosing: ScreenTemplates.Cell?
    let assign: (ScreenTemplateField.Role) -> Void
    let unassign: (ScreenTemplates.Cell) -> Void

    private var isSkeleton: Bool {
        if case .skeleton = page { return true }
        return false
    }

    @ViewBuilder private var background: some View {
        switch page {
        case .image(let image):
            Image(uiImage: image).resizable().scaledToFit()
        case .skeleton(let aspect):
            Rectangle().fill(Color(.systemBackground)).aspectRatio(max(aspect, 0.1), contentMode: .fit)
        }
    }

    var body: some View {
        background
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
                            .overlay {
                                if isSkeleton {
                                    Text(verbatim: line.text)
                                        .font(.system(size: max(line.height * size.height * 0.72, 6)))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.3)
                                        .foregroundStyle(role == nil ? Color.secondary : Color.primary)
                                        .padding(.horizontal, 2)
                                }
                            }
                            .frame(width: max(line.width * size.width, 12) + 4, height: max(line.height * size.height, 12) + 4)
                            .contentShape(Rectangle())
                            .onTapGesture { choosing = item.cell }
                            // 菜单挂在框上（不挂在整页上），iOS 26 从这个框旁边弹出
                            .confirmationDialog(line.text, isPresented: presenting(item.cell), titleVisibility: .visible) {
                                ForEach(ScreenTemplateField.Role.allCases, id: \.self) { option in
                                    Button(ScreenTemplateEditorView.title(option)) { assign(option) }
                                }
                                if role != nil {
                                    Button("不选", role: .destructive) { unassign(item.cell) }
                                }
                            }
                            .accessibilityLabel(line.text)
                            .accessibilityAddTraits(.isButton)
                            .position(x: (line.x + line.width / 2) * size.width, y: (line.y + line.height / 2) * size.height)
                    }
                }
            }
    }

    private func presenting(_ cell: ScreenTemplates.Cell) -> Binding<Bool> {
        Binding {
            choosing == cell
        } set: { shown in
            if !shown, choosing == cell { choosing = nil }
        }
    }

    private var cells: [(cell: ScreenTemplates.Cell, line: ScreenTextLine)] {
        grid.enumerated().flatMap { r, row in
            row.enumerated().map { c, line in (ScreenTemplates.Cell(row: r, column: c), line) }
        }
    }
}
