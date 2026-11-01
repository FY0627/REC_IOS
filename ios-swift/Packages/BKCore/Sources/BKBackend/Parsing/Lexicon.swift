import BKModel

/// 解析用到的关键词表。新增银行格式时，优先在这里补词，再在 `ParserSamples` 测试里补脱敏样例。
enum Lexicon {
    // MARK: 整条通知的类别

    static let verificationCode = Rx(#"验证码|校验码|动态码|动态密码|短信密码|一次性密码|\bOTP\b|one[- ]time (?:password|code)|verification code|verify code|security code|passcode|bestätigungscode|\bm?TAN\b"#)
    /// 正文里真的给出了一个验证码（只提到「验证码」字样的安全提示不算）
    static let verificationCodeValue = Rx(#"(?:验证码|校验码|动态码|动态密码|短信密码|一次性密码)\s*(?:是|为)?\s*[：:]?\s*[A-Za-z0-9]{4,8}(?![\d])|(?<![\d.])\d{4,8}\s*(?:是|为)?\s*(?:您的?)?(?:本次)?(?:验证码|校验码|动态码|动态密码)|(?:\bOTP\b|one[- ]time (?:password|code)|verification code|verify code|security code|passcode|bestätigungscode)\s*(?:is|:|ist)?\s*[：:]?\s*\d{4,8}|\d{4,8}\s+is your (?:otp|verification code|code)|\bOTP for\b|\d{4,8}\s*هو\s*رمز|(?:الرقم السري|كلمة السر|رمز التحقق|رمز التفعيل|c[oó]digo de (?:verificaci[oó]n|seguridad)|код подтверждения|doğrulama kodu).{0,80}?(?<![\d.])\d{4,8}(?!\d)"#)
    static let statement = Rx(#"电子账单|对账单|月结单|账单明细|本期账单明细|e-?statement|monthly statement|statement of account|kontoauszug"#)
    static let reminder = Rx(#"还款提醒|账单提醒|扣款提醒|温馨提示.{0,20}还款|到期还款日|最后还款日|账单日|最低还款|应还款?额|本期应还|账单已出|已出账|payment due|due date|minimum payment|statement (?:is )?ready|将于|将在|即将|预计.{0,6}(?:扣款|扣收|还款|入账)|请于|请在.{0,12}前|请确保|请保证|请存入|请及时还款|请按时还款|will be (?:debited|charged|deducted)|\bis due\b|\bdue (?:on|by)\b|ignore if (?:already )?paid|payment request|\bmandate\b"#)
    static let completed = Rx(#"processed successfully|已还款|还款成功|成功还款|已入账|已到账|已收到|已扣款|已于|扣款成功|has been (?:credited|debited|received)|was (?:charged|debited|credited)|received your payment"#)
    static let marketing = Rx(#"退订|(?:get|earn|enjoy)\b.{0,24}cashback|download now|t&c apply|回T\b|回TD|回复TD|拒收请回|unsubscribe|优惠|活动|抽奖|立减|领取|特惠|福利|专享|邀请|免费|promo|offer|最高可(?:借|贷|享|领)|额度高达|申请|办理|分期|诚邀|恭喜"#)
    /// 信用额度调整，以及支出限额、免密上限这类设置：写的金额是上限，不是交易
    static let limitChange = Rx(#"(?:临时|固定|信用|可用)?额度.{0,10}(?:调整|提升|提高|恢复|降低|调低|调为|生效|到期)|credit limit (?:increase|change|adjust)|限额|上限"#)
    /// 像银行发来的内容（银行名录里没有、也没有【签名】的银行也能认出来）
    static let bankish = Rx(#"银行|\bbank(?:ing)?\b|信用卡|借记卡|储蓄卡|扣账卡|credit card|debit card|card ending"#)
    static let failed = Rx(#"失败|未成功|不成功|未能成功|被拒|拒绝交易|交易拒绝|余额不足|declined|\bfailed\b|unsuccessful|not successful|could not be (?:completed|processed)|returned unpaid|dishonou?red|bounced|abgelehnt|rechazad|recusad|отклонен|reddedildi|مرفوضة|فشل"#)
    /// 短信开头或结尾的【署名】；一条短信可能有两个（「【共享流量使用提醒】…【中国移动】」）
    static let signature = Rx(#"^【([^【】\n]{2,24})】|【([^【】\n]{2,24})】[\s。.]*$"#)
    /// 算银行的署名。`BankDirectory` 只有常见银行的全称，众安、恒生、地方银行和「建行」这样的简称也要算：
    /// 署名不算银行的通知会被直接丢弃，所以这里宁可多算
    static let bankSignature = Rx(#"银行|信用卡|储蓄卡|借记卡|扣账卡|农商|农信|信用社|商行|邮储|浦发|工银|[工农中建交招]行|广发|兴业|民生|光大|中信|华夏|平安|\bbank\b"#)

    // MARK: 金额角色（金额前面最近的标签决定这个数字是什么）

    enum Role: Int {
        case transaction
        case balance
        case creditLimit
        case fee
        case cumulative
        case due
        case points
    }

    static let roleLabels: [(Role, Rx)] = [
        (.balance, Rx(#"可用余额|账户余额|活期余额|余额|结余|\bbalance\b|\ba?va?i?l\.? ?bal|avail(?:able)? bal|\bbaln?\b|\bavbl\b|\bavlb?\b|\bavailable\b|доступно|\bremaining\b|kontostand|saldo|bakiye|остаток|رصيد|الرصيد|مانده|المتبقي|คงเหลือ"#)),
        (.creditLimit, Rx(#"可用额度|信用额度|剩余额度|临时额度|额度|限额|上限|available credit|credit limit|available limit|\blimit\b|\blmt\b|verfügbarer rahmen"#)),
        (.fee, Rx(#"手续费|服务费|工本费|年费|管理费|短信费|\bfees?\b|\bcost\b|\bcharges\b|service charge|\bvat\b|\bgst\b|commission|gebühr|comisi[oó]n|komisyon|رسوم"#)),
        (.cumulative, Rx(#"累计|合计|总计|共计|本月消费|当月消费|\btotal\b"#)),
        (.due, Rx(#"最低还款|应还款?额?|本期账单金额|账单金额|minimum payment|amount due|statement balance|\boutstanding\b|total due|minimum due"#)),
        (.points, Rx(#"积分|\bpoints\b|里程|优惠|立减|减免"#)),
        (.transaction, Rx(#"消费|支付|支出|收入|转入|转出|汇入|汇出|存入|取出|取款|取现|入账|到账|扣款|支取|扣费|扣收|扣除|划扣|还款|退款|退货|冲正|撤销|结息|利息|扣息|工资|代发|金额|交易|付款|收款|充值|提现|预授权|冻结|解冻|\bamt\b|برداشت|واریز|مبلغ|خرید|شراء|ถอน|โอน|compra|\bpago\b|retiro|debited|credited|charged|spent|paid|received|refund(?:ed)?|withdrawn|withdrawal|deposited?|purchase|payment|amount|transaction|transfer(?:red)?|abgebucht|gutgeschrieben|belastet"#)),
    ]

    /// 金额后面紧跟余额标签：「has a $500.00 bal」
    static let balanceAfterAmount = Rx(#"^[ \t]*(?:bal\b|balance\b|avl\b|available\b)"#)
    static let includedFee = Rx(#"含\s*(?:手续费|费用|服务费)|including (?:a )?fee|incl\.? fee"#)
    /// 数字后面紧跟这些字，说明它不是金额（笔数、期数、天数、百分比……）
    static let nonAmountSuffix = Rx(#"^\s*(?:笔|次|期|天|日|个月|月|年|%|％|分钟|小时|岁|位|张|号|人|件|points?\b|x\b)"#)

    // MARK: 交易性质（离金额最近的关键词优先）

    struct KindRule: Sendable {
        let rx: Rx
        let kind: TransactionKind
        let direction: FlowDirection?
        let status: SettlementStatus
        /// 只有「转账 / 汇款」，没说转入还是转出
        let transferGeneric: Bool

        init(_ pattern: String, _ kind: TransactionKind, _ direction: FlowDirection?, status: SettlementStatus = .posted, transferGeneric: Bool = false) {
            rx = Rx(pattern)
            self.kind = kind
            self.direction = direction
            self.status = status
            self.transferGeneric = transferGeneric
        }
    }

    static let kindRules: [KindRule] = [
        KindRule(#"预授权完成"#, .purchase, .outflow),
        KindRule(#"预授权撤销|撤销预授权|预授权取消|authori[sz]ation (?:released|reversed|cancell?ed)"#, .purchase, .inflow, status: .holdReleased),
        KindRule(#"解冻|解除冻结|unfrozen|released hold"#, .other, .inflow, status: .holdReleased),
        // 「预授权冻结」的「冻结」和这条在同一处结束，排在前面的这条优先
        KindRule(#"预授权(?:冻结)?|pre-?authori[sz]ation|authori[sz]ation hold|vormerkung"#, .purchase, .outflow, status: .hold),
        KindRule(#"冻结|暂扣|预扣|on hold|frozen"#, .other, .outflow, status: .hold),
        KindRule(#"冲正|撤销|冲销|撤单|reversal|reversed|cancell?ed your (?:purchase|transaction|payment)|storniert|storno"#, .reversal, nil),
        KindRule(#"退款|退货|退回|退税|返还|refund(?:ed)?|erstattung|rückerstattung|reembolso|devoluci[oó]n|estorno|возврат|\biade\b|استرجاع"#, .refund, .inflow),
        KindRule(#"还款|repayment|payment received|payment thank you|received your payment|your payment of\b|towards your .{0,30}card\b|for your .{0,30}credit card\b"#, .repayment, nil),
        KindRule(#"扣息|利息扣收|扣收利息|贷款利息|透支利息|interest charged?|sollzinsen"#, .interestCharge, .outflow),
        KindRule(#"结息|利息入账|利息收入|付息|存款利息|interest (?:paid|credited|earned)|\binterest\b|zinsgutschrift|利息"#, .interestIncome, .inflow),
        KindRule(#"手续费|年费|管理费|服务费|短信费|扣费|\bfees?\b|gebühr"#, .fee, .outflow),
        KindRule(#"工资|薪资|薪金|代发|奖金|salary|payroll|gehalt|lohn"#, .salary, .inflow),
        // 「手机银行支取」「网上支付支取」是转走或付款，不是取现金
        KindRule(#"取款|取现|提现|\bATM\b|\bcash[- ]?out\b|(?<!手机银行|网上银行|网银|网上支付|快捷支付)支取|cash withdrawal|withdrawal|withdrawn|abhebung|bargeld"#, .withdrawal, .outflow),
        KindRule(#"存款|现金存入|存入现金|cash deposit|deposited (?:via|at|by|through) (?:atm|cash)|\bcash[- ]?in\b|einzahlung"#, .deposit, .inflow),
        KindRule(#"向您(?:尾号\s*[*xX•]*\d{3,4})?的?(?:账户|账号|卡)?(?:完成)?(?:转账|转存|汇款)|转入|汇入|收款|来账|转账收入|转账存入|received from|transfer from|incoming transfer|überweisung von"#, .transferIn, .inflow),
        KindRule(#"(?:you made|your)\s+(?:an?\s+)?[\w-]*\s*transfer(?: of)?|credited to (?:the )?beneficiary|(?<!you )(?<!account )(?<!card )has received|转出|汇出|转账支出|[你您]已成功转账|成功转账至|已转账至|转账至|向[^，,。；;\n]{1,20}(?:转账|汇款)|付款给|transfer(?:red)? to|your transfer is successful|\bsent\b(?! by)|outgoing transfer|überweisung an"#, .transferOut, .outflow),
        KindRule(#"转账|汇款|\btransfer\b|überweisung"#, .transferOut, nil, transferGeneric: true),
        KindRule(#"消费|刷卡|网上支付|快捷支付|网银支付|支付|购物|扣款|划扣|purchase|spent|charged|was used|made (?:with|on|using) your|done at\b|bill payment|(?:imps|neft|rtgs) payment|card transaction|transaction at\b|card payment|payment (?:at|to)|paid (?:to|at)\b|\bPOS\b|kartenzahlung|einkauf"#, .purchase, .outflow),
    ]

    static let inflowCue = Rx(#"存(?:RMB|人民币|CNY)\s*$|收入|入账|到账|存入|收到|退回|返还|credited|\bcredit\b(?! card)|\breceived?\b|deposited|eingang|gutgeschrieben|gutschrift|abono|dep[oó]sito|recibido|recebido|recebeu|re[cç]u\b|зачисл|пополнен|поступ|yatırıl|masuk|diterima|إيداع|ايداع|واریز|รับเงิน|เงินเข้า|โอนเงินเข้า|umepokea"#)
    static let outflowCue = Rx(#"取(?:RMB|人民币|CNY)\s*$|\bfrom:\s*.{0,30}(?:card|account|a/c)|支出|支取|扣除|扣减|扣款|扣收|\bpaid\b|\bspent\b|withdrawn|deducted|\bsent\b(?! by)|debited|\bspending\b|\bcargo\b|\bretiro\b|\bpago\b|\bcompra\b|\bconsumo\b|\bsaque\b|pagamento|\bachat\b|paiement|retrait|покупка|списан|оплата|снятие|harcama|ödeme|çekim|pembayaran|penarikan|شراء|خصم|سحب|برداشت|خرید|ถอน|ชำระ|จ่าย|โอนเงินออก|malipo|umetuma|kwenda|\bdebit\b(?! card)|abgebucht|belastet|belastung"#)
    /// 借贷记号：`NGN4,200.00 DR`、`Dr. Rs. 75.50`。必须是这个大小写，「Dr Smith」「CR7」这类不算
    static let debitMark = Rx(#"(?<![A-Za-z])(?:DR\b|Dr\b\.?(?!\s+(?!Rs\b)[A-Z][a-z]))"#, caseInsensitive: false)
    static let creditMark = Rx(#"(?<![A-Za-z])(?:CR\b|Cr\b\.?(?!\s+(?!Rs\b)[A-Z][a-z]))"#, caseInsensitive: false)
    /// 写在金额后面的结果：这笔消费被撤回了
    static let reversedAfter = Rx(#"reversed|credited back|refunded"#)
    /// 钱是从自己账户出去的：「X has received Rs 100 from your A/c」写的是对方收到了
    static let fromYourAccount = Rx(#"^\D{0,12}\bfrom your\b"#)
    /// 明确说钱进来了：比「网上支付」这种渠道词更能决定方向。不含「入账」，信用卡的「消费入账」是支出
    static let explicitInflow = Rx(#"收入|存入|到账"#)
    /// 汇款说明后面写的结果：决定方向，后面的「到账」说的是收款人那边
    static let sentOut = Rx(#"已(?:汇出|转出)"#)
    /// 括号里的时间说明（「（交易预授权时间10月30日10:20）」）：说的是之前那一步，不决定这笔的性质和状态
    static let timeNote = Rx(#"\([^()]*时间[^()]*\)"#)
    /// 紧跟在这些字后面的时间是之前那笔预授权的时间
    static let holdTimeLabel = Rx(#"预授权时间\s*:?\s*$"#)
    /// 两个金额之间只隔着括号（和币种、「实际扣款」这样的几个字）：括号里是同一笔的另一币种金额
    static let bracketedAmountGap = Rx(#"^[^\d()，,。；;]{0,6}\([^\d()，,。；;]{0,8}$"#)
    static let bracketedAmountEnd = Rx(#"^[^\d()，,。；;]{0,3}\)"#)
    /// 两个金额之间的话以「冻结」结束：「金额10.00美元，已冻结10.00美元」说的是同一笔钱
    static let holdRestatement = Rx(#"冻结[^\d，,。；;]{0,6}$"#)

    static let summaryField = Rx(#"(?:摘要|用途|附言|交易类型|业务类型|备注|description)\s*[：:]\s*([^，,。；;\n]{1,30})"#)
}
