import Foundation
import BKModel
import BKDatabase

extension LedgerBackend {
    /// 演示账本（ADR 0025）：只建好六个账户和初始余额，再放上最近 30 天每天的汇率。没有流水、没有待处理，什么都没学过，
    /// 和刚加完卡的用户一样；之后的通知、截图、手动记账都走真实的流程。
    ///
    /// 账户是 30 天前加的：日期在这之后的通知都算进余额。尾号是编的
    public func seedDemo() async throws {
        let now = clock()
        let opened = calendar.date(byAdding: .day, value: -DemoSeed.days, to: calendar.startOfDay(for: now)) ?? now
        let writer = LedgerBackend(database: database, calendar: calendar, clock: { opened }, newID: newID)
        for draft in DemoSeed.accounts {
            _ = try await writer.addAccount(draft)
        }
        for rates in DemoSeed.rates(until: now, calendar: calendar) {
            try await saveExchangeRates(rates)
        }
    }
}

/// 演示账本里的东西
enum DemoSeed {
    /// 账户加了多少天、放多少天的汇率
    static let days = 30

    /// 招行借记卡、恒生多币种卡（港币、人民币、美元）、中行信用卡、微信、支付宝、现金。名称按 App 的语言显示
    static let accounts: [AccountDraft] = [
        AccountDraft(
            name: "", bankID: "cmb", bankName: "招商银行", last4: "2046", cardType: .debit, currency: .cny,
            paletteID: "graphite-gold", openingBalanceMinor: 1_248_000
        ),
        AccountDraft(
            name: "", bankID: "hangseng", bankName: "恒生银行", last4: "0618", cardType: .debit, currency: .hkd,
            paletteID: "forest", openingBalanceMinor: 862_000, extraCurrencies: [.cny, .usd],
            extraOpeningBalances: [.cny: 350_000, .usd: 41_236]
        ),
        AccountDraft(
            name: "", bankID: "boc", bankName: "中国银行", last4: "7315", cardType: .credit, currency: .cny,
            paletteID: "crimson", openingBalanceMinor: -298_630
        ),
        .pocket(name: "微信支付", type: .wallet, currency: .cny, paletteID: "jade", openingBalanceMinor: 23_650, walletID: "wechatpay"),
        .pocket(name: "支付宝", type: .wallet, currency: .cny, paletteID: "ocean", openingBalanceMinor: 86_000, walletID: "alipay"),
        .pocket(name: "现金", type: .cash, currency: .cny, paletteID: "sunset", openingBalanceMinor: 68_000),
    ]

    /// 1 美元换多少，每天有一点点波动
    static let baseRates: [String: Double] = [
        "CNY": 7.118, "HKD": 7.771, "JPY": 151.4, "EUR": 0.921, "GBP": 0.786, "TWD": 32.18, "MOP": 8.004,
        "SGD": 1.339, "AUD": 1.532, "CAD": 1.388, "KRW": 1392, "THB": 34.8, "NZD": 1.671, "CHF": 0.861,
    ]

    /// 最近 `days` 天，每天早上 8 点一份（和快捷指令每天导入的一样），不晚于 `end`
    static func rates(until end: Date, calendar: Calendar) -> [ExchangeRates] {
        let today = calendar.startOfDay(for: end)
        var list: [ExchangeRates] = []
        for back in stride(from: days, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let updated = day.addingTimeInterval(8 * 3600)
            guard updated <= end else { continue }
            var rates: [String: Double] = ["USD": 1]
            for (offset, (code, value)) in baseRates.sorted(by: { $0.key < $1.key }).enumerated() {
                let wave = sin(Double(back) * 0.37 + Double(offset)) * 0.004 + sin(Double(back) * 0.11 + Double(offset) * 2) * 0.006
                rates[code] = (value * (1 + wave) * 10_000).rounded() / 10_000
            }
            list.append(ExchangeRates(base: .usd, rates: rates, updatedAt: updated, fetchedAt: updated.addingTimeInterval(300)))
        }
        return list
    }
}
