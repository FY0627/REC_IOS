import SwiftUI
import BKModel

/// 「我的 › 自动记账 › 识别模板」：自己做的模板。右上角「导入」：同一个页面里粘贴一条通知，或者从相册选一张截图点出金额（ADR 0028）；
/// 点一个通知模板编辑，往左滑删除。截图模板没有存截图，平时不能编辑，只能往左滑删除；
/// 「开发与调试」里打开「编辑截图模板」后，存了版面骨架的截图模板点开照骨架编辑。
/// 收到通知、截图时先用这些模板认（新做的在前），都认不出再用 App 自带的读法。
struct TemplateListView: View {
    @Environment(LedgerStore.self) private var store
    @State private var templates: [MessageTemplate] = []
    @State private var screenTemplates: [ScreenTemplate] = []
    @State private var loaded = false
    @State private var editing: EditorTarget?
    /// 导入时从相册选来做模板的截图：先放进留着的截图里给编辑页用，编辑页关掉后删掉
    @State private var pickedID: String?
    /// 左滑点了「删除」、正在确认的模板
    @State private var deletingID: String?
    /// 照版面骨架编辑的截图模板（「开发与调试」里打开）
    @State private var editingScreen: ScreenTemplate?
    @AppStorage(ScreenTemplateEditorView.editingEnabledKey) private var screenEditing = false

    /// 弹出的编辑页：新添加，或者改一个已有的
    private enum EditorTarget: Identifiable {
        case new
        case existing(MessageTemplate)

        var id: String {
            switch self {
            case .new: "new"
            case .existing(let template): template.id
            }
        }

        var template: MessageTemplate? {
            if case .existing(let template) = self { return template }
            return nil
        }
    }

    var body: some View {
        List {
            if templates.isEmpty && screenTemplates.isEmpty && loaded {
                Text("还没有识别模板").foregroundStyle(.secondary)
            }
            if !templates.isEmpty {
                Section {
                    ForEach(templates) { template in
                        Group {
                            // 流水上点「不记」记下的写法：没有圈出的金额，不能编辑，只能往左滑删除
                            if template.isSkip {
                                row(template)
                            } else {
                                Button {
                                    editing = .existing(template)
                                } label: {
                                    row(template)
                                }
                            }
                        }
                        .modifier(TemplateSwipe(id: template.id, deleting: $deletingID) {
                            Task {
                                try? await store.deleteTemplate(id: template.id)
                                await reload()
                            }
                        })
                    }
                } header: {
                    if !screenTemplates.isEmpty { Text("通知") }
                }
            }
            if !screenTemplates.isEmpty {
                Section("截图") {
                    ForEach(screenTemplates) { template in
                        Group {
                            if screenEditing, template.layout != nil {
                                Button {
                                    editingScreen = template
                                } label: {
                                    screenRow(template)
                                }
                            } else {
                                screenRow(template)
                            }
                        }
                        .modifier(TemplateSwipe(id: template.id, deleting: $deletingID) {
                            Task {
                                try? await store.deleteScreenTemplate(id: template.id)
                                await reload()
                            }
                        })
                    }
                }
            }
        }
        .navigationTitle("识别模板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("导入", systemImage: "plus") { editing = .new }
            }
        }
        .sheet(item: $editing, onDismiss: {
            Task {
                // 选了截图、没保存就关掉的：这张截图不留（保存了的已经删了）
                if let id = pickedID { await ScreenshotInbox.delete(id) }
                pickedID = nil
                await reload()
            }
        }) { target in
            if let template = target.template {
                TemplateEditorView(template: template)
            } else {
                TemplateImportView(pickedID: $pickedID)
            }
        }
        .sheet(item: $editingScreen, onDismiss: { Task { await reload() } }) { template in
            if let layout = template.layout {
                ScreenTemplateEditorView(template: template, layout: layout)
            }
        }
        .task { await reload() }
    }

    private func screenRow(_ template: ScreenTemplate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(template.name).font(.headline).foregroundStyle(Color.primary)
            Text("\(template.kind.displayName.loc) · \(template.direction.displayName.loc)")
                .font(.subheadline).foregroundStyle(Color.secondary)
            Text(template.preview).font(.caption).foregroundStyle(Color.secondary).lineLimit(2)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func row(_ template: MessageTemplate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(template.name).font(.headline).foregroundStyle(Color.primary)
            Text(template.isSkip ? L("不记") : "\(template.kind.displayName.loc) · \(template.direction.displayName.loc)")
                .font(.subheadline).foregroundStyle(Color.secondary)
            Text(template.preview)
                .font(.caption).foregroundStyle(Color.secondary).lineLimit(3)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func reload() async {
        templates = await store.templates()
        screenTemplates = await store.screenTemplates()
        loaded = true
    }
}

/// 「识别模板 › 导入」：先是通知模板的编辑页（粘贴、手动输入），在里面从相册选了截图就换成截图模板的编辑页（ADR 0028）。
/// 选来的截图只做模板、不记账；它的标识交回列表，编辑页关掉后删掉
private struct TemplateImportView: View {
    @Binding var pickedID: String?
    @State private var entry: ScreenshotInbox.Entry?

    var body: some View {
        if let entry {
            ScreenTemplateEditorView(entry: entry, record: false)
        } else {
            TemplateEditorView(template: nil) { picked in
                pickedID = picked.id
                entry = picked
            }
        }
    }
}

/// 模板的左滑删除：和首页的流水、管理账户一样，左滑露出「删除」，点了从这一行右端弹出系统的确认菜单；
/// 换成同样颜色的行背景，滑动时这一行不变灰、四个角不变圆
private struct TemplateSwipe: ViewModifier {
    let id: String
    @Binding var deleting: String?
    let delete: () -> Void

    func body(content: Content) -> some View {
        content
            .background(alignment: .trailing) {
                if deleting == id {
                    DeleteMenuAnchor(warning: L("删除后不能恢复"), action: L("删除这个模板")) {
                        delete()
                    } onEnd: {
                        deleting = nil
                    }
                    .frame(width: 76)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // 不用 .destructive：那样一点就先把这一行划走，确认前就不见了
                Button("删除", systemImage: "trash") { deleting = id }
                    .tint(.red)
            }
            .listRowBackground(Color(.secondarySystemGroupedBackground))
    }
}
