import SwiftUI
import Observation

enum AppTab: Hashable {
    case home
    case assets
    case stats
    case profile

    var title: String {
        switch self {
        case .home: L("首页")
        case .assets: L("资产")
        case .stats: L("统计")
        case .profile: L("我的")
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
    case categorize(CategorizeTarget)

    var id: String {
        switch self {
        case .addAccount: "addAccount"
        case .pending: "pending"
        case .categorize(let target): target.id
        }
    }
}

/// 系统原生 `TabView`：iOS 26 起标签栏自动使用液态玻璃，尺寸、字号、动效和无障碍都由系统提供。
/// 添加银行卡的「+」在资产页右上角。
/// 切换标签按 iOS 的默认做法：每个页面保留自己的状态（滚动位置、打开的详情）。
/// 资产页打开卡片详情时，资产页用系统的方式隐藏标签栏（随打开 / 关闭的动画滑出 / 滑入）。
struct RootView: View {
    @Binding var tab: AppTab
    @Environment(LedgerStore.self) private var store
    @State private var detail = DetailMotionState()
    @State private var sheet: ActiveSheet?
    @State private var assetsReselectCount = 0
    @AppStorage(OnboardingView.doneKey) private var onboardingDone = false
    @State private var onboarding = false

    /// 再点一次当前的标签时系统也会调用 set：其他页面的列表由系统滚回顶部，
    /// 资产页的卡包是 UIKit 的滚动区，系统不会替它滚，记一下让资产页自己滚
    private var selection: Binding<AppTab> {
        Binding { tab } set: { newTab in
            if newTab == tab, newTab == .assets { assetsReselectCount += 1 }
            tab = newTab
        }
    }

    /// 点通知要打开的这一笔；账本打开之后才接手
    private var notificationRecordID: String? {
        store.state == .ready ? CategorizeRequest.shared.recordID : nil
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
            case .categorize(let target):
                CategorizeSheet(target: target)
            }
        }
        .fullScreenCover(isPresented: $onboarding) {
            OnboardingView {
                onboardingDone = true
                onboarding = false
            }
        }
        // 账本打开后决定要不要新手引导：什么都没有的新用户才出现；升级上来的老用户直接记成看过
        .onChange(of: store.state, initial: true) { _, state in
            guard state == .ready, !onboardingDone else { return }
            if store.allAccounts.isEmpty, store.homeRows.isEmpty, !store.automationVerified {
                onboarding = true
            } else {
                onboardingDone = true
            }
        }
        .onChange(of: notificationRecordID, initial: true) { _, recordID in
            guard let recordID else { return }
            CategorizeRequest.shared.recordID = nil
            Task {
                guard let target = await store.categorizeTarget(recordID: recordID) else { return }
                sheet = .categorize(target)
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
            if PerfFlags.shared.showAlignmentGuides {
                AlignmentGuides()
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
