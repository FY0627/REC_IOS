import SwiftUI
import UIKit
import BKModel

/// 「我的 › 通知」：App 发的两种通知放在一页——导入汇率和记账结果（全部 / 仅失败 / 关闭），
/// 记账结果选「全部」时下面多一个灵动岛（ADR 0024：没分类的在岛上选，没有灵动岛的手机是待分类的提醒横幅）。
/// 灵动岛跟着记账结果出现、收起，放在最下面，出来时不把别的挤开。
/// 打开的那一种下面显示一条演示，看得出会收到什么样的；关了演示就收起来。记账结果选「全部」时演示的通知可以长按，走一遍真的长按选分类。
/// 演示的文字和真的通知是同一套写法（`IngestNotifier.message`、导入汇率的标题和正文），卡号、金额是假的。
/// 打开通知时要通知权限，被拒绝就关回去，提示去系统设置。
struct NotificationSettingsView: View {
    @Environment(ExchangeRateStore.self) private var rates
    @AppStorage(IngestNotifier.modeKey) private var notifyMode = IngestNotifier.Mode.off.rawValue
    @AppStorage(ImportExchangeRatesIntent.notifyKey) private var notifyRates = true
    @AppStorage(IngestNotifier.islandKey) private var islandOn = true
    @AppStorage(ThemeColor.key) private var themeColor = ThemeColor.defaultValue
    @State private var notifyDenied = false
    @State private var longPressing = false
    @Environment(LedgerStore.self) private var store
    @Environment(\.openURL) private var openURL
    private let hasIsland = DynamicIsland.isPresent(model: LiveCategoryActivity.modelIdentifier)

    private var mode: IngestNotifier.Mode { IngestNotifier.Mode(rawValue: notifyMode) ?? .off }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $notifyRates) {
                    Label("导入汇率", systemImage: "arrow.left.arrow.right.circle")
                }
            }
            if notifyRates {
                Section { NotificationPreview(title: L("汇率已更新"), message: ratesExample) }
            }

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
                Section {
                    NotificationPreview(title: nil, message: ingestExample, onLongPress: mode == .all ? showLongPress : nil)
                }
            }

            // 只有「全部」才在岛上选分类（`IngestNotifier.post`），别的时候不显示
            if mode == .all {
                Section {
                    Toggle(isOn: $islandOn) {
                        if hasIsland {
                            Label("灵动岛", systemImage: "iphone.gen3")
                        } else {
                            Label("实时活动提醒", systemImage: "iphone.gen3")
                        }
                    }
                }
                if islandOn {
                    Section { IslandPreview(hasIsland: hasIsland) }
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: notifyMode)
        .animation(.smooth(duration: 0.3), value: notifyRates)
        .animation(.smooth(duration: 0.3), value: islandOn)
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: notifyMode) { _, mode in
            guard mode != IngestNotifier.Mode.off.rawValue else { return }
            askPermission { notifyMode = IngestNotifier.Mode.off.rawValue }
        }
        .onChange(of: islandOn) { _, on in
            // 岛上正在选的也收起，留在待分类
            guard !on else { return }
            Task { await LiveCategoryActivity.endAll() }
        }
        .onChange(of: notifyRates) { _, on in
            guard on else { return }
            askPermission { notifyRates = false }
        }
        .fullScreenCover(isPresented: $longPressing) {
            NotificationLongPressDemo(message: ingestExample, picker: demoPicker) {
                // 自己做了淡出，关的时候系统不再从下面滑走
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { longPressing = false }
            }
            .presentationBackground(.clear)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: longPressing) { _, shown in shown }
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

    /// 长按演示：系统不从下面滑上来，模糊和按钮自己淡入（`NotificationLongPressDemo`）
    private func showLongPress() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { longPressing = true }
    }

    /// 长按演示的按钮：用账本里自己的支出分类，按分类页的顺序（还没选过分类时真的通知也是这样），
    /// 换语言和真的通知一样（`IngestNotifier.pickerLabels`）。翻页、点大类换小类照通知扩展的逻辑（`NotificationPicker`）
    private var demoPicker: NotificationPicker {
        let shown = store.categories.filter { $0.type == .expense && !$0.hidden && !$0.locked }
        let ordered = { (list: [LedgerCategory]) in list.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) } }
        let groups = ordered(shown.filter { $0.parentID == nil }).map { parent in
            NotificationPicker.Group(
                option: NotificationPicker.Option(parent),
                children: ordered(shown.filter { $0.parentID == parent.id }).map(NotificationPicker.Option.init)
            )
        }
        return NotificationPicker(first: nil, groups: groups).localized(name: \.loc, labels: IngestNotifier.pickerLabels)
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

/// 演示用的通知横幅，放在设置项下面（样子见 `NotificationCard`）。
/// 记账结果选「全部」时可以长按（`onLongPress`）：和真的通知一样弹出选分类的按钮（`NotificationLongPressDemo`）
private struct NotificationPreview: View {
    let title: String?
    let message: String
    var onLongPress: (() -> Void)?

    @State private var pressing = false

    var body: some View {
        NotificationCard(title: title, message: message)
            // 按住时像系统的通知那样缩一点，到时间弹出按钮
            .scaleEffect(pressing ? 0.96 : 1)
            .animation(.smooth(duration: 0.25), value: pressing)
            .onLongPressGesture(minimumDuration: 0.4) {
                onLongPress?()
            } onPressingChanged: { pressing = onLongPress != nil && $0 }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("效果演示"))
            .accessibilityValue(Text([title, message].compactMap { $0 }.joined(separator: " ")))
            .accessibilityAction(named: Text("选分类")) { onLongPress?() }
            .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
