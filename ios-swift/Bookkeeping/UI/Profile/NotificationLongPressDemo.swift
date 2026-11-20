import SwiftUI
import BKModel

/// 演示用的通知：样子照系统的通知（App 图标、App 名、时间、标题、正文）。
/// 图标和桌面上的一样：「我的 › 显示 › 图标」选了浅色、深色就画那一个，跟随系统按现在的外观画。
/// `lifted`：长按后浮起来的样子，照真机截图量的（通知图标按 38 算）：实底、圆角约 32、四边约 14、图标和字隔约 12
struct NotificationCard: View {
    let title: String?
    let message: String
    var lifted = false

    @AppStorage(AppearanceMode.iconKey) private var appIcon = AppearanceMode.system.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var iconMode: AppearanceMode {
        let chosen = AppearanceMode(rawValue: appIcon) ?? .system
        guard chosen == .system else { return chosen }
        return colorScheme == .dark ? .dark : .light
    }

    private var corner: CGFloat { lifted ? 32 : 22 }

    var body: some View {
        HStack(alignment: .top, spacing: lifted ? 12 : 10) {
            AppIconPreview(mode: iconMode, cornerRadius: 8.5)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: "Tacito").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("现在").font(.footnote).foregroundStyle(.secondary)
                }
                if let title {
                    Text(title).font(.subheadline.weight(.semibold))
                }
                Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(lifted ? 14 : 12)
        .background {
            if lifted {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            } else {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.separator, lineWidth: 0.5)
                    }
            }
        }
    }
}

/// 「我的 › 通知」长按记账结果的演示通知：照系统长按通知的样子（ADR 0020）——就在长按的那条通知那里浮起来，
/// 后面模糊，通知下面居中弹出一块玻璃的选项（约 260 宽，一行约 44 高，图标在左、字在右，没有分隔线，照真机截图量的）。
/// 下面放不下时整块往上挪，和系统一样。
/// 按钮和真的通知一样：一页 3 个分类，第 4 个是「更多大类」、「更多」、「返回」或「打开 App」；点有小类的大类当场换成小类。
/// 换页用的就是通知扩展那一套（`NotificationPicker.buttons(after:)`）。点到分类、「打开 App」或者点空白处就收起，不记账
struct NotificationLongPressDemo: View {
    let message: String
    let picker: NotificationPicker
    /// 长按的那条演示通知在屏幕上的位置（全局坐标）
    let anchor: CGRect
    let dismiss: () -> Void

    @State private var buttons: [NotificationPicker.Button] = []
    @State private var visible = false
    /// 通知和选项一共多高：下面放不下时往上挪
    @State private var stackHeight: CGFloat = 0

    /// 选项离屏幕下边至少多远（让开主屏幕指示条）
    private static let bottomMargin: CGFloat = 44
    private static let menuWidth: CGFloat = 260
    private static let menuCorner: CGFloat = 30
    private static let rowHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(visible ? 1 : 0)
                    .onTapGesture(perform: close)
                    .accessibilityHidden(true)
                VStack(spacing: 17) {
                    NotificationCard(title: nil, message: message, lifted: true)
                        .scaleEffect(visible ? 1 : 0.97)
                    actions
                        .scaleEffect(visible ? 1 : 0.5, anchor: .top)
                        .opacity(visible ? 1 : 0)
                }
                .frame(width: anchor.width)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stackHeight = $0 }
                .offset(x: anchor.minX, y: top(screenHeight: geo.size.height))
            }
        }
        .ignoresSafeArea()
        .accessibilityAction(.escape, close)
        .onAppear {
            buttons = picker.parentButtons(page: 0)
            withAnimation(.spring(duration: 0.35, bounce: 0.2)) { visible = true }
        }
    }

    /// 通知放在长按的地方；下面放不下选项时整块往上挪到刚好放得下
    private func top(screenHeight: CGFloat) -> CGFloat {
        guard stackHeight > 0 else { return anchor.minY }
        return max(0, min(anchor.minY, screenHeight - Self.bottomMargin - stackHeight))
    }

    /// 系统长按通知下面的那一块：图标在左、字在右，没有分隔线
    private var actions: some View {
        VStack(spacing: 0) {
            ForEach(buttons, id: \.self) { button in
                Button { tap(button) } label: {
                    HStack(spacing: 11) {
                        Image(systemName: button.symbol)
                            .frame(width: 28)
                        Text(verbatim: picker.title(button))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.body)
                    .padding(.leading, 27)
                    .padding(.trailing, 20)
                    .frame(height: Self.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ActionRowStyle())
            }
        }
        .padding(.vertical, 10)
        .frame(width: Self.menuWidth)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.menuCorner, style: .continuous))
        .animation(.smooth(duration: 0.2), value: buttons)
    }

    /// 翻页、点大类换小类、「返回」：当场换按钮；点到分类、「打开 App」：真的通知会收起，这里也收起
    private func tap(_ button: NotificationPicker.Button) {
        if let next = picker.buttons(after: NotificationPicker.identifier(button)) {
            buttons = next
        } else {
            close()
        }
    }

    private func close() {
        withAnimation(.smooth(duration: 0.25)) {
            visible = false
        } completion: {
            dismiss()
        }
    }
}

/// 按下时这一行垫一块圆角的灰，和系统的菜单一样
private struct ActionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0))
                    .padding(.horizontal, 8)
            }
    }
}
