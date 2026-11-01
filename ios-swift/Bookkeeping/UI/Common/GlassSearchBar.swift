import SwiftUI

/// 页面最下面的搜索框（液态玻璃）。点进去时右边像水滴一样分出一个圆形的关闭按钮，退出时并回搜索框里。
/// 用系统的玻璃融合（`GlassEffectContainer` + `glassEffectID`），在动画里出现 / 消失的玻璃会从相邻的玻璃里分出来、并回去。
/// 选币种页面用它：添加银行卡（弹出页里推进来）和「我的 › 主要币种」（标签页里推进来）一个样子。
struct GlassSearchBar: View {
    @Binding var text: String
    let prompt: String

    @FocusState private var focused: Bool
    @Namespace private var glass

    static let height: CGFloat = 48

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(prompt, text: $text)
                        .focused($focused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                    if !text.isEmpty {
                        Button {
                            text = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除")
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: Self.height)
                .contentShape(Capsule())
                .onTapGesture { focused = true }
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("field", in: glass)

                if focused {
                    Button {
                        text = ""
                        focused = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.primary)
                            .frame(width: Self.height, height: Self.height)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("close", in: glass)
                    .accessibilityLabel("取消搜索")
                }
            }
        }
        // 点进去、退出（点关闭或往下翻收起键盘）都在动画里：关闭按钮从搜索框里分出来、并回去
        .animation(.smooth(duration: 0.35), value: focused)
    }
}
