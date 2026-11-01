import Foundation

/// 已知银行的识别线索。只用来判断「这条通知来自哪家银行」，帮助同尾号账户消歧。
/// 短信号码、签名和邮箱域名是公开信息，不保证覆盖银行的全部发送渠道；
/// 设置邮件自动化时应以用户收到的实际发件地址为准。
public struct BankProfile: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var smsNumbers: [String]
    public var signatures: [String]
    public var emailDomains: [String]
    public var defaultPaletteID: String

    public init(id: String, name: String, smsNumbers: [String], signatures: [String], emailDomains: [String], defaultPaletteID: String) {
        self.id = id
        self.name = name
        self.smsNumbers = smsNumbers
        self.signatures = signatures
        self.emailDomains = emailDomains
        self.defaultPaletteID = defaultPaletteID
    }
}

public enum BankDirectory {
    public static let all: [BankProfile] = [
        BankProfile(id: "cmb", name: "招商银行", smsNumbers: ["95555"], signatures: ["招商银行", "招行"], emailDomains: ["cmbchina.com"], defaultPaletteID: "graphite-gold"),
        BankProfile(id: "icbc", name: "工商银行", smsNumbers: ["95588"], signatures: ["工商银行", "中国工商银行", "工银"], emailDomains: ["icbc.com.cn"], defaultPaletteID: "crimson"),
        BankProfile(id: "ccb", name: "建设银行", smsNumbers: ["95533"], signatures: ["建设银行", "中国建设银行"], emailDomains: ["ccb.com"], defaultPaletteID: "ocean"),
        BankProfile(id: "boc", name: "中国银行", smsNumbers: ["95566"], signatures: ["中国银行"], emailDomains: ["boc.cn", "bankofchina.com"], defaultPaletteID: "autumn-gold"),
        BankProfile(id: "abc", name: "农业银行", smsNumbers: ["95599"], signatures: ["农业银行", "中国农业银行"], emailDomains: ["abchina.com"], defaultPaletteID: "jade"),
        BankProfile(id: "bocom", name: "交通银行", smsNumbers: ["95559"], signatures: ["交通银行"], emailDomains: ["bankcomm.com"], defaultPaletteID: "ocean"),
        BankProfile(id: "psbc", name: "邮储银行", smsNumbers: ["95580"], signatures: ["邮储银行", "中国邮政储蓄银行"], emailDomains: ["psbc.com"], defaultPaletteID: "jade"),
        BankProfile(id: "cib", name: "兴业银行", smsNumbers: ["95561"], signatures: ["兴业银行"], emailDomains: ["cib.com.cn"], defaultPaletteID: "ocean"),
        BankProfile(id: "citic", name: "中信银行", smsNumbers: ["95558"], signatures: ["中信银行"], emailDomains: ["citicbank.com"], defaultPaletteID: "crimson"),
        BankProfile(id: "spdb", name: "浦发银行", smsNumbers: ["95528"], signatures: ["浦发银行"], emailDomains: ["spdb.com.cn"], defaultPaletteID: "midnight"),
        BankProfile(id: "cmbc", name: "民生银行", smsNumbers: ["95568"], signatures: ["民生银行"], emailDomains: ["cmbc.com.cn"], defaultPaletteID: "jade"),
        BankProfile(id: "ceb", name: "光大银行", smsNumbers: ["95595"], signatures: ["光大银行"], emailDomains: ["cebbank.com"], defaultPaletteID: "violet"),
        BankProfile(id: "pab", name: "平安银行", smsNumbers: ["95511"], signatures: ["平安银行"], emailDomains: ["pingan.com.cn"], defaultPaletteID: "sunset"),
        BankProfile(id: "cgb", name: "广发银行", smsNumbers: ["95508"], signatures: ["广发银行"], emailDomains: ["cgbchina.com.cn"], defaultPaletteID: "crimson"),
        BankProfile(id: "hxb", name: "华夏银行", smsNumbers: ["95577"], signatures: ["华夏银行"], emailDomains: ["hxb.com.cn"], defaultPaletteID: "crimson"),
    ]

