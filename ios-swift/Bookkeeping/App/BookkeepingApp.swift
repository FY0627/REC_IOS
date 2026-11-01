import SwiftUI
import UIKit

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
    /// 「我的 › 图标」：桌面图标也是这三种，和界面的外观分开选
    static let iconKey = "appIcon"

    /// 跟随系统用主图标：它自己有深色外观，系统换外观时自己变，不弹提示。
    /// 浅色、深色各一套备用图标，系统是什么外观都保持这个颜色
    var iconName: String? {
        switch self {
        case .system: nil
        case .light: "AppIconLight"
        case .dark: "AppIconDark"
        }
    }

    /// 换成「我的 › 图标」选的桌面图标。每次换系统都会弹提示，所以图标已经对了就不换。
    /// 还没选过（包括从图标跟着外观换的版本升上来）就记下现在的图标，不去动它
    @MainActor static func applyIcon() {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons else { return }
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: iconKey) else {
            let installed = allCases.first { $0.iconName == app.alternateIconName } ?? .system
            defaults.set(installed.rawValue, forKey: iconKey)
            return
        }
        let name = (AppearanceMode(rawValue: raw) ?? .system).iconName
        guard app.alternateIconName != name else { return }
        Task { try? await app.setAlternateIconName(name) }
    }
}

@main
struct BookkeepingApp: App {
    @State private var store = LedgerStore()
    @State private var rates = ExchangeRateStore()
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @AppStorage(ThemeColor.key) private var themeColor = ThemeColor.blue.rawValue
    @AppStorage(ExchangeRateStore.primaryKey) private var primaryCurrency = "CNY"
    @Environment(\.scenePhase) private var scenePhase

    private var appearanceMode: AppearanceMode { AppearanceMode(rawValue: appearance) ?? .system }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(rates)
                .preferredColorScheme(appearanceMode.colorScheme)
                .tint(ThemeColor.color(stored: themeColor))
                .onChange(of: themeColor, initial: true) { ThemeColor.applyToWindows() }
                .task { await store.start() }
                .onChange(of: scenePhase) { _, phase in
                    // 自动化在后台入账后，用户下次打开 App 时刷新
                    if phase == .active { store.scheduleRefresh() }
                }
                // 重装后系统可能换回主图标；打开 App 时对一下
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { AppearanceMode.applyIcon() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .ledgerDidChange)) { _ in
                    store.scheduleRefresh()
                }
                // 换了主要币种：首页的本月合计重新换算
                .onChange(of: primaryCurrency) { store.scheduleRefresh() }
        }
    }
}
