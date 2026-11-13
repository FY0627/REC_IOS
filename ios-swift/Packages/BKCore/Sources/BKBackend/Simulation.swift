import Foundation
import BKModel
import BKDatabase

/// 模拟消费的场景：点一下，App 假装收到一条这样的银行短信
public enum SimulatedSpend: String, CaseIterable, Identifiable, Sendable {
    case breakfast, lunch, coffee, taxi, dinner, store, noMerchant

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .breakfast: "早餐"
        case .lunch: "午餐"
        case .coffee: "咖啡"
        case .taxi: "打车"
        case .dinner: "晚餐"
        case .store: "便利店"
        case .noMerchant: "没写商户"
        }
    }

    /// 短信里写的商户；没写商户的像中行的通知
    public var merchant: String? {
        switch self {
        case .breakfast: "包子铺"
        case .lunch: "美团外卖"
        case .coffee: "瑞幸咖啡"
        case .taxi: "滴滴出行"
        case .dinner: "沙县小吃"
        case .store: "见福便利店"
        case .noMerchant: nil
        }
    }

    /// 显示和写进通知的商户。真实账本前面带「模拟·」；演示账本（ADR 0025）里和演示数据的店同名、按演示的语言写：
    /// 早餐、午餐、咖啡、打车是常去的店（已经学会，自动归类），晚餐是没去过的店，便利店选过两个分类（都要在灵动岛上选）
    public func merchant(in language: DemoLanguage?) -> String? {
        guard let language else { return merchant.map { Simulation.merchantPrefix + $0 } }
        let name: DemoName? = switch self {
        case .breakfast: .bakery
        case .lunch: .noodles
        case .coffee: .coffee
        case .taxi: .ride
        case .dinner: .grill
        case .store: .cornerStore
        case .noMerchant: nil
        }
        return name?.text(language)
    }

    /// 随机金额的范围（元）
    public var yuan: ClosedRange<Int> {
        switch self {
        case .breakfast: 5...15
        case .lunch: 15...40
        case .coffee: 9...30
        case .taxi: 12...50
        case .dinner: 20...80
        case .store: 3...30
        case .noMerchant: 10...100
        }
    }
}

/// 模拟消费（「我的 › 开发与调试」）：体验分类建议用。在一张专门的「模拟卡」（工商银行信用卡尾号 9999）上，
/// 用现在的时间和一个金额编一条银行短信，和真的短信走同一个入账流程（解析、去重、自动归类、记账结果通知）。
///
/// - 商户名前面带「模拟·」：学到的分类只算在模拟的商户上，不影响真的瑞幸、滴滴；
/// - 发件人写「模拟消费」，清除时靠它找到模拟的通知；
/// - 一键清除（`clear`）删掉模拟卡、它的流水、模拟的通知和学到的「模拟·」商户，账本回到模拟之前的样子。
///
/// 演示账本（ADR 0025）里不建模拟卡：记到演示的中行信用卡上，用中行的写法，商户和演示数据里的店同名；
/// 一键清除只删模拟的那几笔，卡和学到的分类留着。
enum Simulation {
    static let sender = "模拟消费"
    static let merchantPrefix = "模拟·"
    static let accountKey = "simulation.account"
    /// 演示账本写的语言（`LedgerBackend.seedDemo`）；真实账本没有
    static let demoLanguageKey = "demo.language"

    static func demoLanguage(_ db: SQLiteConnection) throws -> DemoLanguage? {
        try SettingsDAO.get(db, demoLanguageKey).flatMap(DemoLanguage.init(rawValue:))
    }

    /// 演示账本的模拟消费：「您尾号7315的卡消费人民币23.50元，商户：拾光咖啡。【中国银行】」（中行的通知不写时间）
    static func demoMessage(merchant: String?, amountMinor: Int64, last4: String) -> String {
        let amount = MoneyFormat.plain(amountMinor, exponent: 2, grouping: false)
        let shop = merchant.map { "，商户：\($0)" } ?? ""
        return "您尾号\(last4)的卡消费人民币\(amount)元\(shop)。【中国银行】"
    }
    static let account = AccountDraft(
        name: "模拟卡", bankID: "icbc", bankName: "工商银行", last4: "9999", cardType: .credit, currency: .cny, paletteID: "crimson"
    )

