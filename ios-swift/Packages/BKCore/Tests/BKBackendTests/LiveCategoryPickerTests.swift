import Foundation
import XCTest
import BKModel

/// 灵动岛上选分类的三页（ADR 0024）：推荐和「全部」、全部大类（一屏 12 格，放不下时最后一格是「更多」）、小类和「只记大类」，左上角返回。
final class LiveCategoryPickerTests: XCTestCase {
    typealias Option = LiveCategoryPicker.Option
    typealias Group = LiveCategoryPicker.Group

    let food = Group(
        option: Option(id: "ex.food", name: "饮食", symbol: "fork.knife"),
        children: ["早餐", "午餐", "晚餐"].enumerated().map { Option(id: "ex.food.\($0.offset)", name: $0.element, symbol: "sun.max") }
    )

    func plain(_ names: [String]) -> [Group] {
        names.map { Group(option: Option(id: "ex.\($0)", name: $0, symbol: "tag"), children: []) }
    }

    func titles(_ screen: LiveCategoryPicker.Screen) -> [String] { screen.cells.map(\.title) }

    // MARK: 第 1 页

    func testQuickPageHasFiveSuggestionsAndAll() {
        let others = plain(["衣着", "居住", "交通", "日用品", "医疗"])
        let quick = [food.children[1]] + others.map(\.option)
        let picker = LiveCategoryPicker(quick: quick.map { .init(option: $0, opens: false) }, groups: [food] + others)
        let screen = picker.screen(.quick)
        XCTAssertEqual(titles(screen), ["午餐", "衣着", "居住", "交通", "日用品", "全部"], "最多 5 个推荐，最后是「全部」")
        XCTAssertNil(screen.back)
        XCTAssertNil(screen.title, "第 1 页顶上是商户、账户、金额")
        XCTAssertEqual(screen.cells[0].action, .pick("ex.food.1"), "推荐可以是小类，点了就记")
        XCTAssertEqual(screen.cells.last?.action, .show(.parents(chunk: 0)))
    }

    func testFillerParentOpensItsChildrenAndReturnsToQuick() {
        let picker = LiveCategoryPicker(quick: [.init(option: food.option, opens: true)], groups: [food])
        let open = picker.screen(.quick).cells[0]
        XCTAssertEqual(open.action, .show(.children(parentID: "ex.food", chunk: 0, fromQuick: true)), "补位的大类点了进小类")
        let children = picker.screen(.children(parentID: "ex.food", chunk: 0, fromQuick: true))
        XCTAssertEqual(titles(children), ["早餐", "午餐", "晚餐", "只记饮食"])
        XCTAssertEqual(children.cells.last?.action, .pick("ex.food"), "只记大类也是记到一个分类")
        XCTAssertEqual(children.title, "饮食")
        XCTAssertEqual(children.back, .quick, "从推荐点进来的，返回回到第 1 页")
    }

    func testLearnedParentIsPickedDirectly() {
        let picker = LiveCategoryPicker(quick: [.init(option: food.option, opens: false)], groups: [food])
        XCTAssertEqual(picker.screen(.quick).cells[0].action, .pick("ex.food"), "自己选过的大类本身：点了直接记")
    }

    // MARK: 第 2 页

    func testParentsFitOneScreenUpToTwelve() {
        let picker = LiveCategoryPicker(quick: [], groups: [food] + plain((1...11).map { "类\($0)" }))
        let screen = picker.screen(.parents(chunk: 0))
        XCTAssertEqual(screen.cells.count, 12, "12 个正好一屏，没有「更多」")
        XCTAssertEqual(screen.cells[0].action, .show(.children(parentID: "ex.food", chunk: 0, fromQuick: false)))
        XCTAssertEqual(screen.cells[1].action, .pick("ex.类1"), "没有小类的大类点了就记")
        XCTAssertEqual(screen.back, .quick)
        XCTAssertEqual(screen.title, "支出")
    }

