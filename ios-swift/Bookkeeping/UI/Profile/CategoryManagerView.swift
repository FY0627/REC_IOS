import SwiftUI
import BKModel
import BKBackend

/// 「我的 › 分类」：支出、收入、转帐三组。分类全由自己定：增加、删除、改名、换图标、排序、隐藏，
/// 小类可以挪到别的大类下面，两个分类可以合并。删除时选原来的记录改记到哪；不选就回到待分类，记录不删。
/// 转帐和系统分类（手续费、扣息）自动记账要用，只能改名、换图标。
struct CategoryManagerView: View {
    @Environment(LedgerStore.self) private var store
    @State private var type: CategoryType = .expense
    @State private var adding = false
    @State private var errorText: String?

    var body: some View {
        let nodes = store.categoryTree.nodes(type, includeHidden: true)
        List {
            Section {
                ForEach(nodes) { node in
                    NavigationLink {
                        CategoryDetailView(categoryID: node.id)
                    } label: {
                        CategoryManagerRow(category: node.category, childCount: node.children.count)
                    }
                }
                .onMove { from, to in
                    var ids = nodes.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    Task { await run { try await store.reorderCategories(ids) } }
                }
                if type != .transfer {
                    Button("添加大类", systemImage: "plus") { adding = true }
                }
            } header: {
                // 放在分组标题的位置：上下只留一点空隙（单独占一个分组时上下各空一大段）
                Picker("类型", selection: $type) {
                    ForEach(CategoryType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .textCase(nil)
                .listRowInsets(EdgeInsets())
                .padding(.bottom, 8)
            }
            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }
        }
        .navigationTitle("分类")
        .toolbar { EditButton() }
        .sheet(isPresented: $adding) {
            NewCategorySheet(type: type, parentID: nil)
        }
    }

    private func run(_ action: () async throws -> Void) async {
        do {
            try await action()
            errorText = nil
        } catch {
            errorText = "操作失败：\(error.localizedDescription)"
        }
    }
}

private struct CategoryManagerRow: View {
    let category: LedgerCategory
    var childCount = 0

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(symbol: category.symbol)
            Text(category.name).foregroundStyle(category.hidden ? Color.secondary : Color.primary)
            Spacer()
            if category.hidden {
                Text("已隐藏").font(.footnote).foregroundStyle(.secondary)
            } else if category.locked {
                Image(systemName: "lock").font(.footnote).foregroundStyle(.secondary)
            } else if childCount > 0 {
                Text("\(childCount) 个小类").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// 一个分类：改名、换图标、隐藏；大类管理它的小类；挪到别的大类、合并、删除
private struct CategoryDetailView: View {
    let categoryID: String

    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = "tag"
    @State private var loaded = false
    @State private var addingChild = false
    @State private var errorText: String?

    var body: some View {
        if let category = store.categoryTree.category(categoryID) {
            form(category)
        } else {
            ContentUnavailableView("分类已删除", systemImage: "tag.slash")
        }
    }

    private func form(_ category: LedgerCategory) -> some View {
        let children = store.categoryTree.all.filter { $0.parentID == category.id }.sorted { $0.sortOrder < $1.sortOrder }
        return Form {
            Section {
                TextField("名称", text: $name)
                NavigationLink {
                    SymbolPicker(symbol: $symbol)
                } label: {
                    LabeledContent("图标") { Image(systemName: symbol).foregroundStyle(Color.primary) }
                }
                if category.type != .transfer {
                    Toggle("隐藏（记账时不出现）", isOn: Binding(
                        get: { category.hidden },
                        set: { hidden in Task { await run { try await store.setCategoryHidden(id: category.id, hidden: hidden) } } }
                    ))
                }
            }
            if category.isTopLevel, category.type != .transfer, !category.locked {
                Section("小类") {
                    ForEach(children) { child in
                        NavigationLink {
                            CategoryDetailView(categoryID: child.id)
                        } label: {
                            CategoryManagerRow(category: child)
                        }
                    }
                    .onMove { from, to in
                        var ids = children.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        Task { await run { try await store.reorderCategories(ids) } }
                    }
                    Button("添加小类", systemImage: "plus") { addingChild = true }
                }
            }
            if !category.locked {
                Section {
                    if children.isEmpty {
                        NavigationLink("挪到其他大类下面") {
                            CategoryTargetList(title: "挪到", type: category.type, excluding: category.id, topLevelOnly: true,
                                               allowNone: !category.isTopLevel, noneTitle: "单独作为大类") { target in
                                Task { await run { try await store.moveCategory(id: category.id, toParent: target) } }
                            }
                        }
                    }
                    NavigationLink("合并到其他分类") {
                        CategoryTargetList(title: "合并到", type: category.type, excluding: category.id, topLevelOnly: false,
                                           allowNone: false, noneTitle: "") { target in
                            guard let target else { return }
                            Task {
                                await run { try await store.mergeCategory(id: category.id, into: target) }
                                dismiss()
                            }
                        }
                    }
                    deleteMenu(category)
                }
            }
            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", systemImage: "checkmark") {
                    Task { await run { try await store.updateCategory(id: category.id, name: name, symbol: symbol) } }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (name == category.name && symbol == category.symbol))
            }
        }
        .onAppear {
            guard !loaded else { return }
            name = category.name
            symbol = category.symbol
            loaded = true
        }
        .sheet(isPresented: $addingChild) {
            NewCategorySheet(type: category.type, parentID: category.id)
        }
    }

