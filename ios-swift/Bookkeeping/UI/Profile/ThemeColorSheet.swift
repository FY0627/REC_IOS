import SwiftUI

/// 选主题色：和「记一笔」一样的弹窗，左上角取消，右上角确定才换。
/// 现成的颜色点色块；想要别的颜色用系统的色盘（`ColorPicker`）自己调。
/// 选的时候只有弹窗里跟着变：色盘拖动时颜色变得很快，不用让整个 App 跟着重画。
struct ThemeColorSheet: View {
    @Binding var selection: String

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(selection: Binding<String>) {
        _selection = selection
        _draft = State(initialValue: selection.wrappedValue)
    }

    private var custom: Binding<Color> {
        Binding { ThemeColor.color(stored: draft) } set: { draft = ThemeColor.stored(custom: $0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ThemeColorGrid(selection: $draft)
                        .padding(.vertical, 4)
                }
                Section {
                    ColorPicker(selection: custom, supportsOpacity: false) {
                        Label("自定义", systemImage: "eyedropper")
                    }
                }
            }
            .navigationTitle("主题色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定", systemImage: "checkmark") {
                        selection = draft
                        // UIKit 做的部分马上换，不等下一次刷新
                        ThemeColor.applyToWindows()
                        dismiss()
                    }
                }
            }
        }
        .tint(ThemeColor.color(stored: draft))
    }
}

/// 现成的主题色：和记账选分类一样排成格子，每块是它自己的颜色（不跟着主题色），选中的打勾
private struct ThemeColorGrid: View {
    @Binding var selection: String

    private static let columns = 6

    var body: some View {
        let themes = ThemeColor.allCases
        let lines = stride(from: 0, to: themes.count, by: Self.columns).map { Array(themes[$0..<min($0 + Self.columns, themes.count)]) }
        VStack(spacing: 12) {
            ForEach(lines.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 6) {
                    ForEach(lines[index]) { swatch($0) }
                }
            }
        }
    }

    private func swatch(_ theme: ThemeColor) -> some View {
        let isSelected = selection == theme.rawValue
        return Button {
            selection = theme.rawValue
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(theme.color)
                    .frame(width: 36, height: 36)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Color.white)
                            .opacity(isSelected ? 1 : 0)
                    }
                    .padding(3)
                    .overlay(Circle().stroke(theme.color, lineWidth: isSelected ? 2 : 0))
                Text(theme.title)
                    .font(.caption)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .animation(.snappy(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
