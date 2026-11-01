import Foundation
import BKModel

public struct MessageContext: Sendable {
    public var text: String
    public var source: SourceKind
    public var sender: String?
    public var subject: String?
    /// 用于推断「10月24日」这类没写年份的日期：系统接收时间，没有则用处理时间
    public var referenceDate: Date
    public var calendar: Calendar

    public init(text: String, source: SourceKind, sender: String?, subject: String?, referenceDate: Date, calendar: Calendar) {
        self.text = text
        self.source = source
        self.sender = sender
        self.subject = subject
        self.referenceDate = referenceDate
        self.calendar = calendar
    }
}

public struct ParsedEvent: Sendable, Hashable {
    public var draft: EventDraft
    /// 解析阶段就能确定的问题；nil 表示草稿完整（账户匹配在入账服务里做）
    public var issue: PendingReason?
}

public struct ParsedBalance: Sendable, Hashable {
    public var amount: AmountText
    public var negative: Bool
    public var cardTail: String?
    public var transactionTime: WallClock?
}

public struct ParsedMessage: Sendable {
    public var classification: MessageClassification
    public var events: [ParsedEvent]
    public var balances: [ParsedBalance]
    public var bankHint: String?
    /// 认不出银行、但认得出是电子钱包（支付宝、微信支付）发的
    public var walletHint: String?
    public var cleanedText: String
    /// 按固定写法认出的全部尾号（含对方账户的尾号）
    public var cardTails: [String]
    /// 正文里第一个时间；用户模板认出交易时用它作交易时间
    public var firstTime: WallClock?
    /// 正文里只有一个交易参考号时是它
    public var onlyReference: String?
    /// 认出了金额（不管是不是交易金额）
    public var hasAmount: Bool
    /// 【署名】看起来是银行（包括 `BankDirectory` 里没有的银行，这时 `bankHint` 是 nil）
    public var bankSignature: Bool
    /// 有【署名】，但不是银行或电子钱包的署名
    public var nonBankSignature: Bool
}

/// 规则解析器：纯函数，不访问数据库，不依赖网络。
public enum MessageParser {
    public static let version = 6

    // MARK: 识别用正则

