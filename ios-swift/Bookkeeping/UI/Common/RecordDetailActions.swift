import SwiftUI
import UIKit

/// 流水详情右上角的「合并」「删除」：两块圆形液态玻璃，图标是文字颜色（浅色外观黑色，深色外观白色），不跟主题色。
///
/// 和资产页顶部按钮一样像水滴：用系统的玻璃融合（`GlassEffectContainer` + `glassEffectID`），
/// 同一个容器里出现 / 消失的玻璃从相邻的玻璃里分出来、并回去。
/// - 进来：删除先「凝结」出来，紧接着合并从删除里向左分出来，冲过一点再弹回；
/// - 离开（返回、推进下一页）：合并先并回删除，删除再化掉；
/// - 合并、拆开以后能不能合并变了：合并按钮跟着分出来或并回去。
/// 放在系统导航栏里，但不要系统包的那层玻璃（`sharedBackgroundVisibility(.hidden)`），玻璃自己画，才能分合。
/// 什么时候出现、消失由 `RecordDetailView` 按页面的出现、消失（`AppearanceProbe`）控制
struct RecordDetailActions: View {
    let showsDelete: Bool
    let showsMerge: Bool
    let merge: () -> Void
    let delete: () -> Void

    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: GlassControls.mergeSpacing) {
            HStack(spacing: GlassControls.gap) {
                if showsMerge {
                    Button(action: merge) {
                        // 系统的合并图标箭头朝上，转成朝右：几笔并到右边一笔
                        icon("arrow.triangle.merge").rotationEffect(.degrees(90))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("merge", in: glass)
                    .accessibilityLabel("合并")
                }
                if showsDelete {
                    // 确认的小菜单就在这个按钮下面弹出
                    Menu {
                        Section("删除后不能恢复") {
                            Button("删除这笔流水", systemImage: "trash", role: .destructive, action: delete)
                        }
                    } label: {
                        icon("trash")
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("delete", in: glass)
                    .accessibilityLabel("删除")
                }
            }
        }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Color.primary)
            .frame(width: GlassControls.size, height: GlassControls.size)
            .contentShape(Circle())
    }
}

/// 页面将要出现（推进来、从下一页返回）和将要消失（返回、推进下一页）的那一刻：和转场同时开始。
/// SwiftUI 的 `onAppear` 在转场开始后才来，`onDisappear` 在转场结束后才来，赶不上按钮的分合。
/// 手势返回到一半又松手回来：先收到将要消失，再收到将要出现
struct AppearanceProbe: UIViewControllerRepresentable {
    let changed: (Bool) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.changed = changed
    }

    final class Controller: UIViewController {
        var changed: (Bool) -> Void = { _ in }

        override func loadView() {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            self.view = view
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            changed(true)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            changed(false)
        }
    }
}