    func testMoreThanTwelveParentsEndWithMore() {
        let groups = plain((1...14).map { "类\($0)" }) + [food]
        let picker = LiveCategoryPicker(quick: [], groups: groups)
        let first = picker.screen(.parents(chunk: 0))
        XCTAssertEqual(first.cells.count, 12)
        XCTAssertEqual(first.cells.prefix(11).map(\.title), (1...11).map { "类\($0)" })
        XCTAssertEqual(first.cells[11].title, "更多")
        XCTAssertEqual(first.cells[11].symbol, LiveCategoryPicker.moreSymbol)
        XCTAssertEqual(first.cells[11].action, .show(.parents(chunk: 1)))

        let second = picker.screen(.parents(chunk: 1))
        XCTAssertEqual(titles(second), ["类12", "类13", "类14", "饮食"])
        XCTAssertEqual(second.back, .parents(chunk: 0), "返回上一屏")

        // 第二屏的大类点进小类，返回回到第二屏
        let children = picker.screen(.children(parentID: "ex.food", chunk: 0, fromQuick: false))
        XCTAssertEqual(children.back, .parents(chunk: 1))
        XCTAssertEqual(picker.screen(.parents(chunk: 9)).page, .parents(chunk: 1), "超出的屏回到最后一屏")
    }

    func testTwentyFiveParentsTakeThreeScreens() {
        let picker = LiveCategoryPicker(quick: [], groups: plain((1...25).map { "类\($0)" }))
        XCTAssertEqual(picker.screen(.parents(chunk: 1)).cells.prefix(11).map(\.title), (12...22).map { "类\($0)" })
        XCTAssertEqual(picker.screen(.parents(chunk: 1)).cells.last?.action, .show(.parents(chunk: 2)))
        XCTAssertEqual(titles(picker.screen(.parents(chunk: 2))), ["类23", "类24", "类25"])
    }

    func testManyChildrenAlsoPage() {
        let big = Group(option: Option(id: "ex.big", name: "大", symbol: "tag"), children: (1...13).map { Option(id: "ex.big.\($0)", name: "小\($0)", symbol: "tag") })
        let picker = LiveCategoryPicker(quick: [], groups: [big])
        let first = picker.screen(.children(parentID: "ex.big", chunk: 0, fromQuick: false))
        XCTAssertEqual(first.cells.count, 12)
        XCTAssertEqual(first.cells.last?.action, .show(.children(parentID: "ex.big", chunk: 1, fromQuick: false)))
        let second = picker.screen(.children(parentID: "ex.big", chunk: 1, fromQuick: false))
        XCTAssertEqual(titles(second), ["小12", "小13", "只记大"])
        XCTAssertEqual(second.back, .children(parentID: "ex.big", chunk: 0, fromQuick: false))
    }

    func testUnknownParentFallsBackToAllParents() {
        let picker = LiveCategoryPicker(quick: [], groups: [food])
        XCTAssertEqual(picker.screen(.children(parentID: "已删除", chunk: 0, fromQuick: false)).page, .parents(chunk: 0))
    }

    // MARK: 从候选算

    /// 大类、小类换回分类页的顺序；补位凑上的带小类的大类点了进小类，选过的直接记
    func testBuiltFromSuggestionsInCategoryOrder() {
        func category(_ id: String, _ order: Int, parent: String? = nil) -> LedgerCategory {
            LedgerCategory(id: id, type: .expense, parentID: parent, name: id, symbol: "tag", sortOrder: order)
        }
        let food = category("food", 0), lunch = category("lunch", 1, parent: "food"), dinner = category("dinner", 2, parent: "food")
        let clothes = category("clothes", 1), home = category("home", 2)
        let suggestions = CategorySuggestions(
            groups: [CategoryGroup(parent: home, children: []), CategoryGroup(parent: food, children: [dinner, lunch]), CategoryGroup(parent: clothes, children: [])],
            quick: [dinner, home, food], learnedIDs: ["dinner", "home"]
        )
        let picker = LiveCategoryPicker(suggestions, labels: .init(type: "支出"))
        XCTAssertEqual(picker.groups.map(\.option.id), ["food", "clothes", "home"], "固定是分类页的顺序，不按常用排")
        XCTAssertEqual(picker.groups[0].children.map(\.id), ["lunch", "dinner"])
        XCTAssertEqual(picker.quick.map(\.opens), [false, false, true])
        XCTAssertEqual(picker.option("lunch")?.name, "lunch")
    }

    // MARK: 写进实时活动

