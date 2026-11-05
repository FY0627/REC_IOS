import Foundation
import XCTest
import BKModel

/// 通知上选分类的按钮（ADR 0020）：一页 3 个选项，第 4 个翻页、返回或打开 App。
final class NotificationPickerTests: XCTestCase {
    typealias Option = NotificationPicker.Option

    let food = NotificationPicker.Group(
        option: Option(id: "ex.food", name: "饮食", symbol: "fork.knife"),
        children: ["早餐", "午餐", "晚餐", "饮料零食"].enumerated().map { Option(id: "ex.food.\($0.offset)", name: $0.element, symbol: "sun.max") }
    )
    var others: [NotificationPicker.Group] {
        ["衣着", "居住", "交通", "日用品", "医疗"].map { NotificationPicker.Group(option: Option(id: "ex.\($0)", name: $0, symbol: "tag"), children: []) }
    }

    func titles(_ buttons: [NotificationPicker.Button]) -> [String] { buttons.map(\.title) }

    func testParentsArePagedThreeAtATime() {
        let picker = NotificationPicker(first: food.children[1], groups: [food] + others)
        XCTAssertEqual(titles(picker.parentButtons(page: 0)), ["午餐", "饮食", "衣着", "更多大类"], "这个商户选过的在第一个")
        XCTAssertEqual(titles(picker.parentButtons(page: 1)), ["居住", "交通", "日用品", "更多大类"])
        XCTAssertEqual(titles(picker.parentButtons(page: 2)), ["医疗", "打开 App"], "最后一页可以打开 App")
    }

    func testOpeningParentShowsItsChildrenThenTheParentItself() {
        let picker = NotificationPicker(first: nil, groups: [food] + others)
        let open = NotificationPicker.identifier(picker.parentButtons(page: 0)[0])
        let page0 = try! XCTUnwrap(picker.buttons(after: open))
        XCTAssertEqual(titles(page0), ["早餐", "午餐", "晚餐", "更多"])
        let page1 = try! XCTUnwrap(picker.buttons(after: NotificationPicker.identifier(page0[3])))
        XCTAssertEqual(titles(page1), ["饮料零食", "只记饮食", "返回"])
        let back = try! XCTUnwrap(picker.buttons(after: NotificationPicker.identifier(page1[2])))
        XCTAssertEqual(titles(back), titles(picker.parentButtons(page: 0)))
        XCTAssertEqual(NotificationPicker.identifier(page1[1]), "pick.ex.food", "只记大类也是记到一个分类")
        XCTAssertNil(picker.buttons(after: NotificationPicker.identifier(page0[1])), "点小类交回 App")
    }

    func testTapsCountPagesParentAndChild() {
        let picker = NotificationPicker(first: nil, groups: others + [food])
        XCTAssertEqual(picker.taps(to: "ex.衣着"), 1)
        XCTAssertEqual(picker.taps(to: "ex.医疗"), 2, "第二页：更多大类、点它")
        XCTAssertEqual(picker.taps(to: "ex.food.3"), 2 + 2, "饮食在第二页：更多大类、饮食；饮料零食在小类第二页：更多、饮料零食")
        XCTAssertFalse(picker.onFirstPage("ex.food.1"))
        XCTAssertTrue(picker.onFirstPage("ex.居住"))
        XCTAssertNil(picker.taps(to: "不存在"))
    }

    func testLearnedTopLevelIsNotListedTwice() {
        let picker = NotificationPicker(first: others[0].option, groups: others)
        XCTAssertEqual(titles(picker.parentButtons(page: 0)), ["衣着", "居住", "交通", "更多大类"])
    }

    func testCategoryPoolMatchesTheExtension() {
        XCTAssertEqual(NotificationPicker.categoryIDs.count, 20)
        XCTAssertEqual(Set(NotificationPicker.categoryIDs).count, NotificationPicker.categoryIDs.count)
        XCTAssertEqual(NotificationPicker.categoryIDs.first, "ingest.pick.0", "和 Config/NotificationContent-Info.plist 里写的一样")
    }

    func testTravelsThroughUserInfoAsJSON() {
        let picker = NotificationPicker(first: food.children[0], groups: [food] + others)
        XCTAssertEqual(NotificationPicker(json: picker.json), picker)
        XCTAssertNil(NotificationPicker(json: "不是 JSON"))
    }
}
