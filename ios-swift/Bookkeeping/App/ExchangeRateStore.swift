import Foundation
import Observation
import BKModel

/// 主要币种与最新汇率。汇率用于资产页净资产的换算显示，卡片和流水始终是原币种。
///
/// App 自己不联网：汇率由快捷指令自动化下载（「获取 URL 内容」），再交给 App 动作「导入汇率」。
/// 最新一份放在这里（启动时同步读出）；每天的完整汇率表另外保存在账本里，外币交易按当天的汇率估算扣款。
@MainActor
@Observable
final class ExchangeRateStore {
    nonisolated static let primaryKey = "fx.primaryCurrency"
    nonisolated private static let cacheKey = "fx.cache"

    /// 「我的」里选的主要币种：净资产和首页的本月合计都换算成它
    nonisolated static var primaryCurrency: CurrencyCode {
        UserDefaults.standard.string(forKey: primaryKey).map { CurrencyCode($0) } ?? .cny
    }

    private(set) var rates: ExchangeRates?

    init() {
        reload()
        // App 动作「导入汇率」在后台写入缓存后通知界面
        NotificationCenter.default.addObserver(forName: .exchangeRatesDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func reload() {
        rates = Self.cached()
    }

    /// 本机缓存的最新汇率。可以在任何线程调用。
    nonisolated static func cached() -> ExchangeRates? {
        UserDefaults.standard.data(forKey: cacheKey).flatMap { try? JSONDecoder().decode(ExchangeRates.self, from: $0) }
    }

    /// 写入本机缓存。由 App 动作调用，可以在任何线程调用。
    nonisolated static func save(_ rates: ExchangeRates) {
        guard let encoded = try? JSONEncoder().encode(rates) else { return }
        UserDefaults.standard.set(encoded, forKey: cacheKey)
    }
}

extension Notification.Name {
    static let exchangeRatesDidChange = Notification.Name("bk.exchangeRatesDidChange")
}
