import SwiftUI
import UIKit
import UserNotifications

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: L("跟随系统")
        case .light: L("浅色")
        case .dark: L("深色")
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

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 系统要求启动完成之前设好：点通知上的分类按钮时 App 可能正是被它拉起来的
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        // 记下启动的时候：灵动岛上的按钮把 App 拉起来时，看启动后多久才轮到按钮的动作
        _ = LiveCategoryActivity.launchedAt
        return true
    }
}

@main
struct BookkeepingApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = LedgerStore()
    @State private var rates = ExchangeRateStore()
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @AppStorage(ThemeColor.key) private var themeColor = ThemeColor.blue.rawValue
    @AppStorage(ExchangeRateStore.primaryKey) private var primaryCurrency = "CNY"
    /// 换了语言、换了账本（演示数据）整个界面重建（`AppLanguage`）；停在哪个标签放在外面，重建后还在这个标签
    @AppStorage(AppLanguage.key) private var language = AppLanguage.system.rawValue
    @State private var tab: AppTab = .home
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppLanguage.prepare()
    }

    private var appearanceMode: AppearanceMode { AppearanceMode(rawValue: appearance) ?? .system }

    var body: some Scene {
        WindowGroup {
            RootView(tab: $tab)
                // 换了演示数据（ADR 0025）也整个重建：停在另一个账本里的页面都关掉
                .id("\(language)|\(store.ledgerGeneration)")
                .environment(\.locale, AppLanguage.locale)
                .environment(store)
                .environment(rates)
                .preferredColorScheme(appearanceMode.colorScheme)
                .tint(ThemeColor.color(stored: themeColor))
                .onChange(of: themeColor, initial: true) { ThemeColor.applyToWindows() }
                .task { await store.start() }
                .onChange(of: scenePhase) { _, phase in
                    // 自动化在后台入账后，用户下次打开 App 时刷新
                    if phase == .active { store.scheduleRefresh() }
                    // 灵动岛上那一笔已经在 App 里选了分类、或者删了：打开、离开 App 时结束它（ADR 0024）
                    if phase != .inactive { Task { await LiveCategoryActivity.reconcile() } }
                }
                // 单点灵动岛或锁屏卡片：打开这一笔的选分类面板
                .onOpenURL { url in
                    if let recordID = CategoryActivityLink.recordID(from: url) { CategorizeRequest.shared.recordID = recordID }
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
