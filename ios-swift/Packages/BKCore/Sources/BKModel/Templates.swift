import Foundation

/// 用户在本机做的识别模板：从一条收到的通知做出来，只保存在这台 iPhone，不发给任何人。
///
/// 保存的是「写法」而不是原文：用户圈出的金额、尾号、对方换成占位，其他数字（日期、时间、余额、号码）
/// 换成「任意数字」，所以模板里没有原文的任何数字。其余文字原样保留，用来认出同一种通知。
public struct MessageTemplate: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var pieces: [TemplatePiece]
    public var kind: TransactionKind
    public var direction: FlowDirection
    public var createdAt: Date

    public init(id: String, name: String, pieces: [TemplatePiece], kind: TransactionKind, direction: FlowDirection, createdAt: Date) {
        self.id = id
        self.name = name
        self.pieces = pieces
        self.kind = kind
        self.direction = direction
        self.createdAt = createdAt
    }

    /// 给用户看的写法，例如「你已于 # # 将 HKD【金额】转出至"【对方】"」
    public var preview: String { pieces.map(\.preview).joined() }
}

public enum TemplatePiece: Hashable, Sendable, Codable {
    /// 原文文字（不含数字）
    case text(String)
    /// 原文里的其他数字：每条通知都可能不同
    case anyNumber
    case amount
    case cardTail
    case counterparty

    public var preview: String {
        switch self {
        case .text(let text): text
        case .anyNumber: "#"
        case .amount: "【金额】"
        case .cardTail: "【尾号】"
        case .counterparty: "【对方】"
        }
    }
}

extension MessageTemplate {
    /// 编辑页和记账一样只选支出 / 收入 / 转帐：支出可以是退款，转帐再选这张卡是转出还是转入。
    /// 交易性质和方向由这几样推出来；原来的性质（改已有的模板、用通知猜的）还在同一类里就保留，例如手续费、工资、还款
    public static func fields(
        type: EntryType, refund: Bool, transferDirection: FlowDirection, keeping kind: TransactionKind?
    ) -> (kind: TransactionKind, direction: FlowDirection) {
        func keep(_ allowed: Set<TransactionKind>, or fallback: TransactionKind) -> TransactionKind {
            if let kind, allowed.contains(kind) { return kind }
            return fallback
        }
        switch type {
        case .expense where refund:
            return (keep([.refund, .reversal], or: .refund), .inflow)
        case .expense:
            return (keep([.purchase, .fee, .interestCharge], or: .purchase), .outflow)
        case .income:
            return (keep([.income, .salary, .interestIncome], or: .income), .inflow)
        case .transfer:
            switch (kind, transferDirection) {
            case (.repayment?, _), (.deposit?, .inflow), (.withdrawal?, .outflow):
                return (kind!, transferDirection)
            default:
                return (transferDirection == .outflow ? .transferOut : .transferIn, transferDirection)
            }
        }
    }

    /// 反过来：这个性质和方向在编辑页上是哪一类（转出、转入也算转帐）
    public static func entry(kind: TransactionKind, direction: FlowDirection) -> (type: EntryType, refund: Bool) {
        switch kind {
        case .transferIn, .transferOut, .repayment, .deposit, .withdrawal: (.transfer, false)
        case .refund where direction == .inflow, .reversal where direction == .inflow: (.expense, true)
        default: direction == .outflow ? (.expense, false) : (.income, false)
        }
    }
}
