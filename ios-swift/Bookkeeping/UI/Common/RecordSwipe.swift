import SwiftUI
import UIKit
import BKModel

/// 列表里对一笔流水的滑动操作：左滑露出「编辑」「删除」，删除要先确认。都是系统的滑动按钮：
/// 首页、统计是系统列表（`.recordSwipe`）；卡片详情的列表是 UIKit，按钮在 `WalletDetailList`。
/// 确认用系统的下拉菜单（`RecordDeleteMenuButton`），从那一行弹出，所以在行上（卡片详情从「删除」按钮弹出）；
/// 打开编辑、真正删除由页面上的 `.recordSwipeHost` 处理。
struct RecordSwipeState {
    var editing: RecordRow?
    /// 正在确认要不要删的一行
    var deleting: RecordRow?
    /// 确认过了，可以删了
    var confirmedDelete: RecordRow?
}

extension RecordRow {
    /// 删除确认菜单上的说明
    var deleteWarning: String {
        record.transferGroupID == nil ? L("删除后不能恢复") : L("只删除这一边，另一边的账户还留着这笔。删除后不能恢复")
    }
}

/// 删除确认：系统的下拉菜单，和流水详情最下面的「删除」一样，出现、收起都是系统动画，点菜单外面就是取消。
/// 系统的滑动按钮不能挂菜单，用代码打开菜单的公开办法只有 `performPrimaryAction`：
/// 在要弹出的位置放一个看不见的按钮，让它打开菜单，收起后拿掉。
final class RecordDeleteMenuButton: UIButton {
    private var onEnd: () -> Void = {}

    /// `rect` 是 `view` 里的位置。`onEnd` 在菜单收起后调用，确认和取消都会调
    static func show(
        _ row: RecordRow,
        at rect: CGRect,
        in view: UIView,
        onDelete: @escaping () -> Void,
        onEnd: @escaping () -> Void
    ) {
        let button = RecordDeleteMenuButton(frame: rect)
        button.onEnd = onEnd
        button.isHidden = true
        button.isUserInteractionEnabled = false
        button.isContextMenuInteractionEnabled = true
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [
            UIMenu(title: row.deleteWarning, options: .displayInline, children: [
                UIAction(title: L("删除这笔流水"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in onDelete() }
            ])
        ])
        view.addSubview(button)
        button.performPrimaryAction()
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        guard let animator else { return finish() }
        animator.addCompletion { [self] in finish() }
    }

    private func finish() {
        onEnd()
        removeFromSuperview()
    }
}

/// 首页、统计：系统列表的滑动按钮拿不到视图，菜单从这一行右端的这块空白弹出
private struct RecordDeleteAnchor: UIViewRepresentable {
    let row: RecordRow
    let onDelete: () -> Void
    let onEnd: () -> Void

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.open = { anchor in
            RecordDeleteMenuButton.show(row, at: anchor.bounds, in: anchor, onDelete: onDelete, onEnd: onEnd)
        }
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {}

    final class AnchorView: UIView {
        var open: ((UIView) -> Void)?

        // 这时 SwiftUI 已经排好了位置；打开菜单放到布局之后
        override func layoutSubviews() {
            super.layoutSubviews()
            guard !bounds.isEmpty, let open else { return }
            self.open = nil
            Task { open(self) }
        }
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
            // 放在这一行上：确认菜单从这一行右端、也就是「删除」按钮那里弹出
            .background(alignment: .trailing) {
                if state.deleting?.id == row.id {
                    RecordDeleteAnchor(row: row) {
                        state.confirmedDelete = row
                    } onEnd: {
                        state.deleting = nil
                    }
                    .frame(width: 76)
                }
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
