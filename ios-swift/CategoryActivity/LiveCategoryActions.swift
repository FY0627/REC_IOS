import Foundation

/// 扩展里的空壳：岛上按钮的动作是 `LiveActivityIntent`，系统在 App 的进程里运行它们，
/// 真正的写入和换页在 App 的 `LiveCategoryActions`（`Bookkeeping/App/LiveCategoryActivity.swift`）。
/// 扩展只链接 BKModel，不碰账本
enum LiveCategoryActions {
    static func pick(recordID: String, categoryID: String) async {}
    static func show(recordID: String, page: String) async {}
}
