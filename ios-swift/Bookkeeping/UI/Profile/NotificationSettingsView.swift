import SwiftUI
import UIKit
import BKModel

/// 「我的 › 通知」：App 发的两种通知放在一页——记账结果（全部 / 仅失败 / 关闭）和导入汇率。
/// 打开的那一种下面显示一条演示通知，看得出会收到什么样的；关了演示就收起来。
/// 演示的文字和真的通知是同一套写法（`IngestNotifier.message`、导入汇率的标题和正文），卡号、金额是假的。
/// 打开时要通知权限，被拒绝就关回去，提示去系统设置。
struct NotificationSettingsView: View {
    @Environment(ExchangeRateStore.self) private var rates
    @AppStorage(IngestNotifier.modeKey) private var notifyMode = IngestNotifier.Mode.off.rawValue
    @AppStorage(ImportExchangeRatesIntent.notifyKey) private var notifyRates = true
    @AppStorage(ThemeColor.key) private var themeColor = ThemeColor.blue.rawValue
    @State private var notifyDenied = false
    @Environment(\.openURL) private var openURL

    private var mode: IngestNotifier.Mode { IngestNotifier.Mode(rawValue: notifyMode) ?? .off }

    var body: some View {
        Form {
            Section {
                // 菜单按钮右边的文字（选中的项）换了主题色不会马上重画，按主题色重建这一行
                Picker(selection: $notifyMode) {
                    ForEach(IngestNotifier.Mode.allCases) { Text($0.title).tag($0.rawValue) }
                } label: {
                    Label("记账结果", systemImage: "bell.badge")
                }
                .id("notify-\(themeColor)")
            }
            // 演示单独一组、没有底色：浮在设置项下面，像一条真的通知
            if mode != .off {
                Section { NotificationPreview(title: nil, message: ingestExample) }
            }

            Section {
                Toggle(isOn: $notifyRates) {
                    Label("导入汇率", systemImage: "arrow.left.arrow.right.circle")
                }
            }
            if notifyRates {
                Section { NotificationPreview(title: L("汇率已更新"), message: ratesExample) }
            }
        }
        .animation(.smooth(duration: 0.3), value: notifyMode)
        .animation(.smooth(duration: 0.3), value: notifyRates)
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: notifyMode) { _, mode in
            guard mode != IngestNotifier.Mode.off.rawValue else { return }
            askPermission { notifyMode = IngestNotifier.Mode.off.rawValue }
        }
        .onChange(of: notifyRates) { _, on in
            guard on else { return }
            askPermission { notifyRates = false }
        }
        .alert("没有通知权限", isPresented: $notifyDenied) {
            Button("去设置") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("在系统设置里允许 Tacito 发送通知。")
        }
    }

    /// 和真的记账结果通知一样的写法：「全部」是记账成功（可以长按选分类），「仅失败」是没对上卡的一笔
    private var ingestExample: String {
        if mode == .failures {
            let item = IngestItem(
                cardTail: "0000", kind: .purchase, status: nil, amountMinor: nil, currency: .cny, amountText: "32.00",
                result: .pending(.noMatchingAccount)
            )
            return IngestNotifier.message(item, failuresOnly: true) ?? ""
        }
        let item = IngestItem(cardTail: "0000", kind: .purchase, status: nil, amountMinor: 3200, currency: .cny, amountText: nil, result: .recorded)
        return (IngestNotifier.message(item, failuresOnly: false) ?? "") + L("，长按选分类")
    }

    /// 导入过汇率的用真的币种数和时间
    private var ratesExample: String {
        let count = rates.rates?.rates.count ?? 160
        let updated = rates.rates?.updatedAt ?? Date()
        return L("已导入 \(count) 个币种的汇率，数据更新于\(Fmt.dateTime(updated))")
    }

    private func askPermission(revert: @escaping () -> Void) {
        Task {
            if !(await IngestNotifier.requestAuthorization()) {
                revert()
                notifyDenied = true
            }
        }
    }
}

/// 演示用的通知横幅：样子照系统的通知（App 名、时间、标题、正文），放在设置项下面
private struct NotificationPreview: View {
    let title: String?
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("效果演示"))
        .accessibilityValue(Text([title, message].compactMap { $0 }.joined(separator: " ")))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
