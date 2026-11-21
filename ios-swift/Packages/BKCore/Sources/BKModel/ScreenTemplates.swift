import Foundation

/// 截图模板：用户在 App 里打开一张认不出的截图，点出哪段是金额、卡号、对方做成的（ADR 0028）。
/// 只保存在这台 iPhone，不保存截图，也不保存截图上的数字。
///
/// 保存的是「页面上固定的字」（`anchors`：没点到、不含数字的字，用来认出同一种页面）
/// 和「每样东西挨着哪段固定的字」（`fields`：例如「付款方式」同一行右边、「转入成功」下面第一个金额）。
/// 不存位置坐标：手机屏幕大小、广告长短不一样，挨着固定的字找才稳。
///
/// 另存一份版面骨架（`layout`），只给编辑页用：每段字和位置，数字换成示例。认截图不看它
public struct ScreenTemplate: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    /// 页面上固定的字（整理过的写法：去掉两头的符号和中间的空白，不分大小写）
    public var anchors: [String]
    public var fields: [ScreenTemplateField]
    public var kind: TransactionKind
    public var direction: FlowDirection
    /// 记到这个账户。nil 时按截图上的卡号找卡；不是 nil 时截图上的卡号是转帐的另一边
    public var accountID: String?
    public var createdAt: Date
    /// 编辑页画的版面骨架。这个字段加上之前做的模板没有，不能编辑
    public var layout: ScreenTemplateLayout?

    public init(
        id: String, name: String, anchors: [String], fields: [ScreenTemplateField], kind: TransactionKind, direction: FlowDirection,
        accountID: String?, createdAt: Date, layout: ScreenTemplateLayout? = nil
    ) {
        self.id = id
        self.name = name
        self.anchors = anchors
        self.fields = fields
        self.kind = kind
        self.direction = direction
        self.accountID = accountID
        self.createdAt = createdAt
        self.layout = layout
    }

    /// 给用户看的：页面上前几段固定的字
    public var preview: String { anchors.prefix(4).joined(separator: " · ") }

    public func field(_ role: ScreenTemplateField.Role) -> ScreenTemplateField? {
        fields.first { $0.role == role }
    }
}

/// 截图上的一样东西挨着哪段固定的字
public struct ScreenTemplateField: Hashable, Sendable, Codable {
    public enum Role: String, Hashable, Sendable, Codable, CaseIterable {
        case amount
        case cardTail
        case counterparty
    }

    public enum Place: String, Hashable, Sendable, Codable {
        /// 同一行右边（「付款方式  招商银行储蓄卡(1234)」）
        case right
        /// 下面第一个像它的（「转入成功」下面的金额）
        case below
        /// 上面第一个像它的
        case above
    }

    public var role: Role
    public var anchor: String
    public var place: Place

    public init(role: Role, anchor: String, place: Place) {
        self.role = role
        self.anchor = anchor
        self.place = place
    }
}

/// 截图模板的版面骨架：做模板那张截图上识别出的每段字和位置，不存截图。
/// 点到的金额、卡号、对方换成示例（100.00、1234、「对方」），其他数字都换成 0。
/// 打开模板编辑时照着它画出页面，点到的那几段按模板的找法找回来
public struct ScreenTemplateLayout: Hashable, Sendable, Codable {
    /// 截图的宽 / 高
    public var aspect: Double
    public var lines: [ScreenTextLine]

    public init(aspect: Double, lines: [ScreenTextLine]) {
        self.aspect = aspect
        self.lines = lines
    }
}
