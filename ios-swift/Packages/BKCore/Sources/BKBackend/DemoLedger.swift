import Foundation
import BKModel
import BKDatabase

/// 演示账本的语言（ADR 0025）：商户、备注、人名按它写。分类、银行、现金和钱包的名字账本里存的是简体，App 显示时自己换
public enum DemoLanguage: String, CaseIterable, Sendable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case english = "en"
}

/// 写好的演示账本里有多少东西
public struct DemoSummary: Hashable, Sendable {
    public var accounts: Int
    public var records: Int
    public var pending: Int
}

extension LedgerBackend {
    /// 在空的演示账本里写一份用了三个月的样子（ADR 0025）：流水排到现在（`clock()`）为止。
    ///
    /// 通知照真实的写法编（招行动账提醒和快捷支付短信、中行「商户：」、恒生「無卡支付」、招行 Apple Pay 预授权和完成扣款，
    /// 微信、支付宝账单截图），和真的一样走入账流程：解析、认账户、合并冻结、外币扣款、学分类。
    /// 商户、卡号尾号、人名、金额都是编的。常去的店连续选同一个分类，后来就自动归类；有的店改过主意，只排在推荐前面
    public func seedDemo(language: DemoLanguage) async throws -> DemoSummary {
        let plan = DemoPlan(language: language, end: clock(), calendar: calendar)
        let demoClock = DemoClock(plan.openedAt)
        let writer = LedgerBackend(database: database, calendar: calendar, clock: { demoClock.now }, newID: newID)

        let opened = plan.openedAt
        try await database.write { db in try DemoPlan.insertCategories(db, language: language, at: opened) }
        var ids: [DemoAccount: String] = [:]
        for account in DemoAccount.allCases {
            ids[account] = try await writer.addAccount(account.draft).id
        }
        for rates in plan.rates() {
            try await writer.saveExchangeRates(rates)
        }

        for event in plan.events() {
            demoClock.now = event.time.addingTimeInterval(45)
            let result: IngestResult
            switch event.kind {
            case .notice(let text):
                result = try await writer.ingest(IngestRequest(text: text, source: .auto, receivedAt: event.time.addingTimeInterval(20)))
            case .screenshot(let text):
                result = try await writer.ingestScreenshot(text: text, capturedAt: event.time.addingTimeInterval(90))
            case .entry(let entry):
                guard let account = ids[entry.account] else { continue }
                try await writer.addRecord(ManualEntry(
                    type: entry.type, accountID: account, toAccountID: entry.to.flatMap { ids[$0] }, amountMinor: entry.amountMinor,
                    currency: entry.currency, toAmountMinor: entry.toAmountMinor, toCurrency: entry.toCurrency,
                    categoryID: event.category, counterparty: entry.counterparty, note: event.note ?? "", time: event.time
                ))
                continue
            }
            guard let category = event.category else { continue }
            for item in result.items where item.result == .recorded {
                guard let recordID = item.recordID else { continue }
                try await writer.file(recordID, category: category, note: event.note)
            }
        }

        let card = ids[.boc]
        let lastManual = ids[.cash]
        try await database.write { db in
            // 学分类是一笔一笔学的，App 启动时不要再回放一遍；待处理已经是现在的读法
            try SettingsDAO.set(db, LedgerBackend.learningSeededKey, "1")
            try SettingsDAO.set(db, LedgerBackend.pendingRereadKey, String(MessageParser.version))
            try SettingsDAO.set(db, Simulation.demoLanguageKey, language.rawValue)
            if let card { try SettingsDAO.set(db, Simulation.accountKey, card) }
            if let lastManual { try SettingsDAO.set(db, LedgerBackend.lastManualAccountKey, lastManual) }
        }
        return DemoSummary(
            accounts: ids.count, records: try await recordCount(), pending: try await pendingCount()
        )
    }

    /// 演示账本的语言；真实账本是 nil
    public func demoLanguage() async throws -> DemoLanguage? {
        try await database.read { try Simulation.demoLanguage($0) }
    }

    /// 入账后选分类，和用户在通知上点的一样（会学）。已经自动归到这个分类的不动，只补备注
    private func file(_ recordID: String, category: String, note: String?) async throws {
        let current = try await database.read { try RecordDAO.find($0, id: recordID)?.categoryID }
        if current == category {
            if let note { try await updateNote(recordID: recordID, note: note) }
        } else {
            try await setCategory(recordID: recordID, categoryID: category, note: note)
        }
    }
}

// MARK: 账户

