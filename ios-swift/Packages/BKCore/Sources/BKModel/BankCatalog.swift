import Foundation

/// 添加银行卡时按名称找银行：中文全称、简称、繁体、英文缩写和当地语言都能搜到，选中后保存中文全称。
/// 主要用来填写银行；识别通知来自哪家银行的线索在 `BankDirectory`（同一家银行的标识相同），名录里没有的银行按【署名】在这里找。
public struct BankEntry: Hashable, Sendable, Identifiable {
    public var id: String
    /// 保存和显示用的名称（简体中文全称）
    public var name: String
    /// 英文或当地语言的名称
    public var localName: String
    public var region: String
    /// 卡面圆标里的字
    public var badge: String
    /// 默认卡面配色
    public var paletteID: String?
    /// 其他叫法：简称、繁体、缩写、当地语言
    public var aliases: [String]

    public init(id: String, name: String, localName: String, region: String, badge: String, paletteID: String?, aliases: [String]) {
        self.id = id
        self.name = name
        self.localName = localName
        self.region = region
        self.badge = badge
        self.paletteID = paletteID
        self.aliases = aliases
    }
}

public enum BankCatalog {
    public static func entry(id: String?) -> BankEntry? {
        guard let id else { return nil }
        return byID[id]
    }

    /// 按输入找银行，最像的在前。名称完全一样 > 开头一样 > 包含；同样像时内地和港澳台的银行在前
    public static func search(_ query: String, limit: Int = 8) -> [BankEntry] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }
        let latin = q.unicodeScalars.allSatisfy { $0.isASCII }
        var scored: [(score: Int, rank: Int, entry: BankEntry)] = []
        for item in index {
            var best = Int.max
            for key in item.keys {
                if key == q { best = 0; break }
                if key.hasPrefix(q) { best = min(best, 1) } else if key.contains(q) { best = min(best, 2) }
            }
            // 拼音：全拼或首字母的开头，例如 zhaoshang、zsyh
            if best == Int.max, latin, q.count >= 2, item.pinyin.contains(where: { $0.hasPrefix(q) }) { best = 3 }
            if best < Int.max { scored.append((best, item.rank, item.entry)) }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score < b.score }
            if a.rank != b.rank { return a.rank < b.rank }
            return a.entry.name.count < b.entry.name.count
        }
        return scored.prefix(limit).map(\.entry)
    }

    /// 名称或某个叫法和输入完全一样、而且只有一家银行对得上时返回它
    public static func exactMatch(_ text: String) -> BankEntry? {
        let q = normalize(text)
        guard !q.isEmpty else { return nil }
        let hits = index.filter { $0.keys.contains(q) }
        return hits.count == 1 ? hits[0].entry : nil
    }

    /// 通知的【署名】是哪家银行：名称或某个叫法完全一样、而且只有一家对得上。
    /// 署名已经整理过，不用 `index`：它要算拼音，识别通知时不值得
    public static func entry(signature: String) -> BankEntry? {
        let hits = all.filter { $0.name == signature || $0.aliases.contains(signature) }
        return hits.count == 1 ? hits[0] : nil
    }

    /// 比较用：不分大小写、全角半角、重音，去掉空格和标点；在 Apple 系统上繁体转成简体
    public static func normalize(_ text: String) -> String {
        var folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        #if canImport(Darwin)
        if let simplified = folded.applyingTransform(StringTransform(rawValue: "Hant-Hans"), reverse: false) { folded = simplified }
        #endif
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    private struct Indexed: Sendable {
        var entry: BankEntry
        var keys: [String]
        var pinyin: [String]
        var rank: Int
    }

    private static let regionOrder = ["中国内地", "中国香港", "中国澳门", "中国台湾"]

    private static let index: [Indexed] = all.map { entry in
        let names = [entry.name, entry.localName] + entry.aliases
        var keys: [String] = []
        for name in names {
            let key = normalize(name)
            if !key.isEmpty, !keys.contains(key) { keys.append(key) }
        }
        let rank = regionOrder.firstIndex(of: entry.region) ?? regionOrder.count
        return Indexed(entry: entry, keys: keys, pinyin: pinyin(names), rank: rank)
    }

    /// 中文名称的拼音全拼和首字母（只在 Apple 系统上有）
    private static func pinyin(_ names: [String]) -> [String] {
        #if canImport(Darwin)
        var result: [String] = []
        for name in names where name.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) {
            guard let latin = name.applyingTransform(.mandarinToLatin, reverse: false)?
                .applyingTransform(.stripDiacritics, reverse: false)?.lowercased() else { continue }
            let syllables = latin.split(whereSeparator: { !$0.isLetter })
            result.append(syllables.joined())
            result.append(String(syllables.compactMap(\.first)))
        }
        return result
        #else
        return []
        #endif
    }

    private static let byID: [String: BankEntry] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    private static func bank(_ id: String, _ name: String, _ localName: String, _ region: String, _ badge: String, _ palette: String?, _ aliases: [String]) -> BankEntry {
        BankEntry(id: id, name: name, localName: localName, region: region, badge: badge, paletteID: palette, aliases: aliases)
    }

    // 前 15 家的标识与 `BankDirectory` 一致
    public static let all: [BankEntry] = [
        // 中国内地
        bank("icbc", "中国工商银行", "Industrial and Commercial Bank of China", "中国内地", "工", "crimson", ["工商银行", "工行", "ICBC", "中國工商銀行", "工銀"]),
        bank("ccb", "中国建设银行", "China Construction Bank", "中国内地", "建", "ocean", ["建设银行", "建行", "CCB", "中國建設銀行"]),
        bank("abc", "中国农业银行", "Agricultural Bank of China", "中国内地", "农", "jade", ["农业银行", "农行", "ABC", "中國農業銀行"]),
        bank("boc", "中国银行", "Bank of China", "中国内地", "中", "autumn-gold", ["中行", "BOC", "中國銀行"]),
        bank("bocom", "交通银行", "Bank of Communications", "中国内地", "交", "ocean", ["交行", "BOCOM", "BoCom", "交通銀行"]),
        bank("psbc", "中国邮政储蓄银行", "Postal Savings Bank of China", "中国内地", "邮", "jade", ["邮储银行", "邮政储蓄银行", "邮储", "邮政银行", "PSBC", "中國郵政儲蓄銀行"]),
        bank("cmb", "招商银行", "China Merchants Bank", "中国内地", "招", "graphite-gold", ["招行", "CMB", "招商銀行"]),
        bank("cib", "兴业银行", "Industrial Bank", "中国内地", "兴", "ocean", ["兴业", "CIB", "興業銀行"]),
        bank("citic", "中信银行", "China CITIC Bank", "中国内地", "信", "crimson", ["中信", "CITIC", "中信銀行"]),
        bank("spdb", "上海浦东发展银行", "Shanghai Pudong Development Bank", "中国内地", "浦", "midnight", ["浦发银行", "浦发", "SPDB", "上海浦東發展銀行", "浦發銀行"]),
        bank("cmbc", "中国民生银行", "China Minsheng Bank", "中国内地", "民", "jade", ["民生银行", "民生", "CMBC", "中國民生銀行"]),
        bank("ceb", "中国光大银行", "China Everbright Bank", "中国内地", "光", "violet", ["光大银行", "光大", "CEB", "中國光大銀行"]),
        bank("pab", "平安银行", "Ping An Bank", "中国内地", "平", "sunset", ["平安", "平安銀行"]),
        bank("cgb", "广发银行", "China Guangfa Bank", "中国内地", "广", "crimson", ["广发", "CGB", "廣發銀行"]),
        bank("hxb", "华夏银行", "Hua Xia Bank", "中国内地", "华", "crimson", ["华夏", "HXB", "華夏銀行"]),
        bank("czb", "浙商银行", "China Zheshang Bank", "中国内地", "浙", "crimson", ["浙商", "CZB", "浙商銀行"]),
        bank("cbhb", "渤海银行", "China Bohai Bank", "中国内地", "渤", "ocean", ["渤海", "CBHB", "渤海銀行"]),
        bank("hfb", "恒丰银行", "Hengfeng Bank", "中国内地", "恒", "ocean", ["恒丰", "恆豐銀行"]),
        bank("bob", "北京银行", "Bank of Beijing", "中国内地", "京", "crimson", ["北京銀行"]),
        bank("bosc", "上海银行", "Bank of Shanghai", "中国内地", "沪", "ocean", ["上海銀行", "BOSC"]),
        bank("jsbank", "江苏银行", "Bank of Jiangsu", "中国内地", "苏", "ocean", ["江蘇銀行"]),
        bank("njcb", "南京银行", "Bank of Nanjing", "中国内地", "宁", "crimson", ["南京銀行"]),
        bank("nbcb", "宁波银行", "Bank of Ningbo", "中国内地", "甬", "autumn-gold", ["寧波銀行"]),
        bank("hzbank", "杭州银行", "Bank of Hangzhou", "中国内地", "杭", "ocean", ["杭州銀行"]),
        bank("hsbank", "徽商银行", "Huishang Bank", "中国内地", "徽", "crimson", ["徽商銀行"]),
        bank("cqbank", "重庆银行", "Bank of Chongqing", "中国内地", "渝", "ocean", ["重慶銀行"]),
        bank("cdbank", "成都银行", "Bank of Chengdu", "中国内地", "蓉", "crimson", ["成都銀行"]),
        bank("tjbank", "天津银行", "Bank of Tianjin", "中国内地", "津", "ocean", ["天津銀行"]),
        bank("qdbank", "青岛银行", "Bank of Qingdao", "中国内地", "青", "ocean", ["青島銀行"]),
        bank("xmbank", "厦门银行", "Xiamen Bank", "中国内地", "厦", "ocean", ["廈門銀行"]),
        bank("szbank", "苏州银行", "Bank of Suzhou", "中国内地", "苏", "jade", ["蘇州銀行"]),
        bank("gzbank", "广州银行", "Bank of Guangzhou", "中国内地", "广", "crimson", ["廣州銀行"]),
        bank("csbank", "长沙银行", "Bank of Changsha", "中国内地", "长", "crimson", ["長沙銀行"]),
        bank("zzbank", "郑州银行", "Bank of Zhengzhou", "中国内地", "郑", "crimson", ["鄭州銀行"]),
        bank("xabank", "西安银行", "Bank of Xi'an", "中国内地", "西", "crimson", ["西安銀行"]),
        bank("hrbbank", "哈尔滨银行", "Harbin Bank", "中国内地", "哈", "crimson", ["哈爾濱銀行"]),
        bank("sjbank", "盛京银行", "Shengjing Bank", "中国内地", "盛", "crimson", ["盛京銀行"]),
        bank("qlbank", "齐鲁银行", "Qilu Bank", "中国内地", "齐", "ocean", ["齊魯銀行"]),
        bank("dgbank", "东莞银行", "Dongguan Bank", "中国内地", "莞", "crimson", ["東莞銀行"]),
        bank("gybank", "贵阳银行", "Bank of Guiyang", "中国内地", "贵", "crimson", ["貴陽銀行"]),
        bank("bjrcb", "北京农商银行", "Beijing Rural Commercial Bank", "中国内地", "京", "jade", ["北京农村商业银行", "北京農商銀行"]),
        bank("srcb", "上海农商银行", "Shanghai Rural Commercial Bank", "中国内地", "沪", "jade", ["上海农村商业银行", "上海農商銀行"]),
        bank("grcb", "广州农商银行", "Guangzhou Rural Commercial Bank", "中国内地", "广", "jade", ["广州农村商业银行", "廣州農商銀行"]),
        bank("szrcb", "深圳农商银行", "Shenzhen Rural Commercial Bank", "中国内地", "深", "jade", ["深圳农村商业银行", "深圳農商銀行"]),
        bank("cqrcb", "重庆农商银行", "Chongqing Rural Commercial Bank", "中国内地", "渝", "jade", ["重庆农村商业银行", "重慶農商銀行"]),
        bank("rcc", "农村信用社", "Rural Credit Cooperative", "中国内地", "信", "jade", ["信用社", "农信社", "農村信用社"]),
        bank("webank", "微众银行", "WeBank", "中国内地", "微", "ocean", ["深圳前海微众银行", "微眾銀行"]),
        bank("mybank", "网商银行", "MYbank", "中国内地", "网", "ocean", ["浙江网商银行", "網商銀行"]),
        bank("xwbank", "新网银行", "XW Bank", "中国内地", "新", "ocean", ["四川新网银行", "新網銀行"]),
        bank("aibank", "百信银行", "aiBank", "中国内地", "百", "crimson", ["中信百信银行", "百信銀行"]),
        bank("alipay", "支付宝", "Alipay", "中国内地", "支", "ocean", ["支付寶", "余额宝", "花呗"]),
        bank("wechatpay", "微信支付", "WeChat Pay", "中国内地", "微", "jade", ["微信", "微信零钱", "零钱通", "财付通", "財付通"]),

        // 中国香港
        bank("hsbc", "香港上海汇丰银行", "HSBC", "中国香港", "汇", "crimson", ["汇丰银行", "汇丰", "滙豐銀行", "滙豐", "匯豐銀行", "匯豐", "香港上海滙豐銀行", "The Hongkong and Shanghai Banking Corporation", "HSBC UK"]),
        bank("hangseng", "恒生银行", "Hang Seng Bank", "中国香港", "恒", "jade", ["恒生", "恒生銀行"]),
        bank("bochk", "中国银行（香港）", "Bank of China (Hong Kong)", "中国香港", "中", "crimson", ["中银香港", "中銀香港", "中國銀行(香港)", "BOCHK"]),
        bank("scb", "渣打银行", "Standard Chartered", "中国香港", "渣", "ocean", ["渣打", "渣打銀行", "渣打银行（香港）", "SC"]),
        bank("bea", "东亚银行", "The Bank of East Asia", "中国香港", "东", "crimson", ["東亞銀行", "东亚", "BEA"]),
        bank("icbcasia", "中国工商银行（亚洲）", "ICBC (Asia)", "中国香港", "工", "crimson", ["工银亚洲", "工銀亞洲", "中國工商銀行(亞洲)"]),
        bank("ccbasia", "中国建设银行（亚洲）", "China Construction Bank (Asia)", "中国香港", "建", "ocean", ["建行亚洲", "建行亞洲", "中國建設銀行(亞洲)"]),
        bank("cncbi", "中信银行（国际）", "China CITIC Bank International", "中国香港", "信", "crimson", ["信银国际", "信銀國際", "中信銀行(國際)"]),
        bank("cmbwl", "招商永隆银行", "CMB Wing Lung Bank", "中国香港", "永", "graphite-gold", ["永隆银行", "永隆銀行", "招商永隆銀行", "Wing Lung"]),
        bank("dahsing", "大新银行", "Dah Sing Bank", "中国香港", "大", "ocean", ["大新", "大新銀行"]),
        bank("chonghing", "创兴银行", "Chong Hing Bank", "中国香港", "创", "crimson", ["創興銀行", "创兴"]),
        bank("fubonhk", "富邦银行（香港）", "Fubon Bank (Hong Kong)", "中国香港", "富", "ocean", ["富邦銀行(香港)", "富邦香港"]),
        bank("shacom", "上海商业银行", "Shanghai Commercial Bank", "中国香港", "上", "crimson", ["上海商業銀行", "上商"]),
        bank("ncb", "南洋商业银行", "Nanyang Commercial Bank", "中国香港", "南", "crimson", ["南洋商業銀行", "南商"]),
        bank("chiyu", "集友银行", "Chiyu Banking Corporation", "中国香港", "集", "crimson", ["集友銀行"]),
        bank("bocomhk", "交通银行（香港）", "Bank of Communications (Hong Kong)", "中国香港", "交", "ocean", ["交通銀行(香港)", "交银香港"]),
        bank("publichk", "大众银行（香港）", "Public Bank (Hong Kong)", "中国香港", "众", "crimson", ["大眾銀行(香港)"]),
        bank("aeonhk", "AEON 信贷财务", "AEON Credit Service (Asia)", "中国香港", "A", "violet", ["AEON", "永旺", "AEON信貸財務"]),
        bank("zabank", "众安银行", "ZA Bank", "中国香港", "众", "lagoon", ["眾安銀行", "ZA"]),
        bank("mox", "Mox Bank", "Mox Bank", "中国香港", "M", "midnight", ["Mox"]),
        bank("welab", "汇立银行", "WeLab Bank", "中国香港", "汇", "violet", ["匯立銀行", "WeLab"]),
        bank("livi", "理慧银行", "livi bank", "中国香港", "理", "sunset", ["理慧銀行", "livi"]),
        bank("airstar", "天星银行", "Airstar Bank", "中国香港", "天", "ocean", ["天星銀行", "Airstar"]),
        bank("fusionbank", "富融银行", "Fusion Bank", "中国香港", "富", "violet", ["富融銀行", "Fusion"]),
        bank("paob", "平安壹账通银行", "PAO Bank", "中国香港", "平", "sunset", ["平安壹賬通銀行", "PAOB"]),
        bank("antbankhk", "蚂蚁银行（香港）", "Ant Bank (Hong Kong)", "中国香港", "蚁", "ocean", ["螞蟻銀行", "蚂蚁银行"]),
        bank("alipayhk", "AlipayHK", "AlipayHK", "中国香港", "支", "ocean", ["支付宝香港", "支付寶香港"]),
        bank("wechatpayhk", "WeChat Pay HK", "WeChat Pay HK", "中国香港", "微", "jade", ["微信支付香港"]),
        bank("payme", "PayMe", "PayMe from HSBC", "中国香港", "P", "crimson", ["PayMe"]),
        bank("octopus", "八达通", "Octopus", "中国香港", "八", "autumn-gold", ["八達通"]),

        // 中国澳门
        bank("bnu", "大西洋银行", "Banco Nacional Ultramarino", "中国澳门", "大", "ocean", ["大西洋銀行", "BNU"]),
        bank("luso", "澳门国际银行", "Luso International Banking", "中国澳门", "澳", "crimson", ["澳門國際銀行", "Luso"]),
        bank("bocmacau", "中国银行澳门分行", "Bank of China Macau Branch", "中国澳门", "中", "crimson", ["中银澳门", "中銀澳門", "中國銀行澳門分行"]),
        bank("taifung", "大丰银行", "Tai Fung Bank", "中国澳门", "丰", "crimson", ["大豐銀行"]),
        bank("bcm", "澳门商业银行", "Banco Comercial de Macau", "中国澳门", "商", "ocean", ["澳門商業銀行", "BCM"]),
        bank("icbcmacau", "中国工商银行（澳门）", "ICBC (Macau)", "中国澳门", "工", "crimson", ["工银澳门", "工銀澳門", "中國工商銀行(澳門)"]),
        bank("mpay", "澳门钱包", "MPay", "中国澳门", "M", "lagoon", ["MPay", "澳門錢包", "澳门通", "澳門通"]),

        // 中国台湾
        bank("bot", "台湾银行", "Bank of Taiwan", "中国台湾", "台", "ocean", ["臺灣銀行", "台灣銀行", "台银", "台銀"]),
        bank("ctbc", "中国信托商业银行", "CTBC Bank", "中国台湾", "信", "jade", ["中國信託", "中国信托", "中國信託商業銀行"]),
        bank("cathaybk", "国泰世华商业银行", "Cathay United Bank", "中国台湾", "国", "forest", ["国泰世华", "國泰世華", "國泰世華銀行"]),
        bank("esun", "玉山商业银行", "E.SUN Bank", "中国台湾", "玉", "jade", ["玉山银行", "玉山銀行", "玉山"]),
        bank("fubontw", "台北富邦商业银行", "Taipei Fubon Bank", "中国台湾", "富", "ocean", ["台北富邦", "台北富邦銀行"]),
        bank("megabank", "兆丰国际商业银行", "Mega International Commercial Bank", "中国台湾", "兆", "crimson", ["兆丰银行", "兆豐銀行", "兆豐"]),
        bank("firstbank", "第一商业银行", "First Commercial Bank", "中国台湾", "一", "autumn-gold", ["第一银行", "第一銀行"]),
        bank("hncb", "华南商业银行", "Hua Nan Commercial Bank", "中国台湾", "华", "crimson", ["华南银行", "華南銀行"]),
        bank("landbank", "台湾土地银行", "Land Bank of Taiwan", "中国台湾", "土", "jade", ["土地银行", "臺灣土地銀行", "土地銀行"]),
        bank("taishin", "台新国际商业银行", "Taishin International Bank", "中国台湾", "新", "crimson", ["台新银行", "台新銀行"]),
        bank("post-tw", "中华邮政", "Chunghwa Post", "中国台湾", "邮", "jade", ["中華郵政", "郵局"]),

        // 新加坡、马来西亚
        bank("dbs", "星展银行", "DBS Bank", "新加坡", "星", "crimson", ["星展", "星展銀行", "DBS", "POSB"]),
        bank("ocbc", "华侨银行", "OCBC Bank", "新加坡", "侨", "crimson", ["華僑銀行", "OCBC", "永亨银行", "永亨銀行"]),
        bank("uob", "大华银行", "United Overseas Bank", "新加坡", "华", "midnight", ["大華銀行", "UOB"]),
        bank("maybank", "马来亚银行", "Maybank", "马来西亚", "M", "autumn-gold", ["馬來亞銀行"]),
        bank("cimb", "联昌国际银行", "CIMB Bank", "马来西亚", "C", "crimson", ["聯昌國際銀行", "CIMB"]),
        bank("publicbank", "大众银行", "Public Bank", "马来西亚", "众", "crimson", ["大眾銀行"]),

        // 美国、加拿大
        bank("citi", "花旗银行", "Citibank", "美国", "花", "ocean", ["花旗", "花旗銀行", "Citi"]),
        bank("chase", "摩根大通银行", "JPMorgan Chase Bank", "美国", "大", "ocean", ["摩根大通", "大通银行", "Chase", "JPMorgan"]),
        bank("bofa", "美国银行", "Bank of America", "美国", "美", "crimson", ["美國銀行", "BofA", "BoA"]),
        bank("wellsfargo", "富国银行", "Wells Fargo", "美国", "富", "crimson", ["富國銀行"]),
        bank("capitalone", "第一资本", "Capital One", "美国", "C", "midnight", ["第一資本"]),
        bank("usbank", "合众银行", "U.S. Bank", "美国", "U", "ocean", ["美國合眾銀行", "美国合众银行"]),
        bank("pnc", "PNC 银行", "PNC Bank", "美国", "P", "sunset", ["PNC"]),
        bank("amex", "美国运通", "American Express", "美国", "运", "ocean", ["美國運通", "Amex", "AE"]),
        bank("schwab", "嘉信理财", "Charles Schwab", "美国", "嘉", "lagoon", ["嘉信理財", "Schwab"]),
        bank("discover", "Discover", "Discover", "美国", "D", "sunset", ["发现卡", "發現卡"]),
        bank("applecard", "Apple Card", "Apple Card", "美国", "A", "midnight", ["苹果信用卡", "Goldman Sachs", "高盛"]),
        bank("rbc", "加拿大皇家银行", "Royal Bank of Canada", "加拿大", "皇", "ocean", ["加拿大皇家銀行", "皇家银行", "RBC"]),
        bank("td", "道明银行", "TD Bank", "加拿大", "道", "forest", ["道明銀行", "Toronto-Dominion", "TD"]),
        bank("scotiabank", "丰业银行", "Scotiabank", "加拿大", "丰", "crimson", ["豐業銀行", "加拿大丰业银行"]),
        bank("bmo", "蒙特利尔银行", "BMO Bank of Montreal", "加拿大", "蒙", "ocean", ["满地可银行", "滿地可銀行", "BMO"]),
        bank("cibc", "加拿大帝国商业银行", "CIBC", "加拿大", "帝", "crimson", ["加拿大帝國商業銀行"]),

        // 欧洲
        bank("barclays", "巴克莱银行", "Barclays", "英国", "巴", "lagoon", ["巴克萊銀行", "巴克莱"]),
        bank("lloyds", "劳埃德银行", "Lloyds Bank", "英国", "劳", "forest", ["勞埃德銀行", "莱斯银行", "Lloyds"]),
        bank("natwest", "国民西敏寺银行", "NatWest", "英国", "西", "violet", ["國民西敏寺銀行", "国民西敏银行"]),
        bank("santander", "桑坦德银行", "Banco Santander", "西班牙", "桑", "crimson", ["桑坦德", "Santander"]),
        bank("bbva", "西班牙对外银行", "BBVA", "西班牙", "B", "ocean", ["毕尔巴鄂比斯开银行", "西班牙對外銀行"]),
        bank("monzo", "Monzo", "Monzo Bank", "英国", "M", "sunset", []),
        bank("revolut", "Revolut", "Revolut", "英国", "R", "midnight", []),
        bank("starling", "Starling Bank", "Starling Bank", "英国", "S", "violet", ["Starling"]),
        bank("wise", "Wise", "Wise", "英国", "W", "lime", ["TransferWise"]),
        bank("deutschebank", "德意志银行", "Deutsche Bank", "德国", "德", "ocean", ["德意志銀行", "德银"]),
        bank("commerzbank", "德国商业银行", "Commerzbank", "德国", "商", "autumn-gold", ["德國商業銀行"]),
        bank("sparkasse", "德国储蓄银行", "Sparkasse", "德国", "S", "crimson", ["德國儲蓄銀行"]),
        bank("n26", "N26", "N26", "德国", "N", "lagoon", []),
        bank("ing", "荷兰国际集团", "ING", "荷兰", "I", "sunset", ["荷蘭國際集團", "ING Bank"]),
        bank("abnamro", "荷兰银行", "ABN AMRO", "荷兰", "荷", "jade", ["荷蘭銀行"]),
        bank("rabobank", "荷兰合作银行", "Rabobank", "荷兰", "合", "ocean", ["荷蘭合作銀行"]),
        bank("bnpparibas", "法国巴黎银行", "BNP Paribas", "法国", "巴", "forest", ["法國巴黎銀行", "法巴"]),
        bank("socgen", "法国兴业银行", "Société Générale", "法国", "兴", "crimson", ["法國興業銀行", "SocGen"]),
        bank("creditagricole", "法国农业信贷银行", "Crédit Agricole", "法国", "农", "jade", ["法國農業信貸銀行", "东方汇理"]),
        bank("ubs", "瑞银", "UBS", "瑞士", "瑞", "crimson", ["瑞銀", "瑞士银行", "瑞银集团"]),
        bank("postfinance", "瑞士邮政银行", "PostFinance", "瑞士", "邮", "autumn-gold", ["瑞士郵政銀行"]),
        bank("unicredit", "裕信银行", "UniCredit", "意大利", "裕", "crimson", ["裕信銀行"]),
        bank("intesa", "联合圣保罗银行", "Intesa Sanpaolo", "意大利", "圣", "jade", ["聯合聖保羅銀行"]),

        // 日本、韩国
        bank("mufg", "三菱日联银行", "MUFG Bank", "日本", "三", "crimson", ["三菱UFJ銀行", "三菱UFJ", "三菱日聯銀行", "三菱東京UFJ銀行"]),
        bank("smbc", "三井住友银行", "Sumitomo Mitsui Banking Corporation", "日本", "住", "forest", ["三井住友銀行", "SMBC"]),
        bank("mizuho", "瑞穗银行", "Mizuho Bank", "日本", "瑞", "midnight", ["みずほ銀行", "みずほ", "瑞穗銀行"]),
        bank("japanpost", "日本邮政银行", "Japan Post Bank", "日本", "邮", "jade", ["ゆうちょ銀行", "ゆうちょ", "日本郵政"]),
        bank("resona", "理索纳银行", "Resona Bank", "日本", "理", "jade", ["りそな銀行", "りそな"]),
        bank("rakuten", "乐天银行", "Rakuten Bank", "日本", "乐", "crimson", ["楽天銀行", "樂天銀行"]),
        bank("paypaybank", "PayPay 银行", "PayPay Bank", "日本", "P", "crimson", ["PayPay銀行", "PayPay"]),
        bank("sbinet", "住信SBI网络银行", "SBI Sumishin Net Bank", "日本", "S", "ocean", ["住信SBIネット銀行", "住信SBI"]),
        bank("sevenbank", "Seven 银行", "Seven Bank", "日本", "7", "sunset", ["セブン銀行"]),
        bank("kb", "韩国国民银行", "KB Kookmin Bank", "韩国", "国", "autumn-gold", ["KB국민은행", "국민은행", "國民銀行", "国民银行"]),
        bank("shinhan", "新韩银行", "Shinhan Bank", "韩国", "新", "ocean", ["신한은행", "新韓銀行"]),
        bank("hana", "韩亚银行", "Hana Bank", "韩国", "韩", "jade", ["하나은행", "韓亞銀行"]),
        bank("woori", "友利银行", "Woori Bank", "韩国", "友", "ocean", ["우리은행", "友利銀行"]),
        bank("nhbank", "韩国农协银行", "NongHyup Bank", "韩国", "农", "forest", ["NH농협은행", "농협", "農協銀行"]),
        bank("kakaobank", "KakaoBank", "KakaoBank", "韩国", "K", "autumn-gold", ["카카오뱅크"]),
        bank("tossbank", "Toss Bank", "Toss Bank", "韩国", "T", "ocean", ["토스뱅크"]),

        // 澳大利亚、新西兰
        bank("commbank", "澳大利亚联邦银行", "Commonwealth Bank", "澳大利亚", "联", "autumn-gold", ["澳洲聯邦銀行", "联邦银行", "CommBank", "CBA"]),
        bank("westpac", "西太平洋银行", "Westpac", "澳大利亚", "西", "crimson", ["西太平洋銀行", "西太银行"]),
        bank("anz", "澳新银行", "ANZ", "澳大利亚", "澳", "ocean", ["澳新銀行", "澳盛银行"]),
        bank("nab", "澳大利亚国民银行", "National Australia Bank", "澳大利亚", "国", "crimson", ["澳洲國民銀行", "NAB"]),

        // 其他
        bank("kbank", "开泰银行", "Kasikornbank", "泰国", "开", "forest", ["開泰銀行", "KBank", "ธนาคารกสิกรไทย"]),
        bank("bangkokbank", "盘谷银行", "Bangkok Bank", "泰国", "盘", "ocean", ["盤谷銀行", "ธนาคารกรุงเทพ"]),
        bank("scbthai", "泰国汇商银行", "Siam Commercial Bank", "泰国", "汇", "violet", ["泰國匯商銀行", "ไทยพาณิชย์"]),
        bank("bca", "中亚银行", "Bank Central Asia", "印度尼西亚", "B", "ocean", ["中亞銀行", "BCA"]),
        bank("sbi", "印度国家银行", "State Bank of India", "印度", "印", "ocean", ["印度國家銀行", "भारतीय स्टेट बैंक"]),
        bank("hdfc", "HDFC 银行", "HDFC Bank", "印度", "H", "ocean", ["HDFC"]),
        bank("vietcombank", "越南外贸银行", "Vietcombank", "越南", "越", "forest", ["越南外貿銀行", "Ngân hàng Ngoại thương"]),
    ]
}