    /// 删除：在按钮旁边弹出小菜单，选原来的记录改记到哪（或回到待分类），选了就删。记录不删
    private func deleteMenu(_ category: LedgerCategory) -> some View {
        Menu {
            Section(category.isTopLevel ? "连小类一起删除，原来的记录改记到" : "删除后，原来的记录改记到") {
                Button("回到待分类", systemImage: "tray", role: .destructive) { Task { await delete(category, moveTo: nil) } }
                ForEach(deleteTargets(category)) { target in
                    Button(target.name) { Task { await delete(category, moveTo: target.id) } }
                }
            }
        } label: {
            ActionLabel(title: "删除这个分类").foregroundStyle(Color.red)
        }
    }

    /// 可以改记到的分类：同一类型，除了它自己和它的小类；小类名称前写上大类
    private func deleteTargets(_ category: LedgerCategory) -> [DeleteTarget] {
        store.categoryTree.nodes(category.type).filter { $0.id != category.id }.flatMap { node in
            [DeleteTarget(id: node.id, name: node.category.name)]
                + node.children.filter { $0.id != category.id }.map { DeleteTarget(id: $0.id, name: "\(node.category.name) · \($0.name)") }
        }
    }

    private struct DeleteTarget: Identifiable {
        let id: String
        let name: String
    }

    private func delete(_ category: LedgerCategory, moveTo target: String?) async {
        do {
            try await store.deleteCategory(id: category.id, moveRecordsTo: target)
            dismiss()
        } catch {
            errorText = "删除失败：\(error.localizedDescription)"
        }
    }

    private func run(_ action: () async throws -> Void) async {
        do {
            try await action()
            errorText = nil
        } catch {
            errorText = "操作失败：\(error.localizedDescription)"
        }
    }
}

/// 选一个目标分类（挪到哪个大类、合并到哪、删除后记录改记到哪）
private struct CategoryTargetList: View {
    let title: String
    let type: CategoryType
    let excluding: String
    let topLevelOnly: Bool
    let allowNone: Bool
    let noneTitle: String
    let choose: (String?) -> Void

    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if allowNone {
                Button(noneTitle) {
                    choose(nil)
                    dismiss()
                }
            }
            ForEach(store.categoryTree.nodes(type).filter { $0.id != excluding && !(topLevelOnly && $0.category.locked) }) { node in
                row(node.category, indent: false)
                if !topLevelOnly {
                    ForEach(node.children.filter { $0.id != excluding }) { child in row(child, indent: true) }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ category: LedgerCategory, indent: Bool) -> some View {
        Button {
            choose(category.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                CategoryIcon(symbol: category.symbol)
                Text(category.name).foregroundStyle(Color.primary)
            }
            .padding(.leading, indent ? 28 : 0)
        }
    }
}

/// 新增分类：名称和图标
struct NewCategorySheet: View {
    let type: CategoryType
    let parentID: String?

    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = "tag"
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $name)
                NavigationLink {
                    SymbolPicker(symbol: $symbol)
                } label: {
                    LabeledContent("图标") { Image(systemName: symbol).foregroundStyle(Color.primary) }
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
            }
            .navigationTitle(parentID == nil ? "添加大类" : "添加小类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() async {
        do {
            try await store.addCategory(CategoryDraft(type: type, parentID: parentID, name: name, symbol: symbol))
            dismiss()
        } catch {
            errorText = "保存失败：\(error.localizedDescription)"
        }
    }
}

