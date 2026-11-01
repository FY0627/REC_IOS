import Foundation
import BKModel

/// 公开汇率数据源（ExchangeRate-API 的免密钥接口，每日更新，覆盖 160 多个币种）。
/// App 不联网：由快捷指令「获取 URL 内容」下载，再交给 App 动作「导入汇率」。
/// 这里只提供地址（「我的」里共享的快捷指令「导入汇率」下载的就是它）和解析。
public enum ExchangeRateFeed {
    public static let url = URL(string: "https://open.er-api.com/v6/latest/USD")!
    /// 数据源要求在使用汇率的界面上注明来源并链接到官网
    public static let attribution = "Rates By Exchange Rate API"
    public static let attributionURL = URL(string: "https://www.exchangerate-api.com")!

    public enum ParseError: Error, Equatable {
        case invalidResponse
        case providerError(String)
    }

    private struct Response: Decodable {
        let result: String
        let base_code: String?
        let time_last_update_unix: Double?
        let rates: [String: Double]?
        let error_type: String?
    }

    public static func parse(_ data: Data, fetchedAt: Date) throws -> ExchangeRates {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw ParseError.invalidResponse }
        guard response.result == "success" else { throw ParseError.providerError(response.error_type ?? response.result) }
        guard let base = response.base_code, let rates = response.rates, !rates.isEmpty else { throw ParseError.invalidResponse }
        let valid = rates.filter { $0.value > 0 && $0.value.isFinite }
        let updatedAt = response.time_last_update_unix.map { Date(timeIntervalSince1970: $0) } ?? fetchedAt
        return ExchangeRates(base: CurrencyCode(base), rates: valid, updatedAt: updatedAt, fetchedAt: fetchedAt)
    }
}
