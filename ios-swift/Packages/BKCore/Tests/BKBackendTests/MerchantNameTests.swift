import XCTest
@testable import BKBackend

/// 商户归一化：同一家店的不同写法得到同一个键，不是真商户的是 nil。商户都是虚构的。
final class MerchantNameTests: XCTestCase {
    func testChannelPrefixIsRemoved() {
        XCTAssertEqual(MerchantName.key("财付通-测试外卖"), "测试外卖")
        XCTAssertEqual(MerchantName.key("支付宝-厦门某某"), "厦门某某")
        XCTAssertEqual(MerchantName.key("支付宝-厦门某某…"), "厦门某某", "被截断的省略号不算商户名")
        XCTAssertEqual(MerchantName.key("微信支付-测试便利店"), "测试便利店")
        XCTAssertEqual(MerchantName.key("WEIXIN*test shop Shenzhen CN"), "test shop")
        XCTAssertEqual(MerchantName.key("PAYPAL *TESTSTREAM"), "teststream")
        XCTAssertEqual(MerchantName.key("财付通-测试外卖"), MerchantName.key("支付宝-测试外卖"), "两个渠道付同一家店")
        XCTAssertEqual(MerchantName.key("财付通-微信支付-测试便利店"), "测试便利店", "两层渠道都去掉")
        XCTAssertNil(MerchantName.key("财付通-微信支付"), "两层都是渠道，没有商户")
        XCTAssertNil(MerchantName.key("财付通-微信支付-微信转账"), "转给别人，不是店：转给谁都不能学到一起")
        XCTAssertNil(MerchantName.key("财付通-微信支付-微信红包"))
    }

    func testOnlyChannelIsNotAMerchant() {
        for text in ["财付通", "支付宝", "微信支付", "银联", "云闪付", "ALIPAY", "财付通-", "支付宝（中国）网络技术有限公司", "财付通支付科技有限公司"] {
            XCTAssertNil(MerchantName.key(text), text)
        }
    }

    func testCollectionCodesAndMaskedAccountsAreNotMerchants() {
        for text in [
            "ALP*QRCode0055", "ALP*QRCode0123", "Scan QR code", "SCAN QR CODE", "TESTPAY*A1B2C3D4E5 Test City CA",
            #"TESTPAY*A1B2C3D4E5\1234 Test Road\Test"#, "100*0001", "u**@example .com", "138****0011", "12345 beijing CN", "A1B2C3D4", "12345",
        ] {
            XCTAssertNil(MerchantName.key(text), text)
        }
        XCTAssertNil(MerchantName.key(nil))
        XCTAssertNil(MerchantName.key(""))
        XCTAssertNil(MerchantName.key("某"), "一个字看不出是谁")
    }

    func testAddressCityAndPostcodeAreRemoved() {
        XCTAssertEqual(MerchantName.key("EXAMPLE.COM/JP TOKYO JPN"), "example.com/jp")
        XCTAssertEqual(MerchantName.key(#"EXAMPLE.COM/JP\TEST BUILDING\TOKYO\100-00"#), "example.com/jp", "冻结和完成扣款写法不同，是同一家")
        XCTAssertEqual(MerchantName.key("TEST-MERCHANT LIFESTY TAIPEI TWN"), "test-merchant lifesty")
        XCTAssertEqual(MerchantName.key(#"TEST-MERCHANT LIFESTY\5F.,No.100,Test R"#), "test-merchant lifesty")
        XCTAssertEqual(MerchantName.key("TEST SHOP MAKATI PH"), "test shop")
        XCTAssertEqual(MerchantName.key("TEST SHOP SHANGHAI 200000 CN"), "test shop")
        XCTAssertEqual(MerchantName.key("TEST SHOP SHANGHAI CN 200000"), "test shop", "邮编在国家后面也一样")
        XCTAssertEqual(MerchantName.key("TEST CAFE HONG KONG HK"), "test cafe")
        XCTAssertEqual(MerchantName.key("EXAMPLE*SERVICE TOKYO JP"), "example*service", "星号后面是名字：整个算商户")
    }

    func testNameIsKeptWhenThereIsNoCountry() {
        XCTAssertEqual(MerchantName.key("EXAMPLE PAY HONG KONG L"), "example pay hong kong l", "被截断了，看不出哪里是地名")
        XCTAssertEqual(MerchantName.key("TESTMART"), "testmart")
        XCTAssertEqual(MerchantName.key("TESTMART CN"), "testmart", "只剩一个词时不当成城市")
    }

    func testWidthCaseAndBranchAreIgnored() {
        XCTAssertEqual(MerchantName.key("Test Shop"), MerchantName.key("TEST  SHOP"))
        XCTAssertEqual(MerchantName.key("ＴＥＳＴ　ＳＨＯＰ"), "test shop")
        XCTAssertEqual(MerchantName.key("測試銀行咖啡"), "测试银行咖啡", "繁体和简体是同一家")
        XCTAssertEqual(MerchantName.key("测试咖啡（人民路店）"), "测试咖啡")
        XCTAssertEqual(MerchantName.key("测试咖啡(人民路店)"), "测试咖啡")
    }

    func testPeopleAndCompaniesAreKept() {
        XCTAssertEqual(MerchantName.key("张三"), "张三")
        XCTAssertEqual(MerchantName.key("某某支付科技有限公司备付金"), "某某支付科技有限公司备付金")
    }
}