/// 演示账本里的账户：三张卡（一张多币种）、现金、两个电子钱包。尾号是编的
enum DemoAccount: CaseIterable {
    case cmb, hangSeng, boc, wechat, alipay, cash

    var draft: AccountDraft {
        switch self {
        case .cmb:
            AccountDraft(
                name: "", bankID: "cmb", bankName: "招商银行", last4: DemoPlan.cmbTail, cardType: .debit, currency: .cny,
                paletteID: "graphite-gold", openingBalanceMinor: 1_248_000
            )
        case .hangSeng:
            AccountDraft(
                name: "", bankID: "hangseng", bankName: "恒生银行", last4: DemoPlan.hangSengTail, cardType: .debit, currency: .hkd,
                paletteID: "forest", openingBalanceMinor: 862_000, extraCurrencies: [.cny, .usd],
                extraOpeningBalances: [.cny: 350_000, .usd: 41_236]
            )
        case .boc:
            AccountDraft(
                name: "", bankID: "boc", bankName: "中国银行", last4: DemoPlan.bocTail, cardType: .credit, currency: .cny,
                paletteID: "crimson", openingBalanceMinor: -298_630
            )
        case .wechat:
            .pocket(name: "微信支付", type: .wallet, currency: .cny, paletteID: "jade", openingBalanceMinor: 23_650, walletID: "wechatpay")
        case .alipay:
            .pocket(name: "支付宝", type: .wallet, currency: .cny, paletteID: "ocean", openingBalanceMinor: 86_000, walletID: "alipay")
        case .cash:
            .pocket(name: "现金", type: .cash, currency: .cny, paletteID: "sunset", openingBalanceMinor: 68_000)
        }
    }
}

// MARK: 名字

/// 编的商户、人名和备注，按语言写
enum DemoName: CaseIterable {
    case bakery, coffee, noodles, kitchen, bistro, dumplings, brunch, hotpot, grill, cornerStore, market, metro, ride, rail
    case clothes, books, cinema, pharmacy, gas, gym, onlineShop
    case landlord, friendA, friendB, friendC
    case splitNote, giftNote

    func text(_ language: DemoLanguage) -> String {
        let (hans, hant, english) = names
        return switch language {
        case .zhHans: hans
        case .zhHant: hant
        case .english: english
        }
    }

    private var names: (String, String, String) {
        switch self {
        case .bakery: ("麦香早点", "麥香早點", "Morning Crumb Bakery")
        case .coffee: ("拾光咖啡", "拾光咖啡", "Lumen Coffee")
        case .noodles: ("老街牛肉面", "老街牛肉麵", "Old Street Noodles")
        case .kitchen: ("青禾简餐", "青禾簡餐", "Green Grain Kitchen")
        case .bistro: ("炉边小馆", "爐邊小館", "Hearth Bistro")
        case .dumplings: ("小巷饺子馆", "小巷餃子館", "Dumpling House")
        case .brunch: ("晨光早午餐", "晨光早午餐", "Sunny Side Brunch")
        case .hotpot: ("川味小火锅", "川味小火鍋", "Red Pepper Hotpot")
        case .grill: ("巷口烧烤", "巷口燒烤", "Alley Grill")
        case .cornerStore: ("邻里便利店", "鄰里便利商店", "Corner Mart")
        case .market: ("鲜丰超市", "鮮豐超市", "FreshFields Market")
        case .metro: ("城市地铁", "城市捷運", "City Metro")
        case .ride: ("快行出行", "快行叫車", "SwiftRide")
        case .rail: ("城际铁路", "城際鐵路", "Intercity Rail")
        case .clothes: ("布衣良品", "布衣良品", "Thread and Loom")
        case .books: ("页间书店", "頁間書店", "Margins Bookshop")
        case .cinema: ("星河影城", "星河影城", "Starlight Cinema")
        case .pharmacy: ("康安大药房", "康安藥局", "Wellside Pharmacy")
        case .gas: ("城市燃气", "城市瓦斯", "City Gas")
        case .gym: ("跃动健身", "躍動健身", "Pulse Fitness")
        case .onlineShop: ("云集商城", "雲集商城", "Cloudmart")
        case .landlord: ("周先生", "周先生", "Mr. Zhou")
        case .friendA: ("林晓", "林曉", "Alex Lin")
        case .friendB: ("陈思", "陳思", "Sam Chen")
        case .friendC: ("王一帆", "王一帆", "Evan Wang")
        case .splitNote: ("和朋友 AA", "和朋友分帳", "Split with friends")
        case .giftNote: ("给妈妈的生日礼物", "給媽媽的生日禮物", "Birthday gift for Mom")
        }
    }
}

