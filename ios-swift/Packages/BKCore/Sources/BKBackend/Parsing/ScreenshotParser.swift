import Foundation
import BKModel

/// 截图上识别出的文字排成行（ADR 0021）：竖直方向对得上的几段算同一行，从左到右连起来；行从上到下。
/// 这样「支付方式」和右边的「零钱」在同一行，解析和测试都只看文字。
public enum ScreenLayout {
    public static func text(_ lines: [ScreenTextLine]) -> String { rows(lines).joined(separator: "\n") }

    public static func rows(_ lines: [ScreenTextLine]) -> [String] {
        let sorted = lines
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.midY < $1.midY }
        var groups: [[ScreenTextLine]] = []
        for line in sorted {
            if let last = groups.last {
                let mid = last.map(\.midY).reduce(0, +) / Double(last.count)
                let height = min(last.map(\.height).min() ?? line.height, line.height)
                if abs(line.midY - mid) < height * 0.5 {
                    groups[groups.count - 1].append(line)
                    continue
                }
            }
            groups.append([line])
        }
        return groups.map { group in
            group.sorted { $0.x < $1.x }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "  ")
        }
    }
}

/// 截图读出来的结果：交给入账的部分和 `MessageParser` 的一样，另外记下页面写没写用什么付的。
struct ScreenshotReading: Sendable {
    var message: ParsedMessage
    /// 页面写了用什么付的（零钱、余额、哪张卡），或者写了钱存进了零钱、余额。没写时记到的钱包是猜的，
    /// 之后同一笔的银行通知来了，这笔改到那张卡上
    var methodStated: Bool
    /// 用零钱通、余额宝、花呗付的：先找名称里有这几个字的账户
    var methodName: String?
    /// 银行 App 的换汇页：两笔（卖出、买入）记在同一个账户，配成一对（`IngestEngine.exchangeRoute`）
    var exchange = false
}

/// 微信、支付宝付款页截图的规则解析（ADR 0021）：纯函数，不访问数据库。
/// 先认页面（付款成功、账单详情、转账、红包、退款、提现、充值），靠的是页面上固定的字，再按标签读出金额、商户、时间、支付方式和单号。
/// 认不出是付款页的不记；像付款页又读不全的进待处理。
enum ScreenshotParser {
    static let version = 1

    // MARK: 标签

    /// 行首的标签，长的在前：「商户全称」不能当成「商户」
    private static let labels: [(key: Label, names: [String])] = [
        (.ignored, ["商户全称", "收款方全称", "收单机构", "商户单号", "商家订单号", "商品说明", "商品", "账单分类", "标签和备注", "备注", "转账说明", "支付奖励", "服务详情", "计入收支",
                    "收款店铺", "收款方式", "聊天位置", "服务费", "经营账户余额"]),
        (.method, ["支付方式", "付款方式", "支付卡", "付款卡", "扣款方式"]),
        (.target, ["到账银行卡", "到账银行", "提现银行卡", "提现银行", "提现到", "充值银行卡", "充值来源"]),
        (.status, ["当前状态", "交易状态", "支付状态", "转账状态", "状态"]),
        (.reference, ["交易单号", "转账单号", "订单号", "退款单号", "红包单号", "提现单号", "收款单号", "交易编号", "交易号"]),
        (.counterparty, ["收款商户", "商户名称", "收款方", "收款人", "对方账户", "对方", "转账给", "付款方", "付款人", "商户"]),
        (.amount, ["付款金额", "支付金额", "收款金额", "转账金额", "退款金额", "实付款", "实付", "金额"]),
        (.time, ["支付时间", "付款时间", "交易时间", "转账时间", "收款时间", "到账时间", "退款时间", "提现时间", "充值时间", "领取时间", "发起时间", "创建时间", "申请时间"]),
    ]

    private enum Label { case ignored, method, target, status, reference, counterparty, amount, time }

