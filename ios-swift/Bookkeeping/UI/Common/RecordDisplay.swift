import SwiftUI
import BKModel

/// 流水在列表和详情里怎么显示：标题、图标、金额的正负和颜色。
extension RecordRow {
    var entryType: EntryType { record.entryType }

    /// 支出、收入还没有分类
    var isUncategorized: Bool { entryType != .transfer && category == nil }

    /// 首页合成一行的转帐（两边都在 App 里）
    var isPairedTransfer: Bool { entryType == .transfer && peer != nil }

    /// 标题：备注 → 交易对方 → 分类名 → 类型
    var title: String {
        let note = record.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { return note }
        if let counterparty = record.counterparty, !counterparty.isEmpty { return counterparty }
        if let category { return category.name }
        return record.isRefund ? "退款" : entryType.displayName
    }

    /// 分类那一段文字：小类写「饮食 · 午餐」，没有分类写「待分类」
    var categoryText: String {
        if let category { return category.fullName }
        return isUncategorized ? "待分类" : entryType.displayName
    }

    var symbol: String {
        if let category { return category.symbol }
        return isUncategorized ? "questionmark.circle" : record.kind.symbolName
    }

    /// 金额文字。转帐两边合成一行时不带正负号（钱只是挪了地方），到账和转出不一样时两个都写；合成一单时是整单的金额
    func amountText(inAccount: Bool) -> String {
        let r = record
        let minor = inAccount ? r.amountMinor : orderTotalMinor
        if isPairedTransfer, !inAccount { return transferChange ?? Fmt.money(minor, r.currency) }
        return MoneyFormat.signed(minor, currency: r.currency, direction: r.direction)
    }

    /// 到账和转出不一样（手续费、换汇）：「HK$100.00 → ¥91.00」
    private var transferChange: String? {
        guard let peerMoney, peerMoney != record.money else { return nil }
        let own = Fmt.money(record.amountMinor, record.currency)
        let other = Fmt.money(peerMoney.minorUnits, peerMoney.currency)
        return record.direction == .outflow ? "\(own) → \(other)" : "\(other) → \(own)"
    }

    /// 同一币种的转帐，转出比到账多的部分（手续费）。币种不同（换汇）算不出来
    var transferFeeMinor: Int64? {
        guard let peerMoney, peerMoney.currency == record.currency else { return nil }
        let fee = record.direction == .outflow ? record.amountMinor - peerMoney.minorUnits : peerMoney.minorUnits - record.amountMinor
        return fee > 0 ? fee : nil
    }

    /// 两边是同一个账户（换汇）
    private var isExchange: Bool { peer == account }

    /// 进账（收入、退款、转入）用主题色
    func amountColor(inAccount: Bool) -> AnyShapeStyle {
        if isPairedTransfer, !inAccount { return AnyShapeStyle(Color.secondary) }
        return record.direction == .inflow ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary)
    }

    /// 「招商银行 ·0427 → 工商银行 ·6621」；同一个账户换汇写「恒生银行 ·0004 港币 → 人民币」
    var transferRoute: String? {
        guard let peer, entryType == .transfer else { return nil }
        if isExchange, let peerMoney {
            let (from, to) = record.direction == .outflow ? (record.currency, peerMoney.currency) : (peerMoney.currency, record.currency)
            return "\(account.text) \(from.chineseName) → \(to.chineseName)"
        }
        return record.direction == .outflow ? "\(account.text) → \(peer.text)" : "\(peer.text) → \(account.text)"
    }

    /// 卡片详情里写另一边：「转到 工商银行 ·6621」；同一个账户换汇写「换成人民币」
    var transferSideText: String? {
        guard let peer, entryType == .transfer else { return nil }
        if isExchange, let peerMoney {
            return record.direction == .outflow ? "换成\(peerMoney.currency.chineseName)" : "由\(peerMoney.currency.chineseName)换入"
        }
        return record.direction == .outflow ? "转到 \(peer.text)" : "来自 \(peer.text)"
    }

    /// 合成一单的几张卡：「招商银行 ¥700.00 + 中国银行 ¥300.00」
    var orderText: String? {
        guard orderParts.count > 1 else { return nil }
        return orderParts.map { "\($0.account.cardType.isCard ? $0.account.bankName : $0.account.name) \(Fmt.money($0.amountMinor, $0.currency))" }
            .joined(separator: " + ")
    }
}

extension Account {
    /// 读屏用：「招商银行 借记卡 尾号0427」「现金」
    var spokenTitle: String {
        isCard ? "\(bankName) \(cardType.displayName) 尾号\(last4)" : "\(name) \(cardType.displayName)"
    }
}

extension CardType {
    var symbolName: String {
        switch self {
        case .cash: "banknote"
        case .wallet: "wallet.bifold"
        default: "creditcard"
        }
    }
}

/// 分类图标：圆角方块里的 SF Symbol
struct CategoryIcon: View {
    let symbol: String
    var highlighted = false

    var body: some View {
        Image(systemName: symbol)
            .font(.body)
            .foregroundStyle(highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary))
            .frame(width: 40, height: 40)
            .background(highlighted ? AnyShapeStyle(TintShapeStyle().opacity(0.15)) : AnyShapeStyle(Color.primary.opacity(0.06)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }
}