// MARK: 分类

/// 演示用的分类：默认分类的标识，加上三个自己加的（长期用的人多半会加几个）
enum DemoCategory {
    static let breakfast = "ex.food.breakfast"
    static let lunch = "ex.food.lunch"
    static let dinner = "ex.food.dinner"
    static let snack = "ex.food.snack"
    static let clothes = "ex.clothes.wear"
    static let rent = "ex.home.rent"
    static let utility = "ex.home.utility"
    static let phone = "ex.home.phone"
    static let transit = "ex.traffic.transit"
    static let taxi = "ex.traffic.taxi"
    static let trip = "ex.traffic.trip"
    static let book = "ex.study.book"
    static let media = "ex.fun.media"
    static let sport = "ex.fun.sport"
    static let daily = "ex.daily"
    static let medical = "ex.medical"
    static let present = "ex.gift.present"
    static let salary = "in.salary"
    static let interest = "in.interest"
    static let gift = "in.gift"
    /// 自己加的：饮食下面的「买菜」、大类「订阅」、收入「返现」
    static let groceries = "demo.groceries"
    static let subscriptions = "demo.subscriptions"
    static let cashback = "demo.cashback"
}

// MARK: 时间

/// 写演示数据时的「现在」：每一笔按它发生的时间入账，处理时间、学分类的时间都对得上
final class DemoClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ date: Date) { value = date }

    var now: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

/// 固定种子的随机数：同一个「现在」生成的账本每次一样（测试靠它）
struct DemoRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }

    mutating func chance(_ percent: Int) -> Bool { int(1...100) <= percent }

    /// 一个价格（分）：整元的多，也有 .5、.8 这样的尾数
    mutating func price(_ yuan: ClosedRange<Int>) -> Int64 {
        let whole = Int64(int(yuan)) * 100
        switch int(1...10) {
        case 1...5: return whole
        case 6...8: return whole + Int64([50, 80, 90][int(0...2)])
        default: return whole + Int64(int(1...99))
        }
    }
}

// MARK: 计划

/// 一笔演示流水：什么时候、怎么来的（通知、截图、手动）、入账后选哪个分类
struct DemoEvent {
    enum Kind {
        /// 银行、钱包的通知（快捷指令交来的，来源是「自动化」）
        case notice(String)
        /// 微信、支付宝账单截图上的文字
        case screenshot(String)
        /// 手动记的一笔
        case entry(DemoEntry)
    }

    var time: Date
    var kind: Kind
    /// 入账后选的分类；nil 不选（转帐、待处理、通知写明的工资）
    var category: String?
    var note: String?
}

struct DemoEntry {
    var type: EntryType
    var account: DemoAccount
    var amountMinor: Int64
    var currency: CurrencyCode = .cny
    var counterparty: String?
    var to: DemoAccount?
    var toAmountMinor: Int64?
    var toCurrency: CurrencyCode?
}

/// 三个月的流水怎么排：工作日早餐、午饭、咖啡、下班后买菜或吃饭；周末逛街、看电影、和朋友吃火锅；
/// 每月房租、工资、话费、燃气、订阅、还信用卡、给钱包充钱。最后几天留三条待处理
struct DemoPlan {
    static let days = 90
    static let cmbTail = "2046"
    static let hangSengTail = "0618"
    static let bocTail = "7315"
    static let applePayDevice = "4417"
    /// 没添加到 App 的卡（待处理）
    static let otherTail = "5521"
    static let hangSengPhone = "28228228"

    let language: DemoLanguage
    let end: Date
    let calendar: Calendar
    /// 第一天的零点
    let start: Date
    /// 添加账户（初始余额）的时间：第一笔之前
    let openedAt: Date

    init(language: DemoLanguage, end: Date, calendar: Calendar) {
        self.language = language
        self.end = end
        self.calendar = calendar
        let today = calendar.startOfDay(for: end)
        start = calendar.date(byAdding: .day, value: -(Self.days - 1), to: today) ?? today
        openedAt = start.addingTimeInterval(-3600)
    }

    func name(_ name: DemoName) -> String { name.text(language) }

    // MARK: 汇率

    /// 每天一份汇率（以美元为基准），每天有一点点波动
    func rates() -> [ExchangeRates] {
        var list: [ExchangeRates] = []
        for index in 0..<Self.days {
            guard let day = calendar.date(byAdding: .day, value: index, to: start) else { continue }
            let updated = day.addingTimeInterval(8 * 3600)
            guard updated <= end else { continue }
            list.append(ExchangeRates(base: .usd, rates: Self.rates(day: index), updatedAt: updated, fetchedAt: updated.addingTimeInterval(300)))
        }
        return list
    }

