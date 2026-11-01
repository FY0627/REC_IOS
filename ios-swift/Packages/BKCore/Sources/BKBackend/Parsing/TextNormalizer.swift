import Foundation

/// 把短信 / 邮件原文整理成便于规则解析的纯文本。不改变语义，只做格式统一。
enum TextNormalizer {
    private static let htmlHint = Rx(#"<\s*(html|body|div|p|br|table|tr|td|th|span|font|a|b|strong|li|ul|h[1-6])\b[^>]*>"#)
    private static let dropBlocks = Rx(#"<\s*(style|script|head|title)\b[^>]*>[\s\S]*?<\s*/\s*\1\s*>"#)
    private static let comments = Rx(#"<!--[\s\S]*?-->"#)
    private static let blockBreaks = Rx(#"<\s*(br|/p|/div|/tr|/li|/h[1-6]|/table|p|div|tr|li|table)\b[^>]*>"#)
    private static let cellBreaks = Rx(#"<\s*/\s*(td|th)\s*>"#)
    private static let blockquoteOpen = Rx(#"<\s*blockquote\b[^>]*>"#)
    private static let blockquoteClose = Rx(#"<\s*/\s*blockquote\s*>"#)
    private static let anyTag = Rx(#"<[^>]{0,2000}>"#)
    private static let entity = Rx(#"&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});"#)
    private static let spaces = Rx(#"[ \t  -   　]+"#)
    private static let manyNewlines = Rx(#"\n{3,}"#)

    static let namedEntities: [String: String] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "yen": "¥", "euro": "€",
        "pound": "£", "cent": "¢", "middot": "·", "times": "×", "ensp": " ", "emsp": " ", "thinsp": " ",
        "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’", "hellip": "…", "mdash": "—", "ndash": "–",
    ]

    static func looksLikeHTML(_ text: String) -> Bool { htmlHint.test(text) }

    static func normalize(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if looksLikeHTML(text) { text = htmlToText(text) } else { text = decodeEntities(text) }
        text = normalizeWidth(text)
        text = simplifyChinese(text)
        text = text.unicodeScalars.filter { !["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{2060}"].contains($0) }.map(String.init).joined()
        text = spaces.replace(text, with: " ")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        text = lines.joined(separator: "\n")
        text = manyNewlines.replace(text, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func htmlToText(_ html: String) -> String {
        var text = dropBlocks.replace(html, with: " ")
        text = comments.replace(text, with: " ")
        // 引用块标成「>」行，后续按引用历史剔除
        text = blockquoteOpen.replace(text, with: "\n[[BKQUOTE]]\n")
        text = blockquoteClose.replace(text, with: "\n[[/BKQUOTE]]\n")
        text = blockBreaks.replace(text, with: "\n")
        text = cellBreaks.replace(text, with: " ")
        text = anyTag.replace(text, with: "")
        text = decodeEntities(text)
        // 把 blockquote 内的行加上 > 前缀
        var output: [String] = []
        var depth = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[[BKQUOTE]]" { depth += 1; continue }
            if trimmed == "[[/BKQUOTE]]" { depth = max(0, depth - 1); continue }
            output.append(depth > 0 ? "> " + trimmed : String(line))
        }
        return output.joined(separator: "\n")
    }

    static func decodeEntities(_ text: String) -> String {
        let ns = NSString(string: text)
        let matches = entity.matches(ns)
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let body = ns.substring(with: match.range(at: 1))
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                if let value = UInt32(body.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) { replacement = String(Character(scalar)) }
            } else if body.hasPrefix("#") {
                if let value = UInt32(body.dropFirst()), let scalar = Unicode.Scalar(value) { replacement = String(Character(scalar)) }
            } else {
                replacement = namedEntities[body.lowercased()]
            }
            result += replacement ?? ns.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// 银行通知里常见的繁体字转简体，让「結尾號碼」「銀行」「賬戶」等按同一套规则识别（香港、澳门、台湾的银行）。
    /// 只影响解析；原文按原样保存。
    private static let simplified: [Character: Character] = Dictionary(
        uniqueKeysWithValues: zip("號銀賬帳戶碼結額餘費轉錢幣匯過為於從時間點進現開關證驗網購買賣價儲貸記單錄動變發撥還際國內處請詢電話無鐘週筆項業務臺門據這個們與對應該後實達約歷億萬圓經營簽認確權廣東華環優樣檢測試傳輸辦訊簡體續紀歸屬類別種稱響頁顯準備銷凍預繳稅資獎勵紅計劃擔險卻雖連線綫鈔兌換懷終領絡圍齊齡異隨復補償貨貝寶遞滙摺鎖張訂閱參選擇寫讀書冊註頭數詳細狀態啟協議敗錯誤謝歡聯繫熱兩機構員專標誌讓給島灣盧鄉縣區鎮樓層櫃檯圖館飯錶鏈車鐵運駕駛輛軌場戲劇樂師醫藥療學習課題練會衛濟貿競賽獲節慶禮擁護惡嚴厲盜竊詐騙謹嗎麼麽裡裏沒說爲", "号银账账户码结额余费转钱币汇过为于从时间点进现开关证验网购买卖价储贷记单录动变发拨还际国内处请询电话无钟周笔项业务台门据这个们与对应该后实达约历亿万圆经营签认确权广东华环优样检测试传输办讯简体续纪归属类别种称响页显准备销冻预缴税资奖励红计划担险却虽连线线钞兑换怀终领络围齐龄异随复补偿货贝宝递汇折锁张订阅参选择写读书册注头数详细状态启协议败错误谢欢联系热两机构员专标志让给岛湾卢乡县区镇楼层柜台图馆饭表链车铁运驾驶辆轨场戏剧乐师医药疗学习课题练会卫济贸竞赛获节庆礼拥护恶严厉盗窃诈骗谨吗么么里里没说为")
    )

    static func simplifyChinese(_ text: String) -> String {
        guard text.contains(where: { simplified[$0] != nil }) else { return text }
        return String(text.map { simplified[$0] ?? $0 })
    }

    /// 全角数字、字母和常用符号转半角；中文标点（，。；）保留，用于断句。
    static func normalizeWidth(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
                scalars.append(Unicode.Scalar(v - 0xFEE0)!)
            case 0xFF0E: scalars.append(".")
            case 0xFF0A: scalars.append("*")
            case 0xFFE5: scalars.append("¥")
            case 0xFF04: scalars.append("$")
            case 0xFFE1: scalars.append("£")
            case 0xFF0B: scalars.append("+")
            case 0xFF0D, 0x2212: scalars.append("-")
            case 0xFF0F: scalars.append("/")
            case 0xFF1A: scalars.append(":")
            case 0xFF08: scalars.append("(")
            case 0xFF09: scalars.append(")")
            case 0xFF3B: scalars.append("[")
            case 0xFF3D: scalars.append("]")
            case 0xFF20: scalars.append("@")
            case 0xFF07: scalars.append("'")
            case 0x3000: scalars.append(" ")
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}

/// 邮件引用历史与转发处理：避免把历史邮件里的交易再解析一遍。
enum EmailCleaner {
    private static let separator = Rx(#"^\s*-{2,}\s*(original message|原始邮件|forwarded message|转发邮件|转发的邮件|邮件原文)\s*-{2,}\s*$"#)
    private static let forwardHint = Rx(#"forwarded|转发"#)
    private static let wroteLine = Rx(#"^\s*(on\s.{4,200}wrote:|在\s?.{4,200}写道[：:]|.{2,120}于\s?.{4,120}写道[：:])\s*$"#)
    private static let headerFrom = Rx(#"^\s*(发件人|from)\s*:\s*.+$"#)
    private static let headerSent = Rx(#"^\s*(发送时间|sent|date|日期|时间)\s*:\s*.+$"#)
    private static let money = Rx(#"(\d[\d,.]*\s*(元|圆|eur|usd|cny|rmb|hkd|gbp|jpy|chf|€|£|欧元|美元|港币|港元|英镑|日元))|((人民币|rmb|cny|eur|usd|hkd|gbp|jpy|chf|[€£¥$])\s*\d)"#)

    static func stripQuotedHistory(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var markerIndex: Int?
        var isForward = false
        for (index, line) in lines.enumerated() {
            if separator.test(line) {
                markerIndex = index
                isForward = forwardHint.test(line)
                break
            }
            if wroteLine.test(line) {
                markerIndex = index
                break
            }
            if headerFrom.test(line) {
                let window = lines[(index + 1)..<min(lines.count, index + 5)]
                if window.contains(where: { headerSent.test($0) }) {
                    markerIndex = index
                    break
                }
            }
        }
        let unquoted: ([String]) -> [String] = { $0.filter { !$0.hasPrefix(">") } }
        guard let markerIndex else { return unquoted(lines).joined(separator: "\n") }
        let before = unquoted(Array(lines[..<markerIndex])).joined(separator: "\n")
        let after = Array(lines[(markerIndex + 1)...])
        if money.test(before) { return before }
        if isForward || before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 转发的银行邮件：真正的内容在分隔线之后；去掉被转发邮件的头部字段
            let body = after.drop { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty || headerFrom.test(trimmed) || headerSent.test(trimmed)
                    || Rx(#"^\s*(收件人|to|主题|subject|抄送|cc)\s*:"#).test(trimmed)
            }
            return stripQuotedHistory(body.joined(separator: "\n"))
        }
        return before
    }
}
