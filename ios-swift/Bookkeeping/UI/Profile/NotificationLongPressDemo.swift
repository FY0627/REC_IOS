import SwiftUI
import BKModel

/// 演示用的通知：样子照系统的通知（App 图标、App 名、时间、标题、正文）。
/// 图标和桌面上的一样：「我的 › 显示 › 图标」选了浅色、深色就画那一个，跟随系统按现在的外观画
struct NotificationCard: View {
    let title: String?
    let message: String

    @AppStorage(AppearanceMode.iconKey) private var appIcon = AppearanceMode.system.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var iconMode: AppearanceMode {
        let chosen = AppearanceMode(rawValue: appIcon) ?? .system
        guard chosen == .system else { return chosen }
        return colorScheme == .dark ? .dark : .light
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
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
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.separator, lineWidth: 0.5)
        }
    }
}

/// 「我的 › 通知」长按记账结果的演示通知：照系统长按通知的样子，后面模糊，通知放大到顶上，下面一列按钮（ADR 0020）。
/// 按钮和真的通知一样：一页 3 个分类，第 4 个是「更多大类」、「更多」、「返回」或「打开 App」；点有小类的大类当场换成小类。
/// 换页用的就是通知扩展那一套（`NotificationPicker.buttons(after:)`）。点到分类、「打开 App」或者点空白处就收起，不记账
struct NotificationLongPressDemo: View {
    let message: String
    let picker: NotificationPicker
    let dismiss: () -> Void

    @State private var buttons: [NotificationPicker.Button] = []
    @State private var visible = false

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .opacity(visible ? 1 : 0)
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                NotificationCard(title: nil, message: message)
                actions
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .scaleEffect(visible ? 1 : 0.94, anchor: .top)
            .opacity(visible ? 1 : 0)
        }
        .accessibilityAction(.escape, close)
        .onAppear {
            buttons = picker.parentButtons(page: 0)
            withAnimation(.smooth(duration: 0.3)) { visible = true }
        }
    }

    /// 系统长按通知下面的那一列：字在左、图标在右，中间细线
    private var actions: some View {
        VStack(spacing: 0) {
            ForEach(Array(buttons.enumerated()), id: \.element) { index, button in
                if index > 0 { Divider() }
                Button { tap(button) } label: {
                    HStack(spacing: 12) {
                        Text(verbatim: picker.title(button))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: button.symbol)
                            .frame(width: 24)
                    }
                    .font(.body)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ActionRowStyle())
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.smooth(duration: 0.25), value: buttons)
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

/// 按下时整行变灰，和系统的按钮一样
private struct ActionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : .clear)
    }
}
