import SwiftUI
import BKBackend

/// 「我的 › 快捷指令」：App 用到的快捷指令都在这一页——自动记账、截图记账、更新汇率。
/// 最上面用分段选择换着看（和记账页选支出、收入的一样），下面只有两行：设置（添加快捷指令）和教程（原来的分步页面）。
///
/// TestFlight / App Store 装的「添加快捷指令」打开共享链接；自己侧载的用不了共享链接，换成打开快捷指令 App，照着教程自己建。
struct ShortcutsView: View {
    @Environment(\.openURL) private var openURL
    @State private var kind: Kind = .bank

    enum Kind: CaseIterable {
        case bank, screenshot, rates

        var title: LocalizedStringKey {
            switch self {
            case .bank: "自动记账"
            case .screenshot: "截图记账"
            case .rates: "更新汇率"
            }
        }

        var guide: ProfileRoute {
            switch self {
            case .bank: .autoSetup
            case .screenshot: .screenshotSetup
            case .rates: .exchangeRates
            }
        }

        var shared: URL {
            switch self {
            case .bank: SharedShortcuts.bankMessage
            case .screenshot: SharedShortcuts.paymentScreenshot
            case .rates: SharedShortcuts.exchangeRates
            }
        }
    }

    private var shared: Bool { SharedShortcuts.available }

    var body: some View {
        List {
            Section {
                Button(shared ? "添加快捷指令" : "打开快捷指令", systemImage: "plus.square.on.square") {
                    Task { await setUp() }
                }
                NavigationLink(value: kind.guide) {
                    Label("教程", systemImage: "list.number")
                }
            } header: {
                // 放在分组标题的位置：上下只留一点空隙（和「我的 › 分类」一样）
                Picker("快捷指令", selection: $kind) {
                    ForEach(Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .textCase(nil)
                .listRowInsets(EdgeInsets())
                .padding(.bottom, 8)
            }
        }
        .navigationTitle("快捷指令")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setUp() async {
        guard shared else {
            if let url = URL(string: "shortcuts://") { openURL(url) }
            return
        }
        // 开着导入汇率通知：离开 App 前先要通知权限（和原来的设置页一样）
        if kind == .rates, ImportExchangeRatesIntent.notifies { _ = await IngestNotifier.requestAuthorization() }
        openURL(kind.shared)
    }
}
