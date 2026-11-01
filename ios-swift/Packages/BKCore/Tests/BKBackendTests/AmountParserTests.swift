import XCTest
@testable import BKBackend
import BKModel

final class AmountParserTests: XCTestCase {
    private func minor(_ text: String, _ exponent: Int = 2) -> Int64? {
        if case let .success(value) = AmountParser.minorUnits(text, exponent: exponent) { return value }
        return nil
    }

    private func failure(_ text: String, _ exponent: Int = 2) -> AmountParser.Failure? {
        if case let .failure(f) = AmountParser.minorUnits(text, exponent: exponent) { return f }
        return nil
    }

    func testCommonFormats() {
        XCTAssertEqual(minor("38"), 3800)
        XCTAssertEqual(minor("38.00"), 3800)
        XCTAssertEqual(minor("38.5"), 3850)
        XCTAssertEqual(minor("1,234.56"), 123_456)
        XCTAssertEqual(minor("1.234,56"), 123_456)
        XCTAssertEqual(minor("12,50"), 1250)
        XCTAssertEqual(minor("1'234.50"), 123_450)
        XCTAssertEqual(minor("1,234,567.89"), 123_456_789)
        XCTAssertEqual(minor("0.01"), 1)
        XCTAssertEqual(minor("0"), 0)
    }

    func testThreeDigitGroupIsThousandsForTwoDecimalCurrencies() {
        XCTAssertEqual(minor("1,234"), 123_400)
        XCTAssertEqual(minor("1.234"), 123_400)
    }

    func testZeroDecimalCurrency() {
        XCTAssertEqual(minor("1,500", 0), 1500)
        XCTAssertEqual(minor("1.500", 0), 1500)
        XCTAssertEqual(failure("1.5", 0), .ambiguous)
    }

    func testZerosBeyondCurrencyDecimalsAreIgnored() {
        XCTAssertEqual(minor("1000.00", 0), 1000, "银行常把日元写成 JPY1000.00")
        XCTAssertEqual(minor("1,000.00", 0), 1000)
        XCTAssertEqual(minor("0.00", 0), 0)
        XCTAssertEqual(failure("1000.50", 0), .ambiguous, "非 0 的小数不能丢")
    }

    func testThreeDecimalCurrencyIsAmbiguous() {
        XCTAssertEqual(failure("1.234", 3), .ambiguous)
        XCTAssertEqual(minor("1.5", 3), 1500)
    }

    func testInvalid() {
        XCTAssertEqual(failure("abc"), .invalid)
        XCTAssertEqual(failure("1,23,4"), .invalid)
        XCTAssertEqual(failure("0.123"), .ambiguous)
        XCTAssertEqual(failure("99999999999999999999"), .overflow)
    }

    func testFormatting() {
        XCTAssertEqual(MoneyFormat.plain(123_456, exponent: 2), "1,234.56")
        XCTAssertEqual(MoneyFormat.plain(5, exponent: 2), "0.05")
        XCTAssertEqual(MoneyFormat.plain(-123_456, exponent: 2), "-1,234.56")
        XCTAssertEqual(MoneyFormat.plain(1500, exponent: 0), "1,500")
        XCTAssertEqual(MoneyFormat.string(Money(minorUnits: -100, currency: .eur)), "-€1.00")
        XCTAssertEqual(MoneyFormat.signed(3800, currency: .cny, direction: .outflow), "-¥38.00")
    }

    func testSHA256KnownVector() {
        XCTAssertEqual(SHA256.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