    static let baseRates: [String: Double] = [
        "CNY": 7.118, "HKD": 7.771, "JPY": 151.4, "EUR": 0.921, "GBP": 0.786, "TWD": 32.18, "MOP": 8.004,
        "SGD": 1.339, "AUD": 1.532, "CAD": 1.388, "KRW": 1392, "THB": 34.8, "NZD": 1.671, "CHF": 0.861,
    ]

    static func rates(day: Int) -> [String: Double] {
        var rates: [String: Double] = ["USD": 1]
        for (offset, (code, value)) in baseRates.sorted(by: { $0.key < $1.key }).enumerated() {
            let wave = sin(Double(day) * 0.37 + Double(offset)) * 0.004 + sin(Double(day) * 0.11 + Double(offset) * 2) * 0.006
            rates[code] = (value * (1 + wave) * 10_000).rounded() / 10_000
        }
        return rates
    }

    // MARK: 流水

    func events() -> [DemoEvent] {
        var random = DemoRandom(seed: 20_261_113)
        var events: [DemoEvent] = []
        var sequence = 0
        var storeTurn = 0
        var shopTurn = 0
        var marketTurn = 0
        var redPackets = 0
        for index in 0..<Self.days {
            guard let day = calendar.date(byAdding: .day, value: index, to: start) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let date = calendar.component(.day, from: day)
            let weekend = weekday == 1 || weekday == 7
            func at(_ hour: Int, _ minutes: ClosedRange<Int> = 0...59) -> Date {
                day.addingTimeInterval(TimeInterval(hour * 3600 + random.int(minutes) * 60 + random.int(0...59)))
            }
            func add(_ time: Date, _ kind: DemoEvent.Kind, _ category: String?, note: String? = nil) {
                events.append(DemoEvent(time: time, kind: kind, category: category, note: note))
            }
            func nextSequence() -> Int {
                sequence += 1
                return sequence
            }

            // 每个月固定的
            if date == 1 {
                add(at(10, 0...20), .entry(DemoEntry(
                    type: .expense, account: .cmb, amountMinor: 420_000, counterparty: name(.landlord)
                )), DemoCategory.rent)
            }
            if date == 2 {
                add(at(19), .notice(boc(name(.gym), 19_900)), DemoCategory.sport)
            }
            if date == 3 || date == 17 {
                add(at(9, 0...30), .entry(DemoEntry(type: .transfer, account: .cmb, amountMinor: 80_000, to: .wechat)), nil)
            }
            if date == 5 {
                let t = at(9, 5...20)
                add(t, .notice(cmbPush(t, inflow: false, amount: 5_800)), DemoCategory.phone)
            }
            if date == 8 {
                let t = at(3, 0...40)
                add(t, .notice(hangSeng(t, merchant: "NOTELY PRO Dublin IE", currency: .usd, amount: 499)), DemoCategory.subscriptions)
            }
            if date == 10 {
                let t = at(9, 28...35)
                add(t, .notice(cmbPush(t, inflow: true, amount: 1_860_000)), DemoCategory.salary)
            }
            if date == 12 {
                let amount: Int64 = [328_640, 295_810, 342_270][index % 3]
                add(at(20, 5...40), .entry(DemoEntry(type: .transfer, account: .cmb, amountMinor: amount, to: .boc)), nil)
            }
            if date == 14 {
                add(at(18, 10...40), .entry(DemoEntry(type: .transfer, account: .cmb, amountMinor: 50_000, to: .cash)), nil)
            }
            if date == 15 {
                let t = at(19, 10...50)
                add(t, .screenshot(alipay(t, merchant: name(.gas), amount: [8_640, 9_210, 12_830][index % 3], sequence: nextSequence())), DemoCategory.utility)
            }
            if date == 16 {
                add(at(11), .entry(DemoEntry(type: .income, account: .boc, amountMinor: Int64(random.int(860...2_480)))), DemoCategory.cashback)
            }
            if date == 18 {
                let t = at(2, 0...40)
                add(t, .notice(hangSeng(t, merchant: "LUMINA AI San Francisco US", currency: .usd, amount: 2_000)), DemoCategory.subscriptions)
            }
            if date == 21 {
                let t = at(9, 0...10)
                add(t, .notice(cmbPush(t, inflow: true, amount: Int64(random.int(1_210...1_480)))), DemoCategory.interest)
            }
            if date == 25 {
                add(at(21, 0...30), .entry(DemoEntry(type: .transfer, account: .cmb, amountMinor: 60_000, to: .alipay)), nil)
            }

            if weekend {
                // 周末：早午饭、逛街、电影、和朋友吃火锅，回家打车
                let brunch = at(10, 40...59)
                add(brunch, .screenshot(wechat(brunch, merchant: name(.brunch), amount: random.price(48...118), sequence: nextSequence())), DemoCategory.lunch)
                if weekday == 7 {
                    if random.chance(45) {
                        add(at(15), .notice(boc(name(.clothes), random.price(199...459))), DemoCategory.clothes)
                    }
                    if random.chance(50) {
                        let t = at(16, 0...30)
                        add(t, .screenshot(wechat(t, merchant: name(.cinema), amount: random.price(45...90), sequence: nextSequence())), DemoCategory.media)
                    }
                    let dinner = at(18, 30...59)
                    let split = random.chance(50)
                    let hotpot = random.price(168...288)
                    add(dinner, .notice(boc(name(.hotpot), hotpot)), DemoCategory.dinner, note: split ? name(.splitNote) : nil)
                    let home = at(21, 10...50)
                    add(home, .screenshot(alipay(home, merchant: name(.ride), amount: random.price(18...46), sequence: nextSequence())), DemoCategory.taxi)
                    if split, let next = calendar.date(byAdding: .day, value: 1, to: day) {
                        let back = next.addingTimeInterval(TimeInterval(9 * 3600 + random.int(0...120) * 60))
                        let friend = [DemoName.friendA, .friendB, .friendC][random.int(0...2)]
                        add(back, .screenshot(wechatTransferIn(back, from: name(friend), amount: hotpot / 2, sequence: nextSequence())), DemoCategory.gift)
                    }
                } else {
                    let t = at(17, 0...40)
                    marketTurn += 1
                    // 超市多半是买菜，偶尔记成日用品：推荐里两个都有
                    let category = marketTurn % 5 == 0 ? DemoCategory.daily : DemoCategory.groceries
                    add(t, .notice(boc(name(.market), random.price(86...240))), category)
                    if random.chance(30) {
                        add(at(14), .notice(boc(name(.books), random.price(48...118))), DemoCategory.book)
                    }
                    if random.chance(20) {
                        add(at(12, 10...40), .notice(boc(name(.pharmacy), random.price(26...88))), DemoCategory.medical)
                    }
                }
            } else {
                // 工作日：早餐（现金）、地铁、咖啡、午饭（微信）、下班后吃饭或买菜、便利店、晚上网购
                if random.chance(65) {
                    add(at(7, 45...59), .entry(DemoEntry(
                        type: .expense, account: .cash, amountMinor: random.price(6...15), counterparty: name(.bakery)
                    )), DemoCategory.breakfast)
                }
                if random.chance(35) {
                    let t = at(8, 30...55)
                    add(t, .screenshot(alipay(t, merchant: name(.metro), amount: Int64(random.int(3...6)) * 100, sequence: nextSequence())), DemoCategory.transit)
                }
                if random.chance(45) {
                    let t = at(random.chance(60) ? 10 : 15, 0...40)
                    let amount = random.price(16...32)
                    if random.chance(50) {
                        add(t, .screenshot(wechat(t, merchant: name(.coffee), amount: amount, sequence: nextSequence())), DemoCategory.snack)
                    } else {
                        add(t, .notice(boc(name(.coffee), amount)), DemoCategory.snack)
                    }
                }
                if random.chance(85) {
                    let t = at(12, 0...45)
                    let place = random.chance(55) ? DemoName.noodles : .kitchen
                    add(t, .screenshot(wechat(t, merchant: name(place), amount: random.price(22...42), sequence: nextSequence())), DemoCategory.lunch)
                }
                switch random.int(1...100) {
                case 1...35:
                    let place = random.chance(50) ? DemoName.bistro : .dumplings
                    add(at(19, 0...50), .notice(boc(name(place), random.price(42...108))), DemoCategory.dinner)
                case 36...60:
                    let t = at(18, 30...59)
                    marketTurn += 1
                    let category = marketTurn % 5 == 0 ? DemoCategory.daily : DemoCategory.groceries
                    add(t, .notice(boc(name(.market), random.price(38...126))), category)
                default:
                    break
                }
                if random.chance(28) {
                    let t = at(random.int(20...22), 0...59)
                    storeTurn += 1
                    // 便利店买的东西不一样：饮料零食、日用品轮着选，不自动归类，推荐里两个在前
                    let category = storeTurn % 2 == 0 ? DemoCategory.daily : DemoCategory.snack
                    add(t, .screenshot(alipay(t, merchant: name(.cornerStore), amount: random.price(6...28), sequence: nextSequence())), category)
                }
                if random.chance(15) {
                    let t = at(random.int(21...23), 0...59)
                    shopTurn += 1
                    let category = shopTurn % 3 == 0 ? DemoCategory.clothes : DemoCategory.daily
                    add(t, .notice(hangSeng(t, merchant: "WEIXIN*Cloudmart Shenzhen CN", currency: .cny, amount: random.price(39...259))), category)
                }
                if weekday == 6, random.chance(40) {
                    let t = at(19, 0...30)
                    add(t, .screenshot(wechat(t, merchant: name(.cinema), amount: random.price(45...90), sequence: nextSequence())), DemoCategory.media)
                }
            }
            // 朋友发的红包（零星几个）
            if redPackets < 4, random.chance(6) {
                redPackets += 1
                let t = at(20, 0...59)
                let friend = [DemoName.friendA, .friendB, .friendC][random.int(0...2)]
                add(t, .screenshot(wechatRedPacket(from: name(friend), amount: [666, 888, 1_888, 520][redPackets % 4])), DemoCategory.gift)
            }
        }
        events += specialEvents(sequence: &sequence)
        return events.filter { $0.time < end.addingTimeInterval(-300) }.sorted { $0.time < $1.time }
    }

