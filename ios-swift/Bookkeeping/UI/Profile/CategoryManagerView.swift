import SwiftUI
import BKModel
import BKBackend

/// 「我的 › 分类」：支出、收入、转帐三组。分类全由自己定：增加、删除、改名、换图标、排序，小类可以挪到别的大类下面。
/// 删除时原来的记录回到待分类，记录不删。转帐和系统分类（手续费、扣息）自动记账要用，只能改名、换图标。
///
/// 分类排成和记账页一样的格子（同一个 `CategoryGrid`）：点一下打开分类（只改名称和图标），有小类的先展开；
/// 大类和小类两行最后一格是「添加」；长按拖动排顺序，小类拖到别的大类上就挪进去；长按一浮起来就在旁边弹出删除（样子和系统菜单一样），手指挪开就收起（和 iPhone 主屏幕一样）。
/// 都存进账本，记账页、通知、灵动岛跟着变
struct CategoryManagerView: View {
    @Environment(LedgerStore.self) private var store
    @State private var type: CategoryType = .expense
    @State private var adding: AddTarget?
    @State private var opened: String?
    @State private var arrangement = CategoryArrangement()

    /// 「添加」加到哪：大类（`parentID` 为 nil）或某个大类的小类
    struct AddTarget: Identifiable {
        let parentID: String?
        var id: String { parentID ?? "" }
    }

    var body: some View {
        List {
            Section {
                CategoryGrid(type: type, arrangement: arrangement, add: { adding = AddTarget(parentID: $0) }) { opened = $0 }
            } header: {
                // 放在分组标题的位置：上下只留一点空隙（单独占一个分组时上下各空一大段）
                Picker("类型", selection: $type) {
                    ForEach(CategoryType.allCases, id: \.self) { Text($0.displayName.loc).tag($0) }
                }
                .pickerStyle(.segmented)
                .textCase(nil)
                .listRowInsets(EdgeInsets())
                .padding(.bottom, 8)
            }
        }
        .navigationTitle("分类")
        // 拖动时列表不滚，浮起来的图标盖在整个列表上
        .scrollDisabled(arrangement.active)
        // 长按弹出的菜单和浮起来的图标都盖在整个列表上
        .overlay {
            ZStack {
                CategoryMenuOverlay(arrangement: arrangement)
                CategoryDragOverlay(arrangement: arrangement)
            }
        }
        .onChange(of: type) { arrangement.menu = nil }
        .navigationDestination(item: $opened) { id in
            CategoryDetailView(categoryID: id)
        }
        .sheet(item: $adding) { target in
            NewCategorySheet(type: type, parentID: target.parentID)
        }
        .alert("操作失败", isPresented: Binding(get: { arrangement.failure != nil }, set: { if !$0 { arrangement.failure = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(arrangement.failure ?? "")
        }
    }
}

/// 名称和图标：添加和打开分类共用。图标直接排在下面，点一下就换
private struct CategoryForm: View {
    @Binding var name: String
    @Binding var symbol: String
    @FocusState private var naming: Bool
    var focusName = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    CategoryIcon(symbol: symbol)
                    TextField("名称", text: $name)
                        .focused($naming)
                        .submitLabel(.done)
                }
            }
            Section {
                SymbolGrid(symbol: $symbol)
            }
        }
        .onAppear { if focusName { naming = true } }
    }
}

/// 一个分类：只改名称和图标（小类在分类页上排，删除在分类页上长按）
private struct CategoryDetailView: View {
    let categoryID: String

    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = "tag"
    @State private var loaded = false
    @State private var errorText: String?

    var body: some View {
        if let category = store.categoryTree.category(categoryID) {
            CategoryForm(name: $name, symbol: $symbol)
                .navigationTitle(category.localizedName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存", systemImage: "checkmark") { Task { await save(category) } }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                      || (name == category.localizedName && symbol == category.symbol))
                    }
                }
                .onAppear {
                    guard !loaded else { return }
                    name = category.localizedName
                    symbol = category.symbol
                    loaded = true
                }
                .alert("保存失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(errorText ?? "")
                }
        } else {
            ContentUnavailableView("分类已删除", systemImage: "tag.slash")
        }
    }

    private func save(_ category: LedgerCategory) async {
        do {
            try await store.updateCategory(id: category.id, name: name, symbol: symbol)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// 新增分类：输入名称、点一个图标
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
            CategoryForm(name: $name, symbol: $symbol, focusName: true)
                .navigationTitle(parentID == nil ? "添加大类" : "添加小类")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存", systemImage: "checkmark") { Task { await save() } }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .alert("保存失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(errorText ?? "")
                }
        }
    }

    private func save() async {
        do {
            try await store.addCategory(CategoryDraft(type: type, parentID: parentID, name: name, symbol: symbol))
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
