import SwiftUI
import Observation

enum AppTab: Hashable {
    case home
    case assets
    case stats
    case profile

    var title: String {
        switch self {
        case .home: "首页"
        case .assets: "资产"
        case .stats: "统计"
        case .profile: "我的"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"
        case .assets: "wallet.bifold"
        case .stats: "chart.bar"
        case .profile: "person"
        }
    }
}

/// 资产页当前展开的卡片；详情展开时资产页隐藏标签栏。
/// 只有资产页读它：根视图不读，打开详情时其他标签页不重新计算。
@MainActor
@Observable
final class DetailMotionState {
    var selectedAccountID: String?

    var isOpen: Bool { selectedAccountID != nil }

    /// 打开 / 关闭详情时标签栏显隐的动画；卡片的 Core Animation 弹簧（`CardMotion.transition`）参数相同，节奏一致
    static func transition(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.5, dampingFraction: 0.86)
    }
}

enum ActiveSheet: Identifiable {
    case addAccount
    case pending

    var id: Int {
        switch self {
        case .addAccount: 0
        case .pending: 1
        }
    }
}

/// 系统原生 `TabView`：iOS 26 起标签栏自动使用液态玻璃，尺寸、字号、动效和无障碍都由系统提供。
/// 添加银行卡的「+」在资产页右上角。
/// 切换标签按 iOS 的默认做法：每个页面保留自己的状态（滚动位置、打开的详情）。
/// 资产页打开卡片详情时，资产页用系统的方式隐藏标签栏（随打开 / 关闭的动画滑出 / 滑入）。
struct RootView: View {
    @Environment(LedgerStore.self) private var store
    @State private var tab: AppTab = .home
    @State private var detail = DetailMotionState()
    @State private var sheet: ActiveSheet?
    @State private var assetsReselectCount = 0

    /// 再点一次当前的标签时系统也会调用 set：其他页面的列表由系统滚回顶部，
    /// 资产页的卡包是 UIKit 的滚动区，系统不会替它滚，记一下让资产页自己滚
    private var selection: Binding<AppTab> {
        Binding { tab } set: { newTab in
            if newTab == tab, newTab == .assets { assetsReselectCount += 1 }
            tab = newTab
        }
    }

    var body: some View {
        TabView(selection: selection) {
            Tab(AppTab.home.title, systemImage: AppTab.home.symbol, value: AppTab.home) {
                HomeView(openPending: { sheet = .pending })
            }
            Tab(AppTab.assets.title, systemImage: AppTab.assets.symbol, value: AppTab.assets) {
                AssetsView(openAddAccount: { sheet = .addAccount }, reselectCount: assetsReselectCount)
            }
            Tab(AppTab.stats.title, systemImage: AppTab.stats.symbol, value: AppTab.stats) {
                StatsView()
            }
            Tab(AppTab.profile.title, systemImage: AppTab.profile.symbol, value: AppTab.profile) {
                ProfileView()
            }
        }
        .tabBarMinimizeBehavior(.never)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .addAccount:
                AddAccountView()
            case .pending:
                PendingView()
            }
        }
        .environment(detail)
        .dismissesKeyboardOnTapOutside()
        .overlay(alignment: .topTrailing) {
            if PerfFlags.shared.showMetrics {
                MetricsOverlay().padding(.trailing, 8)
            }
        }
        .overlay {
            if case .failed(let message) = store.state {
                StorageErrorView(message: message) { Task { await store.retryStart() } }
            }
        }
    }
}

struct StorageErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("无法打开本地账本", systemImage: "lock.shield")
        } description: {
            Text(message)
        } actions: {
            Button("重试", action: retry)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
        .background(Color(.systemBackground))
    }
}