    public static func profile(id: String?) -> BankProfile? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// 根据短信发件人、邮件发件人和正文签名识别银行。识别不出返回 nil，不猜。
    public static func identify(sender: String?, text: String) -> String? {
        if let sender, !sender.isEmpty {
            let digits = String(sender.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }.map(Character.init))
            if !digits.isEmpty, digits.count <= 16 {
                for bank in all where bank.smsNumbers.contains(where: { digits.hasSuffix($0) }) {
                    return bank.id
                }
            }
            let lowered = sender.lowercased()
            if let at = lowered.lastIndex(of: "@") {
                let domain = lowered[lowered.index(after: at)...].trimmingCharacters(in: CharacterSet(charactersIn: "> "))
                for bank in all where bank.emailDomains.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) {
                    return bank.id
                }
            }
        }
        // 正文签名：【招商银行】或 [招商银行]；取最长匹配，避免「中国银行」误配「中国工商银行」的情况
        var best: (id: String, length: Int)?
        for bank in all {
            for signature in bank.signatures {
                for wrapped in ["【\(signature)】", "[\(signature)]", "［\(signature)］"] where text.contains(wrapped) {
                    if best == nil || wrapped.count > best!.length { best = (bank.id, wrapped.count) }
                }
            }
        }
        return best?.id
    }
}

/// 电子钱包（支付宝、微信支付……）发的通知：认得出是哪个钱包时，没写卡号尾号的那笔记到这个钱包账户。
/// 标识和添加账户时选的「银行」（`BankCatalog`）相同。只看发件人和正文开头的署名，
/// 不看正文里提到的「财付通」「支付宝」：银行短信里常写着「在财付通-美团消费」，那是银行卡的交易。
public struct WalletProfile: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// 短信号码
    public var smsNumbers: [String]
    /// 发件人（App 通知的 App 名称、邮件发件人）里出现这些名称就是它；小写比较
    public var senderNames: [String]
    /// 正文开头的署名（「【支付宝】」「微信支付」）
    public var signatures: [String]
    /// 用户没选钱包时，按账户名称猜：名称里有这些字的电子钱包账户算它
    public var accountNames: [String]
}

public enum WalletDirectory {
    /// 名称长的在前：「支付宝香港」先于「支付宝」
    public static let all: [WalletProfile] = [
        WalletProfile(id: "alipayhk", name: "AlipayHK", smsNumbers: [], senderNames: ["alipayhk", "支付宝香港", "支付寶香港"],
                      signatures: ["AlipayHK", "支付宝香港", "支付寶香港"], accountNames: ["alipayhk", "支付宝香港", "支付寶香港"]),
        WalletProfile(id: "wechatpayhk", name: "WeChat Pay HK", smsNumbers: [], senderNames: ["wechat pay hk", "微信支付香港"],
                      signatures: ["WeChat Pay HK", "微信支付香港"], accountNames: ["wechat pay hk", "微信支付香港", "微信香港"]),
        WalletProfile(id: "alipay", name: "支付宝", smsNumbers: ["95188"], senderNames: ["支付宝", "支付寶", "alipay"],
                      signatures: ["支付宝", "支付寶", "Alipay"], accountNames: ["支付宝", "支付寶", "alipay", "余额宝"]),
        WalletProfile(id: "wechatpay", name: "微信支付", smsNumbers: [], senderNames: ["微信支付", "wechat pay"],
                      signatures: ["微信支付", "WeChat Pay"], accountNames: ["微信", "wechat", "零钱"]),
    ]

    public static func profile(id: String?) -> WalletProfile? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// 发件人或正文开头认出的钱包；认不出返回 nil，不猜
    public static func identify(sender: String?, text: String) -> String? {
        if let sender, !sender.isEmpty {
            let digits = String(sender.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }.map(Character.init))
            if !digits.isEmpty, digits.count <= 16, let found = all.first(where: { $0.smsNumbers.contains { digits.hasSuffix($0) } }) {
                return found.id
            }
            let lowered = sender.lowercased()
            if let found = all.first(where: { $0.senderNames.contains { lowered.contains($0) } }) { return found.id }
        }
        let head = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        for wallet in all {
            for signature in wallet.signatures {
                let wrapped = ["【\(signature)】", "[\(signature)]", "［\(signature)］"]
                if wrapped.contains(where: { head.hasPrefix($0) || text.contains($0) }) { return wallet.id }
                if head.hasPrefix(signature) { return wallet.id }
            }
        }
        return nil
    }

    /// 电子钱包账户是哪个钱包：添加时选的，没选就按名称猜（以前添加的账户没有选）
    public static func provider(of account: Account) -> String? {
        guard account.cardType == .wallet else { return nil }
        if let id = account.bankID, profile(id: id) != nil { return id }
        let names = [account.name, account.bankName].map { $0.lowercased() }
        return all.first { wallet in wallet.accountNames.contains { key in names.contains { $0.contains(key) } } }?.id
    }
}