    /// 「您尾号9999的信用卡11月04日12:05消费人民币23.50元，商户：模拟·瑞幸咖啡。【工商银行】」
    static func message(_ spend: SimulatedSpend, amountMinor: Int64, at time: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: time)
        let when = String(format: "%02d月%02d日%02d:%02d", c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0)
        let merchant = spend.merchant.map { "，商户：\(merchantPrefix)\($0)" } ?? ""
        return "您尾号9999的信用卡\(when)消费人民币\(MoneyFormat.plain(amountMinor, exponent: 2, grouping: false))元\(merchant)。【工商银行】"
    }

    /// 模拟卡；删了或者还没建时为 nil
    static func accountID(_ db: SQLiteConnection) throws -> String? {
        guard let id = try SettingsDAO.get(db, accountKey), let account = try AccountDAO.find(db, id: id), !account.deleted else { return nil }
        return id
    }

    /// 模拟出来的流水有几笔
    static func recordCount(_ db: SQLiteConnection) throws -> Int {
        if try demoLanguage(db) != nil {
            return Int(try db.scalarInt("SELECT COUNT(*) FROM records WHERE ingest_id IN (SELECT id FROM ingests WHERE sender = ?)", [sender]))
        }
        guard let id = try accountID(db) else { return 0 }
        return Int(try db.scalarInt("SELECT COUNT(*) FROM records WHERE account_id = ?", [id]))
    }

    /// 一键清除，返回删了几笔流水
    static func clear(_ db: SQLiteConnection) throws -> Int {
        // 演示账本：卡和学到的分类是演示数据里的，只删模拟的流水
        let demo = try demoLanguage(db) != nil
        let account = demo ? "" : try SettingsDAO.get(db, accountKey) ?? ""
        let records = "SELECT id FROM records WHERE account_id = ? OR ingest_id IN (SELECT id FROM ingests WHERE sender = ?)"
        let ingests = "SELECT id FROM ingests WHERE sender = ?"
        let removed = Int(try db.scalarInt("SELECT COUNT(*) FROM (\(records))", [account, sender]))
        try db.run("DELETE FROM record_evidence WHERE record_id IN (\(records)) OR ingest_id IN (\(ingests))", [account, sender, sender])
        try db.run("DELETE FROM balance_observations WHERE account_id = ? OR ingest_id IN (\(ingests))", [account, sender])
        try db.run("DELETE FROM pending_items WHERE ingest_id IN (\(ingests))", [sender])
        try db.run("UPDATE records SET related_record_id = NULL WHERE related_record_id IN (\(records))", [account, sender])
        try db.run("DELETE FROM records WHERE id IN (\(records))", [account, sender])
        try db.run("DELETE FROM ingests WHERE sender = ?", [sender])
        try db.run("DELETE FROM opening_balances WHERE account_id = ?", [account])
        try db.run("DELETE FROM accounts WHERE id = ?", [account])
        guard !demo else { return removed }
        try db.run("DELETE FROM merchant_categories WHERE merchant LIKE ?", ["%|" + merchantPrefix + "%"])
        try db.run("DELETE FROM settings WHERE key = ?", [accountKey])
        return removed
    }
}

extension LedgerBackend {
    /// 模拟一笔消费：没有模拟卡就先建一张，再把编好的短信交给入账流程（和快捷指令收到的一样）
    public func simulateSpend(_ spend: SimulatedSpend, amountMinor: Int64) async throws -> IngestResult {
        let (existing, language) = try await database.read { db in (try Simulation.accountID(db), try Simulation.demoLanguage(db)) }
        if let language, let existing, let card = try await database.read({ try AccountDAO.find($0, id: existing) }) {
            let text = Simulation.demoMessage(merchant: spend.merchant(in: language), amountMinor: amountMinor, last4: card.last4)
            return try await ingest(IngestRequest(text: text, source: .auto, sender: Simulation.sender, receivedAt: clock(), boundAccountID: existing))
        }
        let accountID: String
        if let existing {
            accountID = existing
        } else {
            accountID = try await addAccount(Simulation.account).id
            try await database.write { try SettingsDAO.set($0, Simulation.accountKey, accountID) }
        }
        let now = clock()
        let text = Simulation.message(spend, amountMinor: amountMinor, at: now, calendar: calendar)
        return try await ingest(IngestRequest(text: text, source: .auto, sender: Simulation.sender, receivedAt: now, boundAccountID: accountID))
    }

    /// 模拟出来的流水有几笔（没有模拟卡时是 0）
    public func simulatedRecordCount() async throws -> Int {
        try await database.read { try Simulation.recordCount($0) }
    }

    /// 一键清除模拟的东西，返回删了几笔流水
    public func clearSimulation() async throws -> Int {
        try await database.write { try Simulation.clear($0) }
    }
}
