import AppIntents
import Foundation
import BKModel

/// 快捷指令里可选择的银行卡账户。只暴露名称、银行和后四位。
struct AccountEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "银行卡账户"
    static let defaultQuery = AccountEntityQuery()

    let id: String
    let title: String
    let subtitle: String

    init(account: Account) {
        id = account.id
        title = "\(account.bankName) ·\(account.last4)"
        subtitle = "\(account.name) · \(account.cardType.displayName) · \(account.currencies.map(\.rawValue).joined(separator: "/"))"
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)", image: .init(systemName: "creditcard"))
    }
}

struct AccountEntityQuery: EntityQuery {
    init() {}

    func entities(for identifiers: [String]) async throws -> [AccountEntity] {
        let accounts = try await AppServices.shared.backend().accounts(includeArchived: true)
        return accounts.filter { identifiers.contains($0.id) }.map(AccountEntity.init)
    }

    /// 只列银行卡：现金、电子钱包没有通知，不参与自动记账
    func suggestedEntities() async throws -> [AccountEntity] {
        try await AppServices.shared.backend().accounts().filter(\.isCard).map(AccountEntity.init)
    }
}