    /// 只出现一次的：日本网店的预授权和完成扣款（外币）、换美元、坐火车、给妈妈买礼物、最后几天的待处理
    private func specialEvents(sequence: inout Int) -> [DemoEvent] {
        var events: [DemoEvent] = []
        func day(_ daysAgo: Int, _ hour: Int, _ minute: Int) -> Date? {
            let today = calendar.startOfDay(for: end)
            return calendar.date(byAdding: .day, value: -daysAgo, to: today)?.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60 + 17))
        }
        func nextSequence() -> Int {
            sequence += 1
            return sequence
        }

        // 外币：先冻结日元，第二天按人民币完成扣款
        if let hold = day(19, 22, 14), let capture = day(18, 9, 41) {
            let yen: Int64 = 12_800
            let rates = Self.rates(day: Self.days - 1 - 19)
            let cny = Int64((Double(yen) / (rates["JPY"] ?? 151.4) * (rates["CNY"] ?? 7.118) * 100).rounded())
            events.append(DemoEvent(time: hold, kind: .notice(cmbHold(hold, yen: yen, cny: cny)), category: nil))
            events.append(DemoEvent(time: capture, kind: .notice(cmbCapture(capture, cny: cny, holdTime: hold)), category: DemoCategory.daily))
        }
        // 同一张卡上换汇：港币换美元，付订阅
        if let time = day(47, 21, 5) {
            events.append(DemoEvent(time: time, kind: .entry(DemoEntry(
                type: .transfer, account: .hangSeng, amountMinor: 80_000, currency: .hkd, to: .hangSeng, toAmountMinor: 10_256, toCurrency: .usd
            )), category: nil))
        }
        if let time = day(33, 15, 22) {
            events.append(DemoEvent(
                time: time, kind: .screenshot(wechat(time, merchant: name(.rail), amount: 15_850, sequence: nextSequence())), category: DemoCategory.trip
            ))
        }
        if let time = day(11, 21, 38) {
            events.append(DemoEvent(time: time, kind: .notice(boc(name(.onlineShop), 32_900)), category: DemoCategory.present, note: name(.giftNote)))
        }
        if let time = day(26, 20, 12) {
            events.append(DemoEvent(
                time: time, kind: .notice(hangSeng(time, merchant: "HARBOUR TICKETS Hong Kong HK", currency: .hkd, amount: 48_000)), category: DemoCategory.media
            ))
        }

        // 待处理：手动记过、银行通知又来了（问是不是同一笔）
        if let manual = day(3, 18, 40), let notice = day(3, 18, 52) {
            events.append(DemoEvent(time: manual, kind: .entry(DemoEntry(
                type: .expense, account: .cmb, amountMinor: 12_860, counterparty: name(.market)
            )), category: DemoCategory.groceries))
            events.append(DemoEvent(time: notice, kind: .notice(cmbQuickPay(notice, channel: "支付宝", merchant: name(.market), amount: 12_860)), category: nil))
        }
        // 待处理：没添加的卡（今天早上的；现在还太早就放到昨晚）
        let morning = day(0, 9, 12).flatMap { $0 < end.addingTimeInterval(-600) ? $0 : nil }
        if let time = morning ?? day(1, 20, 12) {
            events.append(DemoEvent(time: time, kind: .notice(otherBank(time, merchant: name(.onlineShop), amount: 8_600)), category: nil))
        }
        // 待处理：微信付款成功页没写用什么付的
        if let time = day(1, 12, 31) {
            events.append(DemoEvent(time: time, kind: .screenshot("""
            \(clockText(time))
            支付成功
            ¥36.00
            \(name(.noodles))
            完成
            """), category: nil))
        }
        // 待处理：聊天里转给朋友、对方收了（看不出从哪个账户转的）
        if let time = day(2, 20, 46), let received = day(2, 21, 3) {
            events.append(DemoEvent(time: received, kind: .screenshot("""
            \(clockText(received))
            \(name(.friendB))已收款
            ¥200.00
            转账时间  \(wechatTime(time))
            收款时间  \(wechatTime(received))
            账单详情
            """), category: nil))
        }
        return events
    }

    // MARK: 通知的写法（照真实的格式，内容是编的）

    private func components(_ time: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: time)
    }

    private func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }

    private func money(_ minor: Int64) -> String { MoneyFormat.plain(minor, exponent: 2, grouping: false) }

    /// 招行 App 推送：「动账提醒 您尾号2046的储蓄账户11月3日9时30分收入人民币18600.00元。点击查看>>」
    func cmbPush(_ time: Date, inflow: Bool, amount: Int64) -> String {
        let c = components(time)
        let when = "\(c.month ?? 1)月\(c.day ?? 1)日\(c.hour ?? 0)时\(c.minute ?? 0)分"
        return "动账提醒\n您尾号\(Self.cmbTail)的储蓄账户\(when)\(inflow ? "收入" : "支出")人民币\(money(amount))元。点击查看>>"
    }

    /// 招行短信：「【招商银行】您尾号2046的储蓄卡于11月03日12:05在支付宝-鲜丰超市快捷支付人民币32.00元」
    func cmbQuickPay(_ time: Date, channel: String, merchant: String, amount: Int64) -> String {
        let c = components(time)
        return "【招商银行】您尾号\(Self.cmbTail)的储蓄卡于\(two(c.month))月\(two(c.day))日\(two(c.hour)):\(two(c.minute))在\(channel)-\(merchant)快捷支付人民币\(money(amount))元"
    }

    /// 没添加的卡：「【浦发银行】您尾号5521的信用卡11月12日20:12消费人民币86.00元，商户：云集商城。」
    func otherBank(_ time: Date, merchant: String, amount: Int64) -> String {
        let c = components(time)
        return "【浦发银行】您尾号\(Self.otherTail)的信用卡\(two(c.month))月\(two(c.day))日\(two(c.hour)):\(two(c.minute))消费人民币\(money(amount))元，商户：\(merchant)。"
    }

    /// 招行 Apple Pay 预授权冻结（外币）
    func cmbHold(_ time: Date, yen: Int64, cny: Int64) -> String {
        let c = components(time)
        return "【招商银行】您绑定在Apple Pay上的账户\(Self.cmbTail)（设备卡号\(Self.applePayDevice)）于\(two(c.month))月\(two(c.day))日\(two(c.hour)):\(two(c.minute))"
            + "在SAKURA STATIONERY           TOKYO         JPN预授权冻结JPY\(money(yen * 100))（人民币\(money(cny))），请留意后续扣款通知"
    }

    /// 招行 Apple Pay 完成扣款，写明之前那笔预授权的时间
    func cmbCapture(_ time: Date, cny: Int64, holdTime: Date) -> String {
        let c = components(time)
        let h = components(holdTime)
        return "【招商银行】您绑定在Apple Pay上的账户\(Self.cmbTail)（设备卡号\(Self.applePayDevice)）于\(two(c.month))月\(two(c.day))日\(two(c.hour)):\(two(c.minute))"
            + #"在SAKURA STATIONERY\2-8 GINZA\TOKYO\104-00完成扣款人民币"# + money(cny)
            + "（交易预授权时间\(two(h.month))月\(two(h.day))日\(two(h.hour)):\(two(h.minute))）"
    }

    /// 中行信用卡：「您尾号7315的卡消费人民币86.00元，商户：炉边小馆。【中国银行】」（没写时间）
    func boc(_ merchant: String, _ amount: Int64) -> String {
        "您尾号\(Self.bocTail)的卡消费人民币\(money(amount))元，商户：\(merchant)。【中国银行】"
    }

    /// 恒生多币种扣账卡：「你在18/10/2026透過結尾號碼0618的扣賬卡以「無卡支付」交易向… 支付了USD20。」金额不写多余的 0
    func hangSeng(_ time: Date, merchant: String, currency: CurrencyCode, amount: Int64) -> String {
        let c = components(time)
        var digits = money(amount)
        while digits.hasSuffix("0"), digits.contains(".") { digits.removeLast() }
        if digits.hasSuffix(".") { digits.removeLast() }
        let date = "\(two(c.day))/\(two(c.month))/\(c.year ?? 2026)"
        return "【恒生銀行】恒生：你在\(date)透過結尾號碼\(Self.hangSengTail)的扣賬卡以「無卡支付」交易向\(merchant)支付了\(currency.rawValue)\(digits)。如懷疑電\(Self.hangSengPhone)。"
    }

    /// 状态栏的时间（截图第一行）
    private func clockText(_ time: Date) -> String {
        let c = components(time)
        return "\(c.hour ?? 0):\(two(c.minute))"
    }

    private func wechatTime(_ time: Date) -> String {
        let c = components(time)
        return "\(c.year ?? 2026)年\(two(c.month))月\(two(c.day))日 \(two(c.hour)):\(two(c.minute)):\(two(c.second))"
    }

    private func orderNumber(_ prefix: String, _ time: Date, _ sequence: Int, length: Int) -> String {
        let c = components(time)
        let head = prefix + "\(c.year ?? 2026)\(two(c.month))\(two(c.day))"
        let tail = String(sequence)
        return head + String(repeating: "0", count: max(0, length - head.count - tail.count)) + tail
    }

    /// 微信账单详情（零钱付）
    func wechat(_ time: Date, merchant: String, amount: Int64, sequence: Int) -> String {
        let paid = time.addingTimeInterval(-60)
        return """
        \(clockText(time))
        \(merchant)
        -\(money(amount))
        当前状态  支付成功
        支付时间  \(wechatTime(paid))
        收单机构  财付通支付科技有限公司
        支付方式  零钱
        交易单号  \(orderNumber("4200000", paid, sequence, length: 28))
        """
    }

    /// 微信转账详情（收到）
    func wechatTransferIn(_ time: Date, from person: String, amount: Int64, sequence: Int) -> String {
        let sent = time.addingTimeInterval(-600)
        return """
        转账-来自\(person)
        +\(money(amount))
        当前状态  已存入零钱
        转账时间  \(wechatTime(sent))
        收款时间  \(wechatTime(time))
        转账单号  \(orderNumber("1000050", sent, sequence, length: 28))
        """
    }

    /// 聊天里领到的红包
    func wechatRedPacket(from person: String, amount: Int64) -> String {
        """
        \(person)的红包
        \(money(amount))元
        已存入零钱，可直接消费＞
        """
    }

    /// 支付宝账单详情（余额付）
    func alipay(_ time: Date, merchant: String, amount: Int64, sequence: Int) -> String {
        let paid = time.addingTimeInterval(-45)
        let c = components(paid)
        let when = "\(c.year ?? 2026)-\(two(c.month))-\(two(c.day)) \(two(c.hour)):\(two(c.minute)):\(two(c.second))"
        return """
        \(clockText(time))
        \(merchant)
        -\(money(amount))
        交易成功
        支付时间  \(when)
        付款方式  余额
        订单号  \(orderNumber("", paid, sequence, length: 28))
        """
    }

    // MARK: 自己加的分类

    static func insertCategories(_ db: SQLiteConnection, language: DemoLanguage, at time: Date) throws {
        let seeds: [(String, CategoryType, String?, (String, String, String), String)] = [
            (DemoCategory.groceries, .expense, "ex.food", ("买菜", "買菜", "Groceries"), "cart"),
            (DemoCategory.subscriptions, .expense, nil, ("订阅", "訂閱", "Subscriptions"), "laptopcomputer"),
            (DemoCategory.cashback, .income, nil, ("返现", "現金回饋", "Cashback"), "arrow.uturn.backward"),
        ]
        for (id, type, parent, names, symbol) in seeds {
            let name = switch language {
            case .zhHans: names.0
            case .zhHant: names.1
            case .english: names.2
            }
            let category = LedgerCategory(
                id: id, type: type, parentID: parent, name: name, symbol: symbol,
                sortOrder: try CategoryDAO.nextSortOrder(db, type: type, parentID: parent)
            )
            try CategoryDAO.insert(db, category, now: time)
        }
    }
}