    private static let tailPatterns: [Rx] = [
        Rx(#"(?:结尾号码|尾号码|号码结尾|尾号|尾数|末四位|后四位|卡号后四位|账号尾号|卡尾号)\s*(?:为|是)?\s*[：:]?\s*[*xX•·]*\s*(\d{3,4})(?![\d年月日元.,])"#),
        Rx(#"(?:账户|账号|卡号?|card|acct|account|a/c|\bac\b|\bcc\b|konto|karte)\s*(?:ending(?:\s+in|\s+with)?|endend auf|no\.?)?\s*[:：]?\s*\d*[*xX•·.#]{1,}\s*\d*?(\d{3,4})(?![\d年月日元xX*•#]|[.,]\d)"#),
        Rx(#"(?:ending(?:\s+in|\s+with)?|ends in|endend auf)\s*[：:]?\s*[*xX•·]*\s*(\d{3,4})(?![\d.,])"#),
        Rx(#"(?<![\w])[*xX•]{2,}\s?\d*(\d{4})(?![\d.,])"#),
        Rx(#"(?:借记卡|储蓄卡|信用卡|贷记卡|扣账卡|账户|账号)\s*(\d{4})(?![\d年月日元.,:：])"#),
        Rx(#"\bcard\s*\((\d{4})\)"#),
        Rx(#"\b(?:cc|card)\s+(\d{4})(?![\d年月日元.,])"#),
    ]
    private static let referencePattern = Rx(#"(?:交易流水号|流水号|交易参考号|参考号|凭证号|交易编号|交易序号|reference(?:\s+no\.?|\s+number)?|\bref(?:\.|\s+no\.?)?|txn id|transaction id)\s*[：:#]?\s*([A-Za-z0-9][A-Za-z0-9\-]{5,31})"#)
    private static let longDigits = Rx(#"\d{9,}"#)
    /// 电话号码（「+86-138******00」「+852 3665 3665」）和打码的号码（「138******00」「100*0001」）：里面的数字不是金额
    private static let phoneNumber = Rx(#"(?<![\w+])\+\d{1,4}[\s-]+[\d*xX•][\d*xX•\s-]{4,}[\d*xX•]"#)
    private static let maskedNumber = Rx(#"\d*[*•]{2,}\d+|\d+[*•]{2,}\d*|\d+[*•]\d+|\d+[xX]{2,}\d+"#)
    /// 手机号形状的打码号码（共 11 位，1 开头）：后四位不是卡号尾号。打码的卡号（`6222****1234`）长度不同，不受影响
    static let maskedPhone = Rx(#"(?<![\d*xX•])1[3-9](?:\d\s?[*xX•]{4}|\d{2}\s?[*xX•]{3}|[*xX•]{5})\s?\d{4}(?![\d*xX•])"#)
    /// 引号里的文字：转账对象的账号、邮箱
    static let quoted = Rx(#"["“][^"”\n]{1,60}["”]"#)
    private static let counterpartyTailMarker = Rx(#"(?:向|至|到|给|对方|收款|付款|\bto|\bfrom)\s*$"#)
    private static let feeClause = Rx(#"(?:含\s*)?(?:手续费|服务费|费用)[^，,。；;)）]*"#)
    private static let cjk = Rx(#"[\x{4E00}-\x{9FFF}]"#)
    /// 数字后面紧跟着一个词（「54321 testcity」）：是名称里的数字

    private static let dateTimeFull = Rx(#"(20\d{2})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})\s*日?(?:\s*(?:T|\s)?\s*(\d{1,2})\s*[：:时点]\s*(\d{2})\s*(?:[：:分]\s*(\d{2}))?\s*(?:秒|分)?)?"#)
    private static let dateNumericYear = Rx(#"(?<![\d.\-/])(\d{1,2})([-/.])(\d{1,2})[-/.](20\d{2}|\d{2})(?:,?\s+(?:at\s+)?(\d{1,2}):(\d{2})(?::(\d{2}))?)?(?![\d])"#)
    private static let dateEnglishDMY = Rx(#"(?<![\d])(\d{1,2})(?:st|nd|rd|th)?[\s-]+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?[,-]?\s*(20\d{2}|\d{2}(?![\d:]))?(?:,?\s+(?:at\s+)?(\d{1,2}):(\d{2}))?"#)
    private static let dateEnglishMDY = Rx(#"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s*(20\d{2})?(?:,?\s+(?:at\s+)?(\d{1,2}):(\d{2}))?"#)
    /// 「于0618发生」「于20260928的汇款」
    private static let dateCompact = Rx(#"(?<=于)(20\d{2})?(0[1-9]|1[0-2])([0-3]\d)(?!\d)"#)
    private static let dateChinese = Rx(#"(\d{1,2})\s*月\s*(\d{1,2})\s*日(?:\s*(\d{1,2})\s*[：:时点]\s*(\d{2})\s*(?:[：:分]\s*(\d{2}))?\s*(?:秒|分)?)?"#)
    private static let dateShort = Rx(#"(?<![\d.,/])(\d{1,2})([-/])(\d{1,2})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?(?![\d])"#)
    private static let timeOnly = Rx(#"(?<![\d:.])(\d{1,2})\s*[：:]\s*(\d{2})(?:\s*[：:]\s*(\d{2}))?(?![\d:])|(\d{1,2})时(\d{2})分"#)

    private static let amountPattern = Rx(#"(?<![\d,'#])(?<!\d\.)(?:([-+])[ \t]?)?(\d{1,2}(?:,\d{2})+,\d{3}(?:\.\d{1,3})?|\d{1,3}(?:,\d{3})+(?:\.\d{1,3})?|\d{1,3}(?:\.\d{3})+(?:,\d{1,3})?|\d{1,3}(?:'\d{3})+(?:\.\d{1,3})?|\d+(?:[.,]\d{1,3})?)(?![\d'#]|[.,]\d)"#)

    private static let counterpartyPatterns: [Rx] = [
        Rx(#"(?:商户名称|交易商户|商户|对方户名|对方账户名|对方名称|对方|收款方|收款人|付款方|付款人|交易对象|merchant|payee|händler)\s*[：:]\s*([^，,。；;\n()（）]{1,40})"#),
        // 商户描述可以很长（名称 + 地址 + 城市 + 邮编），地址里可能有不带空格的逗号。「绑定在Apple Pay上的账户…」的「在」后面不是商户，不跨过账户、卡号
        Rx(#"在\s*(?!\d)((?:(?!账户|账号|卡号|尾号)(?:[^，,。；;\n]|,(?=\S))){2,80}?)\s*(?:完成(?:一笔)?(?:扣款|消费|支付|交易|付款)|预授权|冻结|消费|支付|刷卡|网上支付|快捷支付|扣款|购物)"#),
        Rx(#"([^\s，,。；;\n:：]{2,30}?)\s*向您(?:尾号\s*[*xX•]*\d{3,4})?的?(?:账户|账号|[^，,。；;\n]{0,8}?卡)?(?:完成)?(?:转账|转存|汇款|存入)"#),
        // 卡组织的商户描述（名称 + 城市 + 国家）可以到 40 多个字符，例如「WEIXIN*Demo QR shop fo Testcity CN」
        Rx(#"向\s*([^您，,。；;\n][^，,。；;\n]{1,44}?)\s*(?:转账|转出|付款|汇款|支付)"#),
        Rx(#"(?:转出|转账|汇款|付款)(?:至|到|给)\s*([^，,。；;\n]{2,30}?)\s*(?=[，,。；;\n]|$)"#),
        Rx(#"(?:来自|付款方)\s*([^，,。；;\n]{2,30}?)(?:的|转账|汇款|[，,。；;\n]|$)"#),
        Rx(#"\bto\s+["“]([^"”\n]{2,40})["”]"#),
        Rx(#"\bat\s+([A-Z0-9][A-Za-z0-9 &'.\-*/]{1,40}?)(?=\s+on\b|\s+\d|[.,;]|\s*$)"#, caseInsensitive: false),
        Rx(#"\b(?:to|from)\s+([A-Z][A-Za-z0-9 &'.\-]{1,40}?)(?=\s+(?:on|using|with|via)\b|\s+\d|[.,;]|\s*$)"#, caseInsensitive: false),
        Rx(#"\bbei\s+([A-Z0-9][A-Za-z0-9 &'.\-]{1,40}?)(?=\s+am\b|[.,;]|\s*$)"#, caseInsensitive: false),
    ]
    private static let genericSummary: Set<String> = [
        "消费", "转账", "跨行转账", "行内转账", "工资", "代发工资", "代发", "利息", "结息", "存款", "取款", "支取", "存入", "转入", "转出",
        "汇款", "退款", "还款", "手续费", "年费", "快捷支付", "网上支付", "支付", "扣款", "收入", "支出", "其他", "无",
    ]
    private static let counterpartyNoise = Rx(#"尾号|账户|卡号|您的|贵|本行|余额|人民币|\d{2}[：:]\d{2}|\d+月\d+日|^\d+$|^[\s\p{P}]+$|^(?:收款人|收款方|付款人|付款方|对方)$"#)

    private static let sentenceBreak = Rx(#"[。；;!！?？\n]|\.\s+(?=[A-Z【\[])"#, caseInsensitive: false)
    private static let clauseBreak = Rx(#"[，、()（）]|,(?!\d)|\s-\s"#, caseInsensitive: false)

    // MARK: 中间结构

    private struct Mention<Value> {
        var range: NSRange
        var value: Value
    }

    private struct AmountMention {
        var range: NSRange
        var digits: String
        var negative: Bool
        var amount: AmountText
        var hasCurrency: Bool
        var role: Lexicon.Role?
        var includedFee: Bool
        var sentence: Int
    }

    // MARK: 入口

    /// 解析和用户模板使用的正文：格式统一，邮件去掉引用的历史邮件。
    public static func cleaned(_ text: String, source: SourceKind) -> String {
        var cleaned = TextNormalizer.normalize(text)
        // 来源分不出时也按邮件处理引用历史：短信和 App 通知里不会出现「原始邮件」分隔线或「>」引用行
        if source == .email || source == .auto { cleaned = EmailCleaner.stripQuotedHistory(cleaned) }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func parse(_ context: MessageContext) -> ParsedMessage {
        let cleaned = MessageParser.cleaned(context.text, source: context.source)
        let subject = context.subject.map(TextNormalizer.normalize) ?? ""
        var bankHint = BankDirectory.identify(sender: context.sender, text: cleaned + "\n" + subject)
        let walletHint = bankHint == nil ? WalletDirectory.identify(sender: context.sender, text: cleaned) : nil

        let signatures = signatures(in: cleaned)
        let bankSignatures = signatures.filter { Lexicon.bankSignature.test($0) }
        let bankSignature = !bankSignatures.isEmpty
        // 名录里只有常见银行：众安、恒生这样的按【署名】在目录里找。目录里也有钱包，钱包发的不走这里
        if bankHint == nil, walletHint == nil {
            bankHint = bankSignatures.lazy.compactMap { BankCatalog.entry(signature: $0)?.id }.first
        }
        let nonBankSignature = bankHint == nil && walletHint == nil && !signatures.isEmpty && !bankSignature

        var foundTails: [String] = []
        var firstTime: WallClock?
        var references: [Mention<String>] = []
        var hasAmount = false
        func result(_ classification: MessageClassification, _ events: [ParsedEvent] = [], _ balances: [ParsedBalance] = []) -> ParsedMessage {
            ParsedMessage(
                classification: classification, events: events, balances: balances, bankHint: bankHint, walletHint: walletHint, cleanedText: cleaned, cardTails: foundTails,
                firstTime: firstTime, onlyReference: references.count == 1 ? references[0].value : nil, hasAmount: hasAmount,
                bankSignature: bankSignature, nonBankSignature: nonBankSignature
            )
        }

        guard !cleaned.isEmpty else { return result(.empty) }
        if Lexicon.verificationCodeValue.test(cleaned) || Lexicon.verificationCodeValue.test(subject) { return result(.verificationCode) }
        if Lexicon.statement.test(subject) || Lexicon.statement.test(cleaned) { return result(.statement) }

        let ns = NSString(string: cleaned)
        let length = ns.length
        var masked = [Bool](repeating: false, count: length)
        func isFree(_ r: NSRange) -> Bool { (r.location..<(r.location + r.length)).allSatisfy { !masked[$0] } }
        func mask(_ r: NSRange) { for i in r.location..<(r.location + r.length) { masked[i] = true } }

        // 1. 卡号尾号
        for match in maskedPhone.matches(ns) { mask(match.range) }
        var tails: [Mention<String>] = []
        for pattern in tailPatterns {
            for match in pattern.matches(ns) where isFree(match.range) {
                guard let value = match.group(1, in: ns) else { continue }
                tails.append(Mention(range: match.range, value: value))
                mask(match.range)
            }
        }
        tails.sort { $0.range.location < $1.range.location }
        foundTails = tails.map(\.value)

        // 2. 日期时间
        let chinese = cjk.test(cleaned)
        var times: [Mention<WallClock>] = []
        func addTime(_ range: NSRange, _ clock: WallClock?) {
            guard let clock, isFree(range) else { return }
            times.append(Mention(range: range, value: clock))
            mask(range)
        }
        let calendar = context.calendar
        let reference = context.referenceDate
        for m in dateTimeFull.matches(ns) {
            addTime(m.range, makeClock(year: m.group(1, in: ns), month: m.group(2, in: ns), day: m.group(3, in: ns), hour: m.group(4, in: ns), minute: m.group(5, in: ns), second: m.group(6, in: ns), reference: reference, calendar: calendar))
        }
        for m in dateNumericYear.matches(ns) {
            guard let a = m.group(1, in: ns).flatMap(Int.init), let b = m.group(3, in: ns).flatMap(Int.init) else { continue }
            let separator = m.group(2, in: ns) ?? "/"
            var month: Int?, day: Int?
            if separator != "/" || a > 12 { day = a; month = b } else if b > 12 { month = a; day = b }
            var yearText = m.group(4, in: ns)
            if let y = yearText, y.count == 2 { yearText = "20" + y }
            if month == nil {
                // 无法区分日/月：不写入日期，只保留时间（如果有）
                addTime(m.range, makeClock(year: nil, month: nil, day: nil, hour: m.group(5, in: ns), minute: m.group(6, in: ns), second: m.group(7, in: ns), reference: reference, calendar: calendar))
                continue
            }
            addTime(m.range, makeClock(year: yearText, month: month.map(String.init), day: day.map(String.init), hour: m.group(5, in: ns), minute: m.group(6, in: ns), second: m.group(7, in: ns), reference: reference, calendar: calendar))
        }
        for m in dateEnglishDMY.matches(ns) {
            let year = m.group(3, in: ns).map { $0.count == 2 ? "20" + $0 : $0 }
            addTime(m.range, makeClock(year: year, month: monthNumber(m.group(2, in: ns)).map(String.init), day: m.group(1, in: ns), hour: m.group(4, in: ns), minute: m.group(5, in: ns), second: nil, reference: reference, calendar: calendar))
        }
        for m in dateEnglishMDY.matches(ns) {
            addTime(m.range, makeClock(year: m.group(3, in: ns), month: monthNumber(m.group(1, in: ns)).map(String.init), day: m.group(2, in: ns), hour: m.group(4, in: ns), minute: m.group(5, in: ns), second: nil, reference: reference, calendar: calendar))
        }
        for m in dateCompact.matches(ns) {
            addTime(m.range, makeClock(year: m.group(1, in: ns), month: m.group(2, in: ns), day: m.group(3, in: ns), hour: nil, minute: nil, second: nil, reference: reference, calendar: calendar))
        }
        for m in dateChinese.matches(ns) {
            addTime(m.range, makeClock(year: nil, month: m.group(1, in: ns), day: m.group(2, in: ns), hour: m.group(3, in: ns), minute: m.group(4, in: ns), second: m.group(5, in: ns), reference: reference, calendar: calendar))
        }
        for m in dateShort.matches(ns) {
            guard let a = m.group(1, in: ns).flatMap(Int.init), let b = m.group(3, in: ns).flatMap(Int.init) else { continue }
            var month: Int?, day: Int?
            if chinese { month = a; day = b } else if a > 12 { day = a; month = b } else if b > 12 { month = a; day = b }
            addTime(m.range, makeClock(year: nil, month: month.map(String.init), day: day.map(String.init), hour: m.group(4, in: ns), minute: m.group(5, in: ns), second: m.group(6, in: ns), reference: reference, calendar: calendar))
        }
        for m in timeOnly.matches(ns) {
            let hour = m.group(1, in: ns) ?? m.group(4, in: ns)
            let minute = m.group(2, in: ns) ?? m.group(5, in: ns)
            addTime(m.range, makeClock(year: nil, month: nil, day: nil, hour: hour, minute: minute, second: m.group(3, in: ns), reference: reference, calendar: calendar))
        }
        times.sort { $0.range.location < $1.range.location }
        times = mergeAdjacentDateAndTime(times, in: ns)
        firstTime = times.first?.value

        // 3. 交易参考号、长数字串、电话号码和打码的号码
        for m in referencePattern.matches(ns) where isFree(m.range) {
            if let value = m.group(1, in: ns) { references.append(Mention(range: m.range, value: value)) }
            mask(m.range)
        }
        for m in longDigits.matches(ns) where isFree(m.range) { mask(m.range) }
        for m in phoneNumber.matches(ns) { mask(m.range) }
        for m in maskedNumber.matches(ns) { mask(m.range) }

        // 4. 句子与分句
        let sentences = splitRanges(ns, by: sentenceBreak)
        func sentenceIndex(_ location: Int) -> Int {
            sentences.firstIndex { location >= $0.location && location < $0.location + $0.length } ?? max(0, sentences.count - 1)
        }
        let clauseBoundaries = clauseBreak.matches(ns).map(\.range.location) + sentenceBreak.matches(ns).map(\.range.location)

        // 5. 金额
        var units = Array(cleaned.utf16)
        for i in 0..<units.count where masked[i] { units[i] = 0x23 }
        let maskedText = NSString(string: String(decoding: units, as: UTF16.self))
        var amounts: [AmountMention] = []
        for m in amountPattern.matches(maskedText) {
            guard let digits = m.group(2, in: maskedText) else { continue }
            let numberRange = m.range(at: 2)
            let afterLocation = numberRange.location + numberRange.length
            let after = maskedText.substring(from: afterLocation)
            let beforeStart = max(0, m.range.location - 10)
            let before = maskedText.substring(with: NSRange(location: beforeStart, length: m.range.location - beforeStart))
            let prefixCurrency = CurrencyTokens.prefix(in: before)
            let suffixCurrency = CurrencyTokens.suffix(in: after)
            let hasCurrency = prefixCurrency != nil || suffixCurrency != nil
            if !hasCurrency, Lexicon.nonAmountSuffix.test(after) { continue }
            // 粘在字母上的数字是编号（交易号 DB59HV、车牌 3AA33），写了币种的除外（USD10、CNY1）
            if !hasCurrency, before.last?.isGluedToNumber == true || after.first?.isGluedToNumber == true { continue }

            let candidates = CurrencyTokens.combine(prefixCurrency, suffixCurrency, chineseText: chinese)
            var signNegative = m.group(1, in: maskedText) == "-"
            if !signNegative, before.hasSuffix("-") || before.hasSuffix("−") { signNegative = true }

            // 金额前最近的标签（限定在本分句内）
            let clauseStart = clauseBoundaries.filter { $0 < numberRange.location }.max().map { $0 + 1 } ?? 0
            let windowStart = max(clauseStart, numberRange.location - 24)
            let window = ns.substring(with: NSRange(location: windowStart, length: max(0, numberRange.location - windowStart)))
            // 「Transaction cost, Ksh0.00」：标签和金额被逗号隔开，这一分句里什么都没有时往前看
            let wider = window.trimmingCharacters(in: .whitespaces).count <= 4
                ? ns.substring(with: NSRange(location: max(0, numberRange.location - 24), length: min(24, numberRange.location))) : window
            var (role, included) = roleFor(window: wider)
            if Lexicon.balanceAfterAmount.test(after) { (role, included) = (.balance, false) }
            let hasDecimals = digits.range(of: #"[.,]\d{2}$"#, options: .regularExpression) != nil
            if !hasCurrency, role == nil, !hasDecimals { continue }
            if role == .points { continue }
            if !hasCurrency, role == nil {
                // 只有两位小数、没有币种也没有标签：分句里必须有交易动作词才算金额
                let clause = ns.substring(with: NSRange(location: clauseStart, length: min(length, afterLocation + 8) - clauseStart))
                if Lexicon.roleLabels.last!.1.test(clause) == false { continue }
            }
            amounts.append(AmountMention(
                range: m.range, digits: digits, negative: signNegative,
                amount: AmountText(digits: digits, currencyCandidates: candidates.candidates, preferredCurrency: candidates.preferred),
                hasCurrency: hasCurrency, role: role ?? .transaction, includedFee: included, sentence: sentenceIndex(numberRange.location)
            ))
        }

        // 已经有写明币种的交易金额时，没写币种的数字是名称、编号或说明（「Amount you can transact is 498,440.00」）
        // （恒生「向54321 testcity CN支付了CNY58」的商户、「Person 4」「TRANSFER365」），不算金额
        if amounts.contains(where: { $0.hasCurrency && $0.role == .transaction }) {
            amounts.removeAll { !$0.hasCurrency && $0.role == .transaction }
        }

        // 同一条通知里其他金额写明的币种，可作为没写币种的金额的线索
        let messageCurrencies = Set(amounts.flatMap(\.amount.currencyCandidates))
        if messageCurrencies.count == 1, let only = messageCurrencies.first {
            for i in amounts.indices where amounts[i].amount.currencyCandidates.isEmpty {
                amounts[i].amount.currencyCandidates = [only]
            }
        }

        // 「预授权冻结JPY1000.00（人民币48.00）」：括号里的是同一笔的实际扣款，不是第二笔交易
        var settlements: [Int: AmountText] = [:]
        var distinctAmounts: [AmountMention] = []
        for amount in amounts {
            if let main = distinctAmounts.last, isSettlement(amount, of: main, in: ns) {
                settlements[main.range.location] = amount.amount
            } else if let main = distinctAmounts.last, isHoldRestatement(amount, of: main, in: ns) {
                continue
            } else {
                distinctAmounts.append(amount)
            }
        }
        amounts = distinctAmounts
        hasAmount = !amounts.isEmpty

        let summaryValue = Lexicon.summaryField.first(ns).flatMap { $0.group(1, in: ns)?.trimmingCharacters(in: .whitespaces) }

        // 6. 组装交易
        var events: [ParsedEvent] = []
        var usedBalances = Set<Int>()
        let transactionAmounts = amounts.enumerated().filter { $0.element.role == .transaction }
        let feeAmounts = amounts.enumerated().filter { $0.element.role == .fee }
        let singleTransaction = transactionAmounts.count == 1
        var nextPart = 0

        func sentenceText(_ index: Int) -> String {
            guard sentences.indices.contains(index) else { return cleaned }
            return ns.substring(with: sentences[index])
        }

        // 「向尾号6621账户转账」里的尾号是对方账户，不是本条通知所属的账户
        func isCounterpartyTail(_ mention: Mention<String>) -> Bool {
            let start = max(0, mention.range.location - 4)
            let before = ns.substring(with: NSRange(location: start, length: mention.range.location - start))
            return counterpartyTailMarker.test(before)
        }

        func nearestTail(before location: Int, sentence: Int) -> (String?, String?) {
            let range = sentences.indices.contains(sentence) ? sentences[sentence] : NSRange(location: 0, length: length)
            let inSentence = tails.filter { $0.range.location >= range.location && $0.range.location < range.location + range.length }
            let own = inSentence.filter { !isCounterpartyTail($0) }
            let ownAll = tails.filter { !isCounterpartyTail($0) }
            let primary = own.last(where: { $0.range.location < location }) ?? own.first
                ?? ownAll.last(where: { $0.range.location < location }) ?? ownAll.first ?? inSentence.first
            let other = inSentence.first { $0.value != primary?.value }?.value
            return (primary?.value, other)
        }

        // 交易对方提取用「去掉时间」的句子，避免把「张三于10月24日」整段当成对方名称
        var timelessUnits = Array(cleaned.utf16)
        for mention in times {
            for i in mention.range.location..<(mention.range.location + mention.range.length) { timelessUnits[i] = 0x20 }
        }
        let timeless = NSString(string: String(decoding: timelessUnits, as: UTF16.self))

        func nearestTime(before location: Int, sentence: Int) -> WallClock? {
            let range = sentences.indices.contains(sentence) ? sentences[sentence] : NSRange(location: 0, length: length)
            let inSentence = times.filter { $0.range.location >= range.location && $0.range.location < range.location + range.length }
            return (inSentence.last(where: { $0.range.location < location }) ?? inSentence.first ?? times.first)?.value
        }

        // 「（交易预授权时间10月30日10:20）」里写的时间
        func holdTime(in range: NSRange) -> WallClock? {
            times.first { mention in
                guard mention.range.location >= range.location, mention.range.location < range.location + range.length else { return false }
                let start = max(range.location, mention.range.location - 8)
                return Lexicon.holdTimeLabel.test(ns.substring(with: NSRange(location: start, length: mention.range.location - start)))
            }?.value
        }

        let sentencesWithMultipleTransactions = Set(Dictionary(grouping: transactionAmounts, by: { $0.element.sentence }).filter { $0.value.count > 1 }.keys)

        for (index, amount) in transactionAmounts {
            let sentence = sentenceText(amount.sentence)
            let sentenceRange = sentences.indices.contains(amount.sentence) ? sentences[amount.sentence] : NSRange(location: 0, length: length)
            // 逾期/将要发生的扣款属于提醒，不入账
            if Lexicon.reminder.test(sentence), !Lexicon.completed.test(sentence) { continue }

            let amountEnd = amount.range.location + amount.range.length
            let prefix = ns.substring(with: NSRange(location: sentenceRange.location, length: max(0, amount.range.location - sentenceRange.location)))
            let suffix = ns.substring(with: NSRange(location: amountEnd, length: max(0, sentenceRange.location + sentenceRange.length - amountEnd)))
            var detection = detectKind(prefix: prefix, suffix: suffix, summary: summaryValue, message: singleTransaction ? cleaned + "\n" + subject : nil)
            if detection.status == .posted, Lexicon.failed.test(sentence) || (singleTransaction && Lexicon.failed.test(cleaned)) {
                detection.status = .failed
            }
            if detection.direction == nil, detection.kind == .other, amount.negative { detection.direction = .outflow }
            // 交易失败时钱没有动，说不清性质也不用问用户
            if detection.status == .failed, detection.direction == nil {
                detection.direction = .outflow
                detection.uncertain = false
            }

            let (tail, otherTail) = nearestTail(before: amount.range.location, sentence: amount.sentence)
            let time = nearestTime(before: amount.range.location, sentence: amount.sentence)
            let counterparty = extractCounterparty(sentence: timeless.substring(with: sentenceRange), summary: summaryValue)
            let reference = references.first { $0.range.location >= sentenceRange.location && $0.range.location < sentenceRange.location + sentenceRange.length }?.value
                ?? (singleTransaction && references.count == 1 ? references[0].value : nil)

            // 余额：同一句里交易金额之后的余额；只有一笔交易时也接受后面句子里的余额
            var balance: AmountText?
            var balanceIndex: Int?
            if let found = amounts.enumerated().first(where: { $0.offset > index && $0.element.role == .balance && ($0.element.sentence == amount.sentence || singleTransaction) && !usedBalances.contains($0.offset) }) {
                balance = found.element.negative ? nil : found.element.amount
                balanceIndex = found.offset
            }
            if let balanceIndex { usedBalances.insert(balanceIndex) }

            // 手续费：「含手续费」拆分；同句单列的手续费作为另一笔
            let sentenceFees = feeAmounts.filter { $0.element.sentence == amount.sentence }
            let included = sentenceFees.first { $0.element.includedFee }?.element.amount

            var issue: PendingReason?
            if sentencesWithMultipleTransactions.contains(amount.sentence) { issue = .ambiguousAmount }
            if issue == nil, detection.uncertain { issue = .uncertainKind }
            if issue == nil, case .failure(.ambiguous) = trialParse(amount.amount) { issue = .ambiguousAmount }

            let part = nextPart
            let draft = EventDraft(
                amount: amount.amount, direction: detection.direction, kind: detection.kind, status: detection.status,
                counterparty: counterparty, cardTail: tail, counterpartyTail: otherTail, transactionTime: time,
                bankReference: reference, balanceAfter: balance, includedFee: included, isSplitFee: false,
                partIndex: part, bankHint: bankHint, walletHint: walletHint, settlement: settlements[amount.range.location],
                holdTime: detection.status == .posted ? holdTime(in: sentenceRange) : nil, evidenceSnippet: String(sentence.prefix(160))
            )
            events.append(ParsedEvent(draft: draft, issue: issue))
            // 主交易用偶数编号，手续费用奇数（`IngestEngine.dedupeKey`）。一句里可以有几项费用，编号不能重复
            nextPart += 2 * max(1, sentenceFees.count)
            for (feeIndex, fee) in sentenceFees.enumerated() {
                var feeDraft = draft
                feeDraft.amount = fee.element.amount
                feeDraft.kind = .fee
                feeDraft.direction = .outflow
                feeDraft.isSplitFee = fee.element.includedFee
                feeDraft.includedFee = nil
                feeDraft.balanceAfter = nil
                feeDraft.bankReference = nil
                feeDraft.counterparty = nil
                feeDraft.settlement = nil
                feeDraft.holdTime = nil
                feeDraft.partIndex = part + 1 + 2 * feeIndex
                events.append(ParsedEvent(draft: feeDraft, issue: issue))
            }
        }

        // 没有交易金额、只有手续费（例如「扣收年费 100 元」）
        if transactionAmounts.isEmpty {
            for (_, fee) in feeAmounts where !fee.includedFee {
                let sentence = sentenceText(fee.sentence)
                if Lexicon.reminder.test(sentence), !Lexicon.completed.test(sentence) { continue }
                let (tail, _) = nearestTail(before: fee.range.location, sentence: fee.sentence)
                var status: SettlementStatus = .posted
                if Lexicon.failed.test(sentence) { status = .failed }
                let draft = EventDraft(
                    amount: fee.amount, direction: .outflow, kind: .fee, status: status, counterparty: nil, cardTail: tail,
                    counterpartyTail: nil, transactionTime: nearestTime(before: fee.range.location, sentence: fee.sentence),
                    bankReference: nil, balanceAfter: nil, includedFee: nil, isSplitFee: false, partIndex: nextPart,
                    bankHint: bankHint, walletHint: walletHint, evidenceSnippet: String(sentence.prefix(160))
                )
                nextPart += 2
                events.append(ParsedEvent(draft: draft, issue: nil))
            }
        }

        // 同一封邮件里重复出现的同一笔（例如正文和摘要各写一次）只保留一次
        var seen = Set<String>()
        events = events.filter { event in
            let d = event.draft
            let key = [d.amount.digits, d.cardTail ?? "", d.kind.rawValue, d.direction?.rawValue ?? "", d.transactionTime?.sortKey ?? "", d.isSplitFee ? "f" : "", d.balanceAfter?.digits ?? ""].joined(separator: "|")
            return seen.insert(key).inserted
        }
        // 中英双语的邮件把同一笔写两遍：一段认不出交易性质（other）时，以认出来的那段为准
        let known = events.filter { $0.draft.kind != .other && !$0.draft.isSplitFee }
        events = events.filter { event in
            let d = event.draft
            guard d.kind == .other, !d.isSplitFee else { return true }
            return !known.contains { other in
                let o = other.draft
                return o.amount.digits == d.amount.digits && o.cardTail == d.cardTail && o.transactionTime?.sortKey == d.transactionTime?.sortKey
                    && (d.direction == nil || o.direction == d.direction)
            }
        }

        let balances: [ParsedBalance] = amounts.enumerated()
            .filter { $0.element.role == .balance && !usedBalances.contains($0.offset) }
            .map { item in
                let (tail, _) = nearestTail(before: item.element.range.location, sentence: item.element.sentence)
                return ParsedBalance(amount: item.element.amount, negative: item.element.negative, cardTail: tail, transactionTime: nearestTime(before: item.element.range.location, sentence: item.element.sentence))
            }

        // 7. 整条通知的类别
        let strongEvents = events.filter { $0.issue == nil && $0.draft.cardTail != nil }
        if !events.isEmpty {
            if Lexicon.marketing.test(cleaned), strongEvents.isEmpty, tails.isEmpty { return result(.marketing) }
            return result(.transaction, events, balances)
        }
        if !transactionAmounts.isEmpty || !feeAmounts.isEmpty {
            // 有金额，但全部是提醒句
            if Lexicon.reminder.test(cleaned) { return result(.reminder) }
        }
        if Lexicon.limitChange.test(cleaned) { return result(.creditLimitChange) }
        if !balances.isEmpty, !Lexicon.marketing.test(cleaned) || !tails.isEmpty { return result(.balanceSnapshot, [], balances) }
        if Lexicon.marketing.test(cleaned) { return result(.marketing) }
        if Lexicon.reminder.test(cleaned) || amounts.contains(where: { $0.role == .due }) { return result(.reminder) }
        // 没有任何金额、也没有尾号：不是动账通知。自动化按「银行」等关键词触发时，普通聊天短信会走到这里，
        // 不放进待处理（否则会被无关短信淹没），只在接收日志里留一条。
        if amounts.isEmpty, tails.isEmpty { return result(.noFinancialContent) }
        return result(.unrecognized)
    }

    // MARK: 工具函数

    private static func signatures(in text: String) -> [String] {
        let ns = NSString(string: text)
        return Lexicon.signature.matches(ns).compactMap { $0.group(1, in: ns) ?? $0.group(2, in: ns) }
    }

    /// `amount` 是紧跟在 `main` 后面括号里的另一币种金额。币种相同时说不清哪个才对，不算（保持歧义）
    private static func isSettlement(_ amount: AmountMention, of main: AmountMention, in ns: NSString) -> Bool {
        guard main.role == .transaction, amount.role == .transaction, main.hasCurrency, amount.hasCurrency, main.sentence == amount.sentence,
              let mainCurrency = main.amount.preferredCurrency ?? main.amount.currencyCandidates.first,
              let currency = amount.amount.preferredCurrency ?? amount.amount.currencyCandidates.first, currency != mainCurrency else { return false }
        let gapStart = main.range.location + main.range.length
        let gap = ns.substring(with: NSRange(location: gapStart, length: amount.range.location - gapStart))
        let after = ns.substring(from: amount.range.location + amount.range.length)
        return Lexicon.bracketedAmountGap.test(gap) && Lexicon.bracketedAmountEnd.test(after)
    }

    /// 「金额10.00美元，已冻结10.00美元」：后一个数只是说这笔钱被冻结了，不是第二笔
    private static func isHoldRestatement(_ amount: AmountMention, of main: AmountMention, in ns: NSString) -> Bool {
        guard main.role == .transaction, amount.role == .transaction, main.sentence == amount.sentence, main.digits == amount.digits,
              main.amount.currencyCandidates == amount.amount.currencyCandidates else { return false }
        let gapStart = main.range.location + main.range.length
        return Lexicon.holdRestatement.test(ns.substring(with: NSRange(location: gapStart, length: amount.range.location - gapStart)))
    }

    private static func trialParse(_ amount: AmountText) -> Result<Int64, AmountParser.Failure> {
        let exponent = (amount.preferredCurrency ?? amount.currencyCandidates.first)?.minorUnitExponent ?? 2
        return AmountParser.minorUnits(amount.digits, exponent: exponent)
    }

    private static func roleFor(window: String) -> (Lexicon.Role?, Bool) {
        let ns = NSString(string: window)
        var best: (role: Lexicon.Role, end: Int)?
        for (role, rx) in Lexicon.roleLabels {
            guard let last = rx.matches(ns).last else { continue }
            let end = last.range.location + last.range.length
            if let current = best {
                // 距离相同（例如「应还款额」同时命中「还款」）时，非交易标签优先
                if end > current.end || (end == current.end && current.role == .transaction && role != .transaction) {
                    best = (role, end)
                }
            } else {
                best = (role, end)
            }
        }
        guard let best else { return (nil, false) }
        let included = best.role == .fee && Lexicon.includedFee.test(window)
        return (best.role, included)
    }

    struct KindDetection {
        var kind: TransactionKind
        var direction: FlowDirection?
        var status: SettlementStatus
        var uncertain: Bool
    }

    static func detectKind(prefix: String, suffix: String, summary: String?, message: String?) -> KindDetection {
        func lastRule(in text: String) -> (Lexicon.KindRule, Int)? {
            let ns = NSString(string: text)
            var best: (Lexicon.KindRule, Int)?
            for rule in Lexicon.kindRules {
                guard let m = rule.rx.matches(ns).last else { continue }
                let end = m.range.location + m.range.length
                if best == nil || end > best!.1 { best = (rule, end) }
            }
            return best
        }
        func firstRule(in text: String) -> Lexicon.KindRule? {
            let ns = NSString(string: text)
            var best: (Lexicon.KindRule, Int)?
            for rule in Lexicon.kindRules {
                guard let m = rule.rx.first(ns) else { continue }
                if best == nil || m.range.location < best!.1 { best = (rule, m.range.location) }
            }
            return best?.0
        }
        // 离金额最近的词为准：金额前面看最后一个，金额后面看第一个（「debited A/c and credited to X」）
        func cueDirection(_ text: String, nearestFirst: Bool = false) -> FlowDirection? {
            let ns = NSString(string: text)
            func position(_ rx: Rx) -> Int? {
                let matches = rx.matches(ns)
                return (nearestFirst ? matches.first : matches.last).map { nearestFirst ? -$0.range.location : $0.range.location + $0.range.length }
            }
            let inflow = position(Lexicon.inflowCue)
            let outflow = position(Lexicon.outflowCue)
            switch (inflow, outflow) {
            case let (i?, o?): return i >= o ? .inflow : .outflow
            case (.some, nil): return .inflow
            case (nil, .some): return .outflow
            default: return nil
            }
        }

        let suffix = Lexicon.timeNote.replace(suffix, with: " ")
        let message = message.map { Lexicon.timeNote.replace($0, with: " ") }
        // 预授权、冻结等状态词可能出现在句中任意位置
        let around = (prefix + " " + suffix).replacingOccurrences(of: "预授权完成", with: "")
        // 金额后面的「手续费 2 元」描述的是另一笔，不用来判断这一笔的性质
        let suffixForKind = feeClause.replace(suffix, with: " ")
        // 标题和金额不在一句时看整条通知。「Purchase Refund」两个词都有，退款是结果
        let refund = message.flatMap { text in Lexicon.kindRules.first { $0.kind == .refund && $0.rx.test(text) } }
        let rule = lastRule(in: prefix)?.0 ?? summary.flatMap(firstRule(in:)) ?? firstRule(in: suffixForKind) ?? refund ?? message.flatMap(firstRule(in:))
        var status: SettlementStatus = .posted
        if let statusRule = Lexicon.kindRules.first(where: { $0.status != .posted && $0.rx.test(around) }) { status = statusRule.status }
        // 紧贴金额的借贷记号最可靠；标题和金额不在一句时（`شراء…` 换行后才是金额）再看整条通知
        let cue = Lexicon.fromYourAccount.test(suffix) ? .outflow : markDirection(prefix: prefix, suffix: suffix)
            ?? cueDirection(prefix) ?? cueDirection(suffix, nearestFirst: true) ?? summary.flatMap { cueDirection($0) } ?? message.flatMap { cueDirection($0) }

        guard let rule else {
            if let cue { return KindDetection(kind: .other, direction: cue, status: status, uncertain: false) }
            return KindDetection(kind: .other, direction: nil, status: status, uncertain: true)
        }
        if rule.status != .posted { status = rule.status }
        if rule.transferGeneric {
            if Lexicon.sentOut.test(suffix) { return KindDetection(kind: .transferOut, direction: .outflow, status: status, uncertain: false) }
            guard let cue else { return KindDetection(kind: .other, direction: nil, status: status, uncertain: true) }
            return KindDetection(kind: cue == .inflow ? .transferIn : .transferOut, direction: cue, status: status, uncertain: false)
        }
        switch rule.kind {
        case .reversal:
            return KindDetection(kind: .reversal, direction: cue ?? .inflow, status: status, uncertain: false)
        case .repayment:
            // 方向不明时交给入账服务按账户类型决定（信用卡收到还款 / 借记卡付出还款）
            return KindDetection(kind: .repayment, direction: cue, status: status, uncertain: false)
        default:
            if rule.kind == .purchase, Lexicon.reversedAfter.test(suffix) {
                return KindDetection(kind: .reversal, direction: .inflow, status: status, uncertain: false)
            }
            // 「网上支付收入」「收入(跨行支付)」：「支付」只说明渠道，写明了收入就是钱进来了。不知道具体性质，和只写「收入」一样记为其他
            if rule.kind == .purchase, rule.direction == .outflow, cue == .inflow, Lexicon.explicitInflow.test(prefix) {
                return KindDetection(kind: .other, direction: .inflow, status: status, uncertain: false)
            }
            return KindDetection(kind: rule.kind, direction: rule.direction ?? cue, status: status, uncertain: rule.direction == nil && cue == nil)
        }
    }

    private static func markDirection(prefix: String, suffix: String) -> FlowDirection? {
        let before = String(prefix.suffix(16)), after = String(suffix.prefix(6))
        if Lexicon.debitMark.test(before) || Lexicon.debitMark.test(after) { return .outflow }
        if Lexicon.creditMark.test(before) || Lexicon.creditMark.test(after) { return .inflow }
        return nil
    }

    static func extractCounterparty(sentence: String, summary: String?) -> String? {
        let ns = NSString(string: sentence)
        for pattern in counterpartyPatterns {
            for match in pattern.matches(ns) {
                guard var value = match.group(1, in: ns) else { continue }
                value = value.replacingOccurrences(of: #"^[^】]*】"#, with: "", options: .regularExpression)
                value = value.replacingOccurrences(of: #"于\s*\d.*$"#, with: "", options: .regularExpression)
                value = value.replacingOccurrences(of: #"^(?:您的?|贵方)"#, with: "", options: .regularExpression)
                value = value.replacingOccurrences(of: #"\s*(?:于|在)\s*$"#, with: "", options: .regularExpression)
                value = value.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
                if value.count < 2 || counterpartyNoise.test(value) { continue }
                return value
            }
        }
        if let summary, !genericSummary.contains(summary), !counterpartyNoise.test(summary), summary.count >= 2 {
            return summary
        }
        return nil
    }

    private static func splitRanges(_ ns: NSString, by rx: Rx) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        for m in rx.matches(ns) {
            let end = m.range.location + m.range.length
            if end > start { ranges.append(NSRange(location: start, length: end - start)) }
            start = end
        }
        if start < ns.length { ranges.append(NSRange(location: start, length: ns.length - start)) }
        return ranges
    }

    private static func monthNumber(_ name: String?) -> Int? {
        guard let name = name?.lowercased().prefix(3) else { return nil }
        return ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(of: String(name)).map { $0 + 1 }
    }

    private static func makeClock(year: String?, month: String?, day: String?, hour: String?, minute: String?, second: String?, reference: Date, calendar: Calendar) -> WallClock? {
        let m = month.flatMap(Int.init)
        let d = day.flatMap(Int.init)
        let h = hour.flatMap(Int.init)
        let mi = minute.flatMap(Int.init)
        let s = second.flatMap(Int.init)
        if let m, !(1...12).contains(m) { return nil }
        if let d, !(1...31).contains(d) { return nil }
        if let h, !(0...23).contains(h) { return nil }
        if let mi, !(0...59).contains(mi) { return nil }
        if let s, !(0...59).contains(s) { return nil }
        guard (m != nil && d != nil) || (h != nil && mi != nil) else { return nil }
        var y = year.flatMap(Int.init)
        var inferred = false
        if y == nil, let m, let d {
            let refYear = calendar.component(.year, from: reference)
            y = refYear
            inferred = true
            if let candidate = calendar.date(from: DateComponents(year: refYear, month: m, day: d)), candidate > reference.addingTimeInterval(2 * 86_400) {
                y = refYear - 1
            }
        }
        if m == nil { y = nil; inferred = false }
        return WallClock(year: y, month: m, day: d, hour: h, minute: mi, second: s, yearInferred: inferred)
    }

    /// 「10月24日 」与「14:30」分开写时合并成一个时间。
    private static func mergeAdjacentDateAndTime(_ mentions: [Mention<WallClock>], in ns: NSString) -> [Mention<WallClock>] {
        var output: [Mention<WallClock>] = []
        for mention in mentions {
            if var last = output.last, last.value.hasDate, !last.value.hasTime, !mention.value.hasDate, mention.value.hasTime {
                let gapStart = last.range.location + last.range.length
                let gap = mention.range.location - gapStart
                if gap >= 0, gap <= 3, ns.substring(with: NSRange(location: gapStart, length: gap)).trimmingCharacters(in: .whitespaces).isEmpty {
                    last.value.hour = mention.value.hour
                    last.value.minute = mention.value.minute
                    last.value.second = mention.value.second
                    last.range = NSRange(location: last.range.location, length: mention.range.location + mention.range.length - last.range.location)
                    output[output.count - 1] = last
                    continue
                }
            }
            output.append(mention)
        }
        return output
    }
}

private extension Character {
    /// 紧贴在数字旁边时，说明这个数字是编号的一部分
    var isGluedToNumber: Bool { isASCII && isLetter }
}

/// 金额旁的币种写法。
enum CurrencyTokens {
    struct Found {
        var candidates: [CurrencyCode]
        var preferred: CurrencyCode?
        var symbolOnly: Bool
    }

    /// 「Rs」：印度、巴基斯坦、尼泊尔、斯里兰卡都这么写，账户持有哪个就是哪个
    private static let rupees: [CurrencyCode] = ["INR", "PKR", "NPR", "LKR"].map { CurrencyCode($0) }
    private static let dollarFamily: [CurrencyCode] = ["USD", "HKD", "SGD", "AUD", "CAD", "TWD", "NZD", "MOP"].map { CurrencyCode($0) }

    // 按长度从长到短匹配
    private static let tokens: [(String, [CurrencyCode], CurrencyCode?, Bool)] = [
        ("人民币", [.cny], .cny, false), ("澳门元", [CurrencyCode("MOP")], nil, false), ("瑞士法郎", [.chf], nil, false),
        ("新台币", [CurrencyCode("TWD")], nil, false), ("US$", [.usd], nil, false), ("HK$", [.hkd], nil, false),
        ("NT$", [CurrencyCode("TWD")], nil, false), ("S$", [CurrencyCode("SGD")], nil, false), ("A$", [CurrencyCode("AUD")], nil, false),
        ("C$", [CurrencyCode("CAD")], nil, false), ("RMB", [.cny], nil, false), ("CNY", [.cny], nil, false), ("EUR", [.eur], nil, false),
        ("USD", [.usd], nil, false), ("HKD", [.hkd], nil, false), ("GBP", [.gbp], nil, false), ("JPY", [.jpy], nil, false),
        ("CHF", [.chf], nil, false), ("SGD", [CurrencyCode("SGD")], nil, false), ("AUD", [CurrencyCode("AUD")], nil, false),
        ("CAD", [CurrencyCode("CAD")], nil, false), ("MOP", [CurrencyCode("MOP")], nil, false), ("TWD", [CurrencyCode("TWD")], nil, false),
        ("KRW", [CurrencyCode("KRW")], nil, false), ("SEK", [CurrencyCode("SEK")], nil, false), ("NOK", [CurrencyCode("NOK")], nil, false),
        ("DKK", [CurrencyCode("DKK")], nil, false), ("PLN", [CurrencyCode("PLN")], nil, false), ("CZK", [CurrencyCode("CZK")], nil, false),
        ("HUF", [CurrencyCode("HUF")], nil, false), ("美元", [.usd], nil, false), ("欧元", [.eur], nil, false), ("港币", [.hkd], nil, false),
        ("港元", [.hkd], nil, false), ("英镑", [.gbp], nil, false), ("日元", [.jpy], nil, false), ("韩元", [CurrencyCode("KRW")], nil, false),
        ("澳元", [CurrencyCode("AUD")], nil, false), ("加元", [CurrencyCode("CAD")], nil, false),
        ("دينار", [CurrencyCode("JOD"), CurrencyCode("KWD"), CurrencyCode("BHD")], nil, false), ("MT", [CurrencyCode("MZN")], nil, false), ("TL", [CurrencyCode("TRY")], nil, false),
        ("BIRR", [CurrencyCode("ETB")], nil, false), ("KSHS", [CurrencyCode("KES")], nil, false), ("KSH", [CurrencyCode("KES")], nil, false), ("TSHS", [CurrencyCode("TZS")], nil, false), ("TSH", [CurrencyCode("TZS")], nil, false),
        ("PHP", [CurrencyCode("PHP")], nil, false), ("INR", [CurrencyCode("INR")], nil, false), ("BAHT", [CurrencyCode("THB")], nil, false), ("NAIRA", [CurrencyCode("NGN")], nil, false),
        ("RS.", rupees, CurrencyCode("INR"), true), ("RS", rupees, CurrencyCode("INR"), true), ("R$", [CurrencyCode("BRL")], nil, false), ("RM", [CurrencyCode("MYR")], nil, false),
        ("RP", [CurrencyCode("IDR")], nil, false), ("TK", [CurrencyCode("BDT")], nil, false), ("DHS", [CurrencyCode("AED")], nil, false), ("SR", [CurrencyCode("SAR")], nil, false),
        ("₹", [CurrencyCode("INR")], nil, false), ("₱", [CurrencyCode("PHP")], nil, false), ("₦", [CurrencyCode("NGN")], nil, false), ("₫", [CurrencyCode("VND")], nil, false),
        ("฿", [CurrencyCode("THB")], nil, false), ("₺", [CurrencyCode("TRY")], nil, false), ("₪", [CurrencyCode("ILS")], nil, false), ("₴", [CurrencyCode("UAH")], nil, false),
        ("₽", [CurrencyCode("RUB")], nil, false), ("৳", [CurrencyCode("BDT")], nil, false), ("บาท", [CurrencyCode("THB")], nil, false), ("ريال", [CurrencyCode("SAR")], nil, false),
        ("ر.س", [CurrencyCode("SAR")], nil, false), ("درهم", [CurrencyCode("AED")], nil, false), ("د.إ", [CurrencyCode("AED")], nil, false), ("تومان", [CurrencyCode("IRR")], nil, false),
        ("菲律宾比索", [CurrencyCode("PHP")], nil, false), ("新加坡元", [CurrencyCode("SGD")], nil, false), ("新西兰元", [CurrencyCode("NZD")], nil, false),
        ("泰铢", [CurrencyCode("THB")], nil, false), ("林吉特", [CurrencyCode("MYR")], nil, false),
        ("€", [.eur], nil, false), ("£", [.gbp], nil, false), ("円", [.jpy], nil, false), ("₩", [CurrencyCode("KRW")], nil, false),
    ]

    /// 上面没列出的币种代码（PHP、THB……）。必须大写，「top 10」「all 5」不是金额
    private static let isoCodes = Set(CurrencyCode.supported.map(\.rawValue))

    private static func isoCode(_ letters: Substring, neighbour: Character?) -> Found? {
        guard letters.count == 3, isoCodes.contains(String(letters)), !(neighbour?.isLetter == true && neighbour?.isASCII == true) else { return nil }
        return Found(candidates: [CurrencyCode(String(letters))], preferred: nil, symbolOnly: false)
    }

    static func prefix(in before: String) -> Found? {
        let trimmed = before.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespaces)
        let upper = trimmed.uppercased()
        for (token, candidates, preferred, symbolOnly) in tokens where upper.hasSuffix(token.uppercased()) {
            // 「EUR」之类的字母代码前面不能紧跟字母（避免把单词的一部分当成币种）
            if token.first!.isLetter, token.first!.isASCII {
                let rest = upper.dropLast(token.count)
                if let previous = rest.last, previous.isASCII, previous.isLetter { continue }
            }
            return Found(candidates: candidates, preferred: preferred, symbolOnly: symbolOnly)
        }
        if trimmed.hasSuffix("¥") { return Found(candidates: [.cny, .jpy], preferred: nil, symbolOnly: true) }
        if trimmed.hasSuffix("$") { return Found(candidates: dollarFamily, preferred: nil, symbolOnly: true) }
        return isoCode(trimmed.suffix(3), neighbour: trimmed.dropLast(3).last)
    }

    static func suffix(in after: String) -> Found? {
        let trimmed = after.drop { $0 == " " }
        let upper = trimmed.uppercased()
        for (token, candidates, preferred, symbolOnly) in tokens where upper.hasPrefix(token.uppercased()) {
            if token.first!.isLetter, token.first!.isASCII {
                let rest = upper.dropFirst(token.count)
                if let next = rest.first, next.isASCII, next.isLetter { continue }
            }
            return Found(candidates: candidates, preferred: preferred, symbolOnly: symbolOnly)
        }
        if trimmed.hasPrefix("元") || trimmed.hasPrefix("圆") {
            return Found(candidates: [.cny, .hkd, CurrencyCode("MOP"), CurrencyCode("TWD")], preferred: .cny, symbolOnly: true)
        }
        return isoCode(trimmed.prefix(3), neighbour: trimmed.dropFirst(3).first)
    }

    /// 合并前后缀：「人民币100.00元」→ CNY；「¥100」在中文通知里优先 CNY，但保留 JPY 候选。
    static func combine(_ prefix: Found?, _ suffix: Found?, chineseText: Bool) -> (candidates: [CurrencyCode], preferred: CurrencyCode?) {
        switch (prefix, suffix) {
        case (nil, nil):
            return ([], nil)
        case let (p?, nil):
            return (p.candidates, p.preferred ?? (p.candidates.count == 1 ? p.candidates[0] : (chineseText && p.candidates.contains(.cny) ? .cny : nil)))
        case let (nil, s?):
            return (s.candidates, s.preferred ?? (s.candidates.count == 1 ? s.candidates[0] : nil))
        case let (p?, s?):
            let intersection = p.candidates.filter(s.candidates.contains)
            if !intersection.isEmpty {
                let preferred = intersection.count == 1 ? intersection[0] : (p.preferred ?? s.preferred)
                return (intersection, preferred)
            }
            // 「美元100元」这类：明确的代码优先于泛用的「元」
            if !p.symbolOnly { return (p.candidates, p.candidates.count == 1 ? p.candidates[0] : p.preferred) }
            if !s.symbolOnly { return (s.candidates, s.candidates.count == 1 ? s.candidates[0] : s.preferred) }
            return (p.candidates + s.candidates, nil)
        }
    }
}