    private static let timePreference = ["支付时间", "付款时间", "交易时间", "转账时间", "到账时间", "退款时间", "提现时间", "充值时间", "收款时间", "领取时间", "发起时间", "创建时间", "申请时间"]

    // MARK: 识别用正则

    /// 只有金额的一行：「¥12.00」「-12.00」「+100.00」「6.66元」。OCR 常把「¥」认成「Y」。没有两位小数的（时间、电量）不算
    private static let amountOnly = Rx(#"^([-+])?\s*[¥Y]?\s*([-+])?\s*(\d{1,3}(?:,\d{3})+|\d+)\.(\d{2})\s*元?$"#, caseInsensitive: false)
    private static let amountInText = Rx(#"([-+])?\s*¥?\s*(\d{1,3}(?:,\d{3})+|\d+)\.(\d{2})"#, caseInsensitive: false)
    private static let fullDate = Rx(#"(20\d{2})\s*[年/.-]\s*(\d{1,2})\s*[月/.-]\s*(\d{1,2})\s*日?\s*(\d{1,2})\s*[:：]\s*(\d{2})(?:\s*[:：]\s*(\d{2}))?"#)
    private static let monthDay = Rx(#"(\d{1,2})\s*月\s*(\d{1,2})\s*日\s*(\d{1,2})\s*[:：]\s*(\d{2})(?:\s*[:：]\s*(\d{2}))?"#)
    private static let tail = Rx(#"\((\d{4})\)|尾号\s*(\d{4})|(?<!\d)(\d{4})\s*$"#)
    private static let reference = Rx(#"^[A-Za-z0-9]{10,40}$"#)

    /// 看得出是付款相关的页面；一个都没有的截图不记、不进待处理
    private static let paymentMark = Rx(#"支付成功|付款成功|交易成功|支付时间|付款时间|支付方式|付款方式|转账|转帐|红包|收款|退款|提现|充值|当前状态|交易单号|订单号|账单详情|已存入"#)
    /// 「经营账户」是微信收款商业版收的钱存的地方，收款页、提现页上只有它，没有「微信」「零钱」
    private static let wechatMarks = ["微信", "零钱", "财付通", "转账单号", "交易单号", "商户单号", "收单机构", "经营账户", "聊天位置"]
    private static let alipayMarks = ["支付宝", "余额宝", "花呗", "账单分类", "收款方全称", "商家订单号", "蚂蚁"]

    private static let outgoingWords = Rx(#"对方已收|待对方|待.{0,8}(?:确认)?收款|转给|发给|付款给|已转账|转账成功|发出的红包"#)
    private static let incomingWords = Rx(#"已收款|你已收款|已收钱|收款成功|已存入|存入零钱|收款到账|二维码收款|来自|已领取.{0,4}红包|收到"#)
    private static let purchaseWords = Rx(#"支付成功|付款成功|交易成功|支付时间|付款时间|支付方式|付款方式|收单机构|商户全称"#)
    private static let failedWords = Rx(#"支付失败|交易失败|交易关闭|已关闭|已撤销|已取消|已退还|已退回|已过期"#)
    /// 零钱和零钱通、余额和余额宝之间挪钱：不是收支，也不是付款
    private static let ownMove = Rx(#"零钱通(?:转入|转出)|(?:转入|转出到?)零钱通|余额宝(?:转入|转出)|(?:转入|转出到?)余额宝|零钱通-"#)
    private static let withdraw = Rx(#"(?:零钱|余额)提现|提现-到|提现到|^提现"#)
    private static let topUp = Rx(#"(?:零钱|余额)充值|充值-来自|充值到(?:零钱|余额)"#)
    private static let refund = Rx(#"退款"#)
    /// 收款页底部「联系顾客 | 退款 | 帮助中心」里单独的「退款」是按钮，不是这笔退了款
    private static let refundButton = Rx(#"(?:^|\s|[|｜丨])退款(?=$|\s|[|｜丨])"#)
    private static let savedToWallet = Rx(#"已存入|存入零钱|存入余额"#)
    /// 微信收款商业版：顾客付给自己店铺的钱，存进经营账户，是收入
    private static let businessReceipt = Rx(#"经营账户|收款店铺"#)
    /// 微信转账页的标题写着谁收了钱：「你已收款，资金已存入零钱」「待你收款」是自己收，「阿翔已收款」「待阿翔确认收款」是对方收、钱是自己转出去的
    private static let receivedTitle = Rx(#"^(?:待(.{1,24}?)(?:确认)?收款|(.{1,24}?)已收款)(?:[，,\s].*)?$"#)

    /// 页面上的这些行不是商户名称：状态栏、导航、页面标题、按钮
    private static let noiseRow = Rx(#"^(?:\d{1,2}[:：]\d{2}|[0-9]{1,3}%?|[45]G|LTE|WiFi|<|返回|账单详情|交易详情|详情|全部账单|全部收款明细|账单|支付成功|付款成功|交易成功|转账成功|收款成功|已收款|你已收款|微信支付|支付宝|完成|返回商家|\.{2,}|…+|·+|X|x|更多|查看账单|查看详情|联系商家|申请退款|常见问题|对此订单有疑问)$"#)
    private static let adWords = Rx(#"优惠|券|奖励|领取|广告|立即|查看|积分|抽奖|推荐|活动|开通|服务|关注|公众号|小程序|随机立减|立减"#)
    private static let titlePrefix = Rx(#"^(?:转账-转给|转账-来自|转账给|转账-|微信红包-发给|微信红包-来自|微信红包-|扫二维码付款-给|二维码收款-来自|付款给|收款方[:：]?)\s*"#)
    private static let titleSuffix = Rx(#"(?:发出的?|的)红包$|(?:\.{2,}|…+)$"#)
    /// 红包页上写着谁发的：「王五的红包」「某某发出红包」「某某发出的红包」。新版红包页这行下面是祝福语，不是对方
    private static let redPacketSender = Rx(#"^(.{1,24}?)(?:发出的?|的)红包$"#)

    // MARK: 换汇页（银行 App）

    /// 银行 App 的货币兑换结果页（众安「货币兑换成功」）：同一个账户里卖出一个币种、买入另一个币种
    private static let exchangeMark = Rx(#"兑换|换汇|(?<![A-Za-z])exchange"#)
    /// 「+HKD 39.02」「-USD 5.00」：带正负号和币种代码的金额。OCR 会把负号认成破折号、减号
    private static let signedCurrencyAmount = Rx(#"(?<![A-Za-z0-9.])([-+−–—])\s*([A-Za-z]{3})\s*(\d{1,3}(?:,\d{3})+|\d+)\.(\d{2})(?![0-9])"#)
    /// 「卖出 (USD)」「买入 (HKD)」：两个金额在上一行，从左到右和这一行的标签对应
    private static let exchangeSide = Rx(#"(?<![A-Za-z])(卖出|买入|sell|buy)\s*[(（]?\s*([A-Za-z]{3})(?![A-Za-z])\s*[)）]?"#)
    private static let plainAmount = Rx(#"(?<![0-9.,])(\d{1,3}(?:,\d{3})+|\d+)\.(\d{2})(?![0-9])"#)
    private static let exchangeTimeRow = Rx(#"^(?:兑换时间|交易时间|时间)\s"#)
    private static let exchangeFailed = Rx(#"兑换失败|交易失败|未成功|已取消|(?<![A-Za-z])failed"#)

    struct ExchangeLeg: Equatable {
        var currency: CurrencyCode
        var digits: String
    }

    // MARK: 入口

    static func cleaned(_ text: String) -> String {
        let rows = TextNormalizer.normalize(text).split(separator: "\n").map { row in
            // 「—12.00」「–12.00」：OCR 把负号认成了破折号
            row.replacingOccurrences(of: #"^[—–]\s*(?=[¥Y]?\s*\d)"#, with: "-", options: .regularExpression)
        }
        return rows.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func parse(_ text: String, referenceDate: Date, calendar: Calendar) -> ScreenshotReading {
        let cleaned = cleaned(text)
        let rows = cleaned.split(separator: "\n").map(String.init)
        func result(_ classification: MessageClassification, _ events: [ParsedEvent] = [], wallet: String? = nil, bank: String? = nil, tails: [String] = [],
                    time: WallClock? = nil, reference: String? = nil, hasAmount: Bool = false, stated: Bool = false, name: String? = nil) -> ScreenshotReading {
            ScreenshotReading(
                message: ParsedMessage(
                    classification: classification, events: events, balances: [], bankHint: bank, walletHint: wallet, cleanedText: cleaned, cardTails: tails,
                    firstTime: time, onlyReference: reference, hasAmount: hasAmount, bankSignature: false, nonBankSignature: false
                ),
                methodStated: stated, methodName: name
            )
        }
        guard !rows.isEmpty else { return result(.noFinancialContent) }
        let paymentLike = paymentMark.test(cleaned)

        // 1. 标签：「支付方式  零钱」在同一行；值换到下一行的也认
        var values: [Label: (name: String, value: String, row: Int)] = [:]
        var timeValues: [String: String] = [:]
        var labelRows = Set<Int>()
        for (index, row) in rows.enumerated() {
            guard let found = Self.label(of: row) else { continue }
            let (key, name, rest) = found
            labelRows.insert(index)
            var value = rest
            if value.isEmpty, index + 1 < rows.count, Self.label(of: rows[index + 1]) == nil { value = rows[index + 1] }
            if key == .reference {
                // 单号太长时换行：下一行全是数字就接上
                value = value.replacingOccurrences(of: " ", with: "")
                if index + 1 < rows.count, rows[index + 1].replacingOccurrences(of: " ", with: "").allSatisfy(\.isNumber), Self.label(of: rows[index + 1]) == nil {
                    value += rows[index + 1].replacingOccurrences(of: " ", with: "")
                }
            }
            if key == .time { timeValues[name] = timeValues[name] ?? value }
            if values[key] == nil { values[key] = (name, value, index) }
        }

        // 银行 App 的换汇页：不是付款页，没有「支付成功」这类字，两个金额写在同一行。认出来就记成同一个账户里的一对转帐
        if let legs = exchangeLegs(rows: rows, cleaned: cleaned) {
            let timeRow = rows.first { exchangeTimeRow.test($0) }
            let time = timeRow.flatMap { clock(in: $0, reference: referenceDate, calendar: calendar) } ?? clock(in: cleaned, reference: referenceDate, calendar: calendar)
            let ref = (values[.reference]?.value).flatMap { Self.reference.test($0) ? $0 : nil }
            let status: SettlementStatus = exchangeFailed.test(cleaned) ? .failed : .posted
            let snippet = "\(legs.sold.currency) \(legs.sold.digits) → \(legs.bought.currency) \(legs.bought.digits)"
            func draft(_ leg: ExchangeLeg, _ direction: FlowDirection, part: Int) -> EventDraft {
                EventDraft(
                    amount: AmountText(digits: leg.digits, currencyCandidates: [leg.currency], preferredCurrency: leg.currency),
                    direction: direction, kind: direction == .outflow ? .transferOut : .transferIn, status: status, counterparty: nil, cardTail: nil,
                    counterpartyTail: nil, transactionTime: time, bankReference: ref, balanceAfter: nil, includedFee: nil, isSplitFee: false,
                    partIndex: part, bankHint: nil, walletHint: nil, evidenceSnippet: snippet
                )
            }
            var reading = result(
                .transaction, [ParsedEvent(draft: draft(legs.sold, .outflow, part: 0), issue: nil), ParsedEvent(draft: draft(legs.bought, .inflow, part: 2), issue: nil)],
                time: time, reference: ref, hasAmount: true, stated: true
            )
            reading.exchange = true
            return reading
        }

        // 2. 金额：第一行只有金额的；没有就看「付款金额 ¥12.00」
        var amountRow: Int?
        var sign: String?
        var digits: String?
        for (index, row) in rows.enumerated() where !labelRows.contains(index) {
            let ns = NSString(string: row)
            guard let m = amountOnly.first(ns) else { continue }
            amountRow = index
            sign = m.group(1, in: ns) ?? m.group(2, in: ns)
            digits = (m.group(3, in: ns) ?? "") + "." + (m.group(4, in: ns) ?? "00")
            break
        }
        if digits == nil, let labeled = values[.amount]?.value {
            let ns = NSString(string: labeled)
            if let m = amountInText.first(ns) {
                sign = m.group(1, in: ns)
                digits = (m.group(2, in: ns) ?? "") + "." + (m.group(3, in: ns) ?? "00")
            }
        }
        guard let digits else { return result(paymentLike ? .unrecognized : .noFinancialContent) }
        guard paymentLike else { return result(.noFinancialContent) }

        // 3. 哪个 App：页面上的字；支付方式写了零钱、余额也算。
        // 微信聊天里点开的转账页只有「某某已收款」「转账时间」「收款时间」：要对方点收款的转账是微信的
        let method = values[.method]?.value
        let receiver = Self.receiver(rows: rows, before: amountRow, labelRows: labelRows)
        var app = whichApp(cleaned)
        if app == nil, receiver != nil || (timeValues["转账时间"] != nil && timeValues["收款时间"] != nil) { app = "wechatpay" }
        if let method {
            if method.contains("零钱") { app = "wechatpay" } else if method.contains("余额宝") || method.contains("花呗") || method.contains("账户余额") || method == "余额" { app = "alipay" }
        }

        // 4. 页面是哪一种
        let methodRow = values[.method]?.row
        let pageText = rows.enumerated().filter { $0.offset != methodRow }.map(\.element).joined(separator: "\n")
        if ownMove.test(pageText) { return result(.noFinancialContent) }
        let title = Self.title(rows: rows, amountRow: amountRow, labelRows: labelRows)
        let titleText = title ?? ""
        let isWithdraw = withdraw.test(titleText) || withdraw.test(pageText)
        let isTopUp = topUp.test(titleText) || topUp.test(pageText)
        let isRedPacket = pageText.contains("红包")
        let isTransfer = pageText.contains("转账") || pageText.contains("转帐")
        let status = values[.status]?.value ?? ""
        let isRefund = refund.test(titleText) || status.contains("退款成功") || (sign == "+" && refund.test(refundButton.replace(pageText, with: " ")))
        let toBusiness = businessReceipt.test(pageText)
        let sender = isRedPacket ? Self.redPacketSender(rows: rows, before: amountRow, labelRows: labelRows) : nil

        // 5. 方向：先看正负号，再看页面上的字。「谁已收款」先于「已收款」这类词：对方收了是自己付的。
        // 红包存进了自己的零钱是收到的，页面上写「某某发出的红包」也一样
        var direction: FlowDirection?
        if sign == "-" { direction = .outflow } else if sign == "+" { direction = .inflow }
        if direction == nil {
            if isRefund || isTopUp { direction = .inflow }
            else if isWithdraw { direction = .outflow }
            else if let receiver { direction = receiver == "你" ? .inflow : .outflow }
            else if isRedPacket, savedToWallet.test(pageText) { direction = .inflow }
            else if outgoingWords.test(pageText) { direction = .outflow }
            else if incomingWords.test(pageText) { direction = .inflow }
            else if purchaseWords.test(pageText) { direction = .outflow }
        }

        let kind: TransactionKind
        if isWithdraw { kind = .transferOut }
        else if isTopUp { kind = .transferIn }
        else if isRefund { kind = .refund }
        else if toBusiness, direction == .inflow { kind = .income }
        else if isRedPacket { kind = direction == .inflow ? .income : .other }
        else if isTransfer { kind = direction == .inflow ? .transferIn : .transferOut }
        else { kind = direction == .inflow ? .income : .purchase }

        let settlement: SettlementStatus = failedWords.test(status) || (status.isEmpty && failedWords.test(pageText)) ? .failed : .posted

        // 6. 记到哪：支付方式写了卡就记到卡；写了零钱、余额，或者没写，记到这个 App 的钱包。提现、充值的卡是转账的另一边。
        // 经营账户收的、提现的：先找名称里有「经营账户」的账户，没有就是微信钱包
        var cardTail: String?
        var counterpartyTail: String?
        var bankHint: String?
        var stated = false
        var methodName: String?
        let incomeToWallet = direction == .inflow && savedToWallet.test(pageText)
        if isWithdraw || isTopUp {
            let source = values[.target]?.value ?? method ?? pageText
            counterpartyTail = tailOf(source)
            stated = true
            if toBusiness { methodName = "经营账户" }
        } else if let method {
            stated = true
            if method.contains("零钱通") { methodName = "零钱通" }
            else if method.contains("余额宝") { methodName = "余额宝" }
            else if method.contains("花呗") { methodName = "花呗" }
            else if method.contains("亲属卡") { methodName = "亲属卡" }
            else if !method.contains("零钱"), !method.contains("余额") {
                cardTail = tailOf(method)
                bankHint = bank(in: method)
            }
        } else if incomeToWallet {
            stated = true
            if toBusiness { methodName = "经营账户" }
        }
        let walletHint = cardTail == nil && bankHint == nil ? app : nil

        // 7. 商户或对方：标签 > 金额上面那一行（页面标题）> 金额下面不像广告的一行。
        // 转账页的标题是「谁已收款」：对方收的取名字；自己收的页面上没写对方，金额下面的「零钱余额」也不是。
        // 红包页取发红包的人，不取金额上面的祝福语
        var counterparty = values[.counterparty]?.value
        if counterparty == nil || counterparty?.isEmpty == true {
            if let receiver { counterparty = receiver == "你" || receiver == "对方" ? nil : receiver }
            else if let sender { counterparty = sender == "你" || sender == "我" ? nil : sender }
            else { counterparty = title }
        }
        if counterparty == nil, receiver == nil, sender == nil, let amountRow, amountRow + 1 < rows.count, !labelRows.contains(amountRow + 1) {
            let below = rows[amountRow + 1]
            if below.count <= 20, !noiseRow.test(below), !adWords.test(below), !failedWords.test(below), amountOnly.first(NSString(string: below)) == nil { counterparty = below }
        }
        counterparty = counterparty.map(cleanName).flatMap { $0.isEmpty ? nil : $0 }
        if isWithdraw || isTopUp || (isRefund && counterparty?.contains("退款") == true) { counterparty = nil }

        // 8. 时间、单号
        let preferred = direction == .inflow ? ["收款时间", "到账时间"] + timePreference : timePreference
        let timeText = preferred.lazy.compactMap { timeValues[$0] }.first ?? cleaned
        let time = clock(in: timeText, reference: referenceDate, calendar: calendar) ?? clock(in: cleaned, reference: referenceDate, calendar: calendar)
        let ref = (values[.reference]?.value).flatMap { Self.reference.test($0) ? $0 : nil }

        let amount = AmountText(digits: digits, currencyCandidates: [.cny], preferredCurrency: .cny)
        let snippet = [counterparty, (sign ?? "") + digits, method].compactMap { $0 }.joined(separator: " ")
        let draft = EventDraft(
            amount: amount, direction: direction, kind: kind, status: settlement, counterparty: counterparty, cardTail: cardTail,
            counterpartyTail: counterpartyTail, transactionTime: time, bankReference: ref, balanceAfter: nil, includedFee: nil, isSplitFee: false,
            partIndex: 0, bankHint: bankHint, walletHint: walletHint, evidenceSnippet: snippet
        )
        let issue: PendingReason? = direction == nil ? .uncertainKind : nil
        return result(
            .transaction, [ParsedEvent(draft: draft, issue: issue)], wallet: walletHint, bank: bankHint, tails: [cardTail, counterpartyTail].compactMap { $0 },
            time: time, reference: ref, hasAmount: true, stated: stated, name: methodName
        )
    }

    /// 页面写没写用什么付的（入账时判断以前那笔截图的钱包是不是猜的）
    static func statesMethod(_ text: String, calendar: Calendar) -> Bool {
        parse(text, referenceDate: Date(), calendar: calendar).methodStated
    }

    /// 换汇页卖出、买入的币种和金额。先看「卖出 (USD)  买入 (HKD)」和上一行的两个金额，再看「-USD 5.00」「+HKD 39.02」。
    /// 两个币种要不一样，并且都是认得的币种代码；页面上没有「兑换」「换汇」的不算
    static func exchangeLegs(rows: [String], cleaned: String) -> (sold: ExchangeLeg, bought: ExchangeLeg)? {
        guard exchangeMark.test(cleaned) else { return nil }
        func code(_ raw: String) -> CurrencyCode? {
            let code = CurrencyCode(raw)
            return CurrencyCode.supported.contains(code) ? code : nil
        }
        func digits(_ m: NSTextCheckingResult, _ ns: NSString, from group: Int) -> String {
            (m.group(group, in: ns) ?? "") + "." + (m.group(group + 1, in: ns) ?? "00")
        }
        for index in rows.indices.dropFirst() {
            let ns = NSString(string: rows[index])
            let sides = exchangeSide.matches(ns).compactMap { m -> (sell: Bool, code: CurrencyCode)? in
                guard let word = m.group(1, in: ns), let c = m.group(2, in: ns).flatMap(code) else { return nil }
                return (word == "卖出" || word.lowercased() == "sell", c)
            }
            guard sides.count == 2, sides[0].sell != sides[1].sell, sides[0].code != sides[1].code else { continue }
            let above = NSString(string: rows[index - 1])
            let amounts = plainAmount.matches(above).map { digits($0, above, from: 1) }
            guard amounts.count == 2 else { continue }
            let legs = zip(sides, amounts).map { (sell: $0.0.sell, leg: ExchangeLeg(currency: $0.0.code, digits: $0.1)) }
            guard let sold = legs.first(where: { $0.sell })?.leg, let bought = legs.first(where: { !$0.sell })?.leg else { continue }
            return (sold, bought)
        }
        var sold: [ExchangeLeg] = [], bought: [ExchangeLeg] = []
        for row in rows {
            let ns = NSString(string: row)
            for m in signedCurrencyAmount.matches(ns) {
                guard let sign = m.group(1, in: ns), let c = m.group(2, in: ns).flatMap(code) else { continue }
                let leg = ExchangeLeg(currency: c, digits: digits(m, ns, from: 3))
                if sign == "+" { if !bought.contains(leg) { bought.append(leg) } } else if !sold.contains(leg) { sold.append(leg) }
            }
        }
        guard sold.count == 1, bought.count == 1, sold[0].currency != bought[0].currency else { return nil }
        return (sold[0], bought[0])
    }

    // MARK: 小工具

    private static func label(of row: String) -> (Label, String, String)? {
        for (key, names) in labels {
            for name in names where row.hasPrefix(name) {
                var rest = String(row.dropFirst(name.count))
                // 「状态」不能吃掉「状态栏」这类字；标签后面要么没字，要么是空格、冒号
                if let first = rest.first, !(first == " " || first == ":" || first == "：") { continue }
                rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " :："))
                return (key, name, rest)
            }
        }
        return nil
    }

    private static func whichApp(_ text: String) -> String? {
        let wechat = wechatMarks.filter(text.contains).count
        let alipay = alipayMarks.filter(text.contains).count
        if wechat > alipay { return "wechatpay" }
        if alipay > wechat { return "alipay" }
        return nil
    }

    /// 金额上面最近的、不是状态栏和标题的一行
    private static func title(rows: [String], amountRow: Int?, labelRows: Set<Int>) -> String? {
        guard let amountRow, amountRow > 0 else { return nil }
        for index in stride(from: amountRow - 1, through: 0, by: -1) where !labelRows.contains(index) {
            let row = rows[index]
            if noiseRow.test(row) || amountOnly.first(NSString(string: row)) != nil { continue }
            if row.count > 40 { return nil }
            return row
        }
        return nil
    }

    /// 金额上面写着谁收了钱的一行（`receivedTitle`）：收钱的人，自己是「你」
    private static func receiver(rows: [String], before amountRow: Int?, labelRows: Set<Int>) -> String? {
        let end = amountRow ?? rows.count
        guard end > 0 else { return nil }
        for index in stride(from: end - 1, through: 0, by: -1) where !labelRows.contains(index) {
            let ns = NSString(string: rows[index])
            guard let m = receivedTitle.first(ns) else { continue }
            let name = (m.group(1, in: ns) ?? m.group(2, in: ns))?.trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// 金额上面写着谁发的红包的一行（`redPacketSender`）：发红包的人
    private static func redPacketSender(rows: [String], before amountRow: Int?, labelRows: Set<Int>) -> String? {
        guard let amountRow, amountRow > 0 else { return nil }
        for index in stride(from: amountRow - 1, through: 0, by: -1) where !labelRows.contains(index) {
            let ns = NSString(string: rows[index])
            guard let m = redPacketSender.first(ns) else { continue }
            let name = m.group(1, in: ns)?.trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? nil : name
        }
        return nil
    }

    private static func cleanName(_ raw: String) -> String {
        let name = titleSuffix.replace(titlePrefix.replace(raw, with: ""), with: "")
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tailOf(_ text: String) -> String? {
        let ns = NSString(string: text)
        guard let m = tail.first(ns) else { return nil }
        return m.group(1, in: ns) ?? m.group(2, in: ns) ?? m.group(3, in: ns)
    }

    /// 「招商银行储蓄卡(1234)」「建行信用卡」里的银行
    private static func bank(in text: String) -> String? {
        var best: (id: String, length: Int)?
        for bank in BankDirectory.all {
            for name in [bank.name] + bank.signatures where text.contains(name) {
                if best == nil || name.count > best!.length { best = (bank.id, name.count) }
            }
        }
        if let best { return best.id }
        let name = text.replacingOccurrences(of: #"(?:储蓄卡|借记卡|信用卡|贷记卡|银行卡|卡)?\s*(?:\(\d{4}\)|尾号\d{4})?$"#, with: "", options: .regularExpression)
        return BankCatalog.entry(signature: name)?.id
    }

    private static func clock(in text: String, reference: Date, calendar: Calendar) -> WallClock? {
        let ns = NSString(string: text)
        if let m = fullDate.first(ns) {
            let n = (1...6).map { m.group($0, in: ns).flatMap(Int.init) }
            guard let year = n[0], let month = n[1], let day = n[2], let hour = n[3], let minute = n[4], (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60 else { return nil }
            return WallClock(year: year, month: month, day: day, hour: hour, minute: minute, second: n[5])
        }
        if let m = monthDay.first(ns) {
            let n = (1...5).map { m.group($0, in: ns).flatMap(Int.init) }
            guard let month = n[0], let day = n[1], let hour = n[2], let minute = n[3], (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60 else { return nil }
            // 没写年份：不晚于截图那天的最近一年
            let now = calendar.dateComponents([.year, .month, .day], from: reference)
            var year = now.year ?? 2026
            if let m0 = now.month, let d0 = now.day, month > m0 || (month == m0 && day > d0) { year -= 1 }
            return WallClock(year: year, month: month, day: day, hour: hour, minute: minute, second: n[4], yearInferred: true)
        }
        return nil
    }
}
