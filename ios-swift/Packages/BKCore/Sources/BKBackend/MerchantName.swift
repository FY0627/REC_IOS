import Foundation

/// 从交易对方认出商户，学习分类时当作键（ADR 0017）。同一家店的不同写法要得到同一个键，不是真商户的返回 nil。
///
/// - 支付渠道加商户（「财付通-美团」「支付宝-某某」「WEIXIN*test shop」「PAYPAL *SHOP」）：只留商户；
/// - 卡组织的商户描述带地址（「SHOP TOKYO JPN」「SHOP\1 TEST ROAD\TOKYO\100-00」）：去掉地址、城市、邮编和国家；
/// - 只有渠道或收款码（「财付通」「ALP*QRCode0055」「Scan QR code」）、打码的账号（「100*0001」）、纯数字：不是商户。
///
/// 认不准时宁可学不到一起，也不能把两家店当成一家。
enum MerchantName {
    static func key(_ counterparty: String?) -> String? {
        guard let counterparty else { return nil }
        var text = TextNormalizer.simplifyChinese(TextNormalizer.normalizeWidth(counterparty))
        // 反斜杠后面是地址，省略号后面被截断了
        if let end = text.firstIndex(where: { $0 == "\\" || $0 == "…" }) { text = String(text[..<end]) }
        guard !text.contains("**") else { return nil }

        var name = withoutLocation(text).lowercased()
        name = name.replacingOccurrences(of: #"\s*\([^()]*\)$"#, with: "", options: .regularExpression)
        // 渠道的公司全称，不是商户（「支付宝（中国）网络技术有限公司」）
        if name.hasSuffix("公司"), channels.contains(where: { name.hasPrefix($0) }) { return nil }
        for channel in channels where name.hasPrefix(channel) {
            let rest = name.dropFirst(channel.count).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return nil }
            guard let first = rest.first, separators.contains(first) else { continue }
            name = String(rest.dropFirst())
            break
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " " + separators))

        guard name.count >= 2, name.contains(where: \.isLetter), !collectionCodes.contains(where: { name.contains($0) }) else { return nil }
        // 「某某*」后面是一串码（「TESTPAY*A1B2C3D4E5」「100*0001」）：一个收款通道下面可能是很多家店，不算商户
        if let star = name.firstIndex(of: "*") {
            let after = name[name.index(after: star)...].split(separator: " ").first.map(String.init) ?? ""
            if after.isEmpty || isCode(after) { return nil }
        }
        if !name.contains(" "), isCode(name) { return nil }
        return String(name.prefix(60))
    }

    /// 去掉末尾的国家、邮编和城市。没有国家时不去掉城市：看不出最后一个词是不是地名
    private static func withoutLocation(_ text: String) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if let last = words.last, words.count > 1, isPostcode(last) { words.removeLast() }
        guard let last = words.last, words.count > 1, countries.contains(last) else { return words.joined(separator: " ") }
        words.removeLast()
        if let last = words.last, words.count > 1, isPostcode(last) { words.removeLast() }
        if words.count > 2, longCities.contains(words.suffix(2).joined(separator: " ").uppercased()) {
            words.removeLast(2)
        } else if words.count > 1 {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    /// 5 位以上的数字，或者「100-00」这样中间带横线的
    private static func isPostcode(_ word: String) -> Bool {
        let digits = word.filter { $0 != "-" }
        return digits.count >= 5 && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
    }

    /// 只有 ASCII 字母和数字，并且有数字
    private static func isCode(_ word: String) -> Bool {
        word.contains(where: \.isNumber) && word.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// 支付渠道：后面没有商户时不是商户，后面有商户时只留商户。同一个前缀的长的在前
    private static let channels = [
        "财付通", "支付宝", "微信支付", "微信", "银联在线", "银联", "云闪付", "京东支付", "美团支付", "抖音支付", "网联",
        "tenpay", "wechat pay", "wechatpay", "wechat", "weixin", "wxpay", "alipay", "alp", "paypal", "unionpay",
    ]

    private static let separators = "-—_·:*"

    /// 写着这些的是收款码，不是店名（「Scan QR code」）
    private static let collectionCodes = ["qr code", "qrcode", "二维码", "收款码", "扫码", "扫一扫"]

    /// 卡组织商户描述末尾的国家（大写）
    private static let countries: Set<String> = [
        "CN", "CHN", "HK", "HKG", "MO", "MAC", "TW", "TWN", "JP", "JPN", "KR", "KOR", "SG", "SGP", "TH", "THA", "PH", "PHL", "MY", "MYS",
        "ID", "IDN", "VN", "VNM", "IN", "IND", "US", "USA", "GB", "GBR", "CA", "CAN", "AU", "AUS", "NZ", "NZL", "DE", "DEU", "FR", "FRA",
        "IT", "ITA", "ES", "ESP", "NL", "NLD", "CH", "CHE", "AE", "ARE",
    ]

    /// 两个词的城市（其余的城市按一个词算）
    private static let longCities: Set<String> = ["HONG KONG", "NEW YORK", "LOS ANGELES", "SAN FRANCISCO", "KUALA LUMPUR"]
}
