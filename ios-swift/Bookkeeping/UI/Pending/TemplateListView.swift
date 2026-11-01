import SwiftUI
import BKModel

/// 「我的 › 自动记账 › 识别模板」：自己做的模板。右上角「+」添加，点一个模板编辑，往左滑删除。
/// 收到通知时先用这些模板认（新做的在前），都认不出再用 App 自带的读法。
struct TemplateListView: View {
    @Environment(LedgerStore.self) private var store
    @State private var templates: [MessageTemplate] = []
    @State private var loaded = false
    @State private var editing: EditorTarget?

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
            if templates.isEmpty && loaded {
                Text("还没有识别模板").foregroundStyle(.secondary)
            }
            ForEach(templates) { template in
                Button {
                    editing = .existing(template)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(template.name).font(.headline).foregroundStyle(Color.primary)
                        Text("\(template.kind.displayName) · \(template.direction.displayName)")
                            .font(.subheadline).foregroundStyle(Color.secondary)
                        Text(template.preview)
                            .font(.caption).foregroundStyle(Color.secondary).lineLimit(3)
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { templates[$0].id }
                Task {
                    for id in ids { try? await store.deleteTemplate(id: id) }
                    await reload()
                }
            }
        }
        .navigationTitle("识别模板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("添加", systemImage: "plus") { editing = .new }
            }
        }
        .sheet(item: $editing, onDismiss: { Task { await reload() } }) { target in
            TemplateEditorView(template: target.template)
        }
        .task { await reload() }
    }

    private func reload() async {
        templates = await store.templates()
        loaded = true
    }
}
