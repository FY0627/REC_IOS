import SwiftUI
import BKModel

/// 列表里对一笔流水的滑动操作：左滑露出「编辑」「删除」，删除要先确认。
/// 首页、统计是系统列表（`.recordSwipe`）；卡片详情的列表是 UIKit，手势在 `WalletDetailList`。
/// 两边都只是写这里的状态，打开编辑、确认删除由页面上的 `.recordSwipeHost` 处理。
struct RecordSwipeState {
    var editing: RecordRow?
    var deleting: RecordRow?
}

extension View {
    /// 放在列表的一行上
    func recordSwipe(_ row: RecordRow, state: Binding<RecordSwipeState>) -> some View {
        modifier(RecordSwipeActions(row: row, state: state))
    }

    /// 放在页面上
    func recordSwipeHost(_ state: Binding<RecordSwipeState>) -> some View {
        modifier(RecordSwipeHost(state: state))
    }
}

private struct RecordSwipeActions: ViewModifier {
    let row: RecordRow
    @Binding var state: RecordSwipeState
    @AppStorage(ThemeColor.key) private var themeColor = ThemeColor.blue.rawValue

    func body(content: Content) -> some View {
        content
            // 和卡片详情一样：左滑露出两个按钮，点了才算，滑到底不直接触发
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // 不用 destructive：系统会马上把这一行划走，而这时还没有确认
                Button("删除", systemImage: "trash") { state.deleting = row }
                    .tint(.red)
                Button("编辑", systemImage: "pencil") { state.editing = row }
                    .tint(ThemeColor.color(stored: themeColor))
            }
    }
}

private struct RecordSwipeHost: ViewModifier {
    @Binding var state: RecordSwipeState
    @Environment(LedgerStore.self) private var store
    @State private var editing: RecordDetail?
    @State private var errorText: String?

    func body(content: Content) -> some View {
        content
            .task(id: state.editing?.id) {
                guard let row = state.editing else { return }
                editing = await store.detail(recordID: row.id)
                state.editing = nil
            }
            .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                if let editing { RecordEditor(detail: editing) {} }
            }
            .confirmationDialog(
                "删除这笔流水？",
                isPresented: Binding(get: { state.deleting != nil }, set: { if !$0 { state.deleting = nil } }),
                titleVisibility: .visible,
                presenting: state.deleting
            ) { row in
                Button("删除", role: .destructive) { Task { await delete(row) } }
                Button("取消", role: .cancel) {}
            } message: { row in
                Text(row.record.transferGroupID == nil ? "删除后不能恢复" : "只删除这一边，另一边的账户还留着这笔。删除后不能恢复")
            }
            .alert("删除失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
    }

    private func delete(_ row: RecordRow) async {
        do {
            try await store.deleteRecord(id: row.id)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