    func testPageTokenRoundTrips() {
        let pages: [LiveCategoryPicker.Page] = [
            .quick, .parents(chunk: 0), .parents(chunk: 3),
            .children(parentID: "ex.food", chunk: 0, fromQuick: true),
            .children(parentID: "A1B2-有.点", chunk: 2, fromQuick: false),
        ]
        for page in pages { XCTAssertEqual(LiveCategoryPicker.Page(token: page.token), page, page.token) }
        for bad in ["", "x", "p", "p.a", "c.0.x.id", "c.0.q.", "q.1"] { XCTAssertNil(LiveCategoryPicker.Page(token: bad), bad) }

        typealias Action = LiveCategoryPicker.Cell.Action
        let actions: [Action] = [.pick("ex.food.1"), .show(.quick), .show(.children(parentID: "ex.food", chunk: 1, fromQuick: true))]
        for action in actions { XCTAssertEqual(Action(token: action.token), action, action.token) }
        for bad in ["", "k.", "s.", "s.x", "pick"] { XCTAssertNil(Action(token: bad), bad) }
    }

    /// 实时活动的内容要小于 4KB：最坏的一屏（12 格、名字长、id 是 UUID）也留出商户、账户、金额的地方
    func testWorstScreenIsSmall() throws {
        let long = String(repeating: "很长的分类名称", count: 3)
        let groups = (0..<30).map { _ in
            Group(option: Option(id: UUID().uuidString, name: long, symbol: "takeoutbag.and.cup.and.straw"),
                  children: (0..<20).map { _ in Option(id: UUID().uuidString, name: long, symbol: "figure.and.child.holdinghands") })
        }
        let picker = LiveCategoryPicker(quick: groups.prefix(5).map { .init(option: $0.option, opens: true) }, groups: groups)
        let screens = [picker.screen(.quick), picker.screen(.parents(chunk: 1)), picker.screen(.children(parentID: groups[13].option.id, chunk: 1, fromQuick: false))]
        for screen in screens {
            let size = try JSONEncoder().encode(screen).count
            XCTAssertLessThan(size, 2_500, "\(screen.page)：\(size) 字节")
            XCTAssertEqual(try JSONDecoder().decode(LiveCategoryPicker.Screen.self, from: JSONEncoder().encode(screen)), screen)
        }
    }

    func testLocalizedNamesAndLabels() {
        let names = ["饮食": "Food", "早餐": "Breakfast", "午餐": "Lunch", "晚餐": "Dinner"]
        let picker = LiveCategoryPicker(quick: [.init(option: food.option, opens: true)], groups: [food] + plain((1...12).map { "类\($0)" }))
            .localized(name: { names[$0] ?? $0 }, labels: .init(all: "All", more: "More", only: "Just %@", type: "Expense"))
        let decoded = try! XCTUnwrap(LiveCategoryPicker(json: picker.json))
        XCTAssertEqual(titles(decoded.screen(.quick)), ["Food", "All"])
        XCTAssertEqual(decoded.screen(.parents(chunk: 0)).cells.last?.title, "More")
        XCTAssertEqual(decoded.screen(.parents(chunk: 0)).title, "Expense")
        XCTAssertEqual(titles(decoded.screen(.children(parentID: "ex.food", chunk: 0, fromQuick: true))), ["Breakfast", "Lunch", "Dinner", "Just Food"])
        XCTAssertNil(LiveCategoryPicker(json: "不是 JSON"))
    }

    // MARK: 有没有灵动岛

    func testDynamicIslandByModel() {
        for model in ["iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone16,1", "iPhone17,1", "iPhone17,3", "iPhone18,1", "iPhone18,4", "iPhone19,1"] {
            XCTAssertTrue(DynamicIsland.isPresent(model: model), model)
        }
        // 13、14、SE 3、16e、17e 是刘海或 Home 键；iPad、模拟器没给机型时不算
        for model in ["iPhone14,5", "iPhone14,6", "iPhone14,7", "iPhone14,8", "iPhone17,5", "iPhone18,5", "iPhone12,8", "iPad16,3", "arm64", "x86_64", "iPhone", "iPhoneX,1"] {
            XCTAssertFalse(DynamicIsland.isPresent(model: model), model)
        }
    }
}
