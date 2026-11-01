import SwiftUI
import BKModel

/// 列表里对一笔流水的滑动操作：左滑露出「编辑」「删除」，删除要先确认。
/// 首页、统计是系统列表（`.recordSwipe`）；卡片详情的列表是 UIKit，手势在 `WalletDetailList`。
/// 确认框从那一行弹出，所以在行上（卡片详情从「删除」按钮弹出）；打开编辑、真正删除由页面上的 `.recordSwipeHost` 处理。
struct RecordSwipeState {
    var editing: RecordRow?
    /// 正在确认要不要删的一行
    var deleting: RecordRow?
    /// 确认过了，可以删了
    var confirmedDelete: RecordRow?
}

extension RecordRow {
    /// 删除确认框上的说明
    var deleteWarning: String {
        record.transferGroupID == nil ? "删除后不能恢复" : "只删除这一边，另一边的账户还留着这笔。删除后不能恢复"
    }
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
            // 放在这一行上：确认框从它所在的视图弹出，放在页面上就离这一行很远
            .confirmationDialog(
                "删除这笔流水？",
                isPresented: Binding(get: { state.deleting?.id == row.id }, set: { if !$0 { state.deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) { state.confirmedDelete = row }
                Button("取消", role: .cancel) {}
            } message: {
                Text(row.deleteWarning)
            }
            // 和卡片详情一样：左滑露出两个按钮，点了才算，滑到底不直接触发
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // 不用 destructive：系统会马上把这一行划走，而这时还没有确认
                Button("删除", systemImage: "trash") { state.deleting = row }
                    .tint(.red)
                Button("编辑", systemImage: "pencil") { state.editing = row }
                    .tint(ThemeColor.color(stored: themeColor))
            }
            // 系统默认的行背景滑动时四个角都变圆；换成同样颜色的背景，形状和滑动前一样
            .listRowBackground(Color(.secondarySystemGroupedBackground))
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
            .onChange(of: state.confirmedDelete?.id) {
                guard let row = state.confirmedDelete else { return }
                state.confirmedDelete = nil
                Task { await delete(row) }
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
