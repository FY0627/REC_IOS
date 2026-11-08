import Foundation
import BKModel

/// 账本里的名称按选的语言（`AppLanguage`）显示。账本里存的是简体中文（默认分类、银行、现金、电子钱包的名字），
/// 这里只在显示时换；用户自己起的名字不在目录里，原样显示。

extension CurrencyCode {
    /// 简体用习惯叫法（港币、澳元）；台湾用系统的台湾叫法（港幣、澳幣、日圓）；英文用英文名称
    var localizedName: String {
        switch AppLanguage.resolved {
        case .zhHant:
            if let name = Self.taiwanNames[rawValue] { return name }
            if let name = AppLanguage.locale.localizedString(forCurrencyCode: rawValue), name.uppercased() != rawValue { return name }
            return chineseName
        case .english:
            return englishName
        default:
            return chineseName
        }
    }

    /// 系统的台湾叫法和当地习惯不一样的几个
    private static let taiwanNames: [String: String] = [
        "TWD": "新台幣", "CNY": "人民幣", "HKD": "港幣", "MOP": "澳門幣",
    ]
}

extension AccountLabel {
    /// 「招商银行 ·0427」；现金、电子钱包写名称；已删除的账户写上「（已删除）」
    var localizedText: String {
        let base = cardType.isCard ? "\(bankName.loc) ·\(last4)" : name.loc
        return deleted ? L("\(base)（已删除）") : base
    }

    /// 合成一单那行里的简称：银行卡写银行，其他写名称
    var shortName: String { cardType.isCard ? bankName.loc : name.loc }
}

extension Account {
    var localizedTitle: String { label.localizedText }
    var localizedBankName: String { bankName.loc }

    /// 账户名称：银行卡没改过的默认名称（「招商银行信用卡」）按选的语言重新拼，其他按名称查
    var localizedName: String {
        guard isCard, name == Account.defaultName(bankName: bankName, cardType: cardType) else { return name.loc }
        let separator = AppLanguage.resolved == .english ? " " : ""
        return localizedBankName + separator + cardType.displayName.loc
    }
}

extension CategoryLabel {
    var localizedName: String { name.loc }
    /// 「饮食 · 午餐」
    var localizedFullName: String { parentName.map { "\($0.loc) · \(name.loc)" } ?? name.loc }
}

extension LedgerCategory {
    var localizedName: String { name.loc }
}
