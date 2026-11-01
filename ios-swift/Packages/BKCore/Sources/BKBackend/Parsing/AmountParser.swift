import Foundation
import BKModel

/// 金额文本 → 最小货币单位整数。只用整数运算。
public enum AmountParser {
    public enum Failure: Error, Equatable, Sendable {
        /// 分隔符含义不确定（例如 KWD 的 `1.234`），或小数位多于币种允许的位数
        case ambiguous
        case invalid
        case overflow
    }

    /// - Parameters:
    ///   - digits: 例如 `1,234.56`、`1.234,56`、`1'234.50`、`38`、`12,5`
    ///   - exponent: 币种的小数位数
    public static func minorUnits(_ digits: String, exponent: Int) -> Result<Int64, Failure> {
        let text = digits.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789.,'").contains($0) }) else {
            return .failure(.invalid)
        }
        guard let firstDigit = text.first, firstDigit.isNumber else { return .failure(.invalid) }
        let commas = text.filter { $0 == "," }.count
        let dots = text.filter { $0 == "." }.count
        let apostrophes = text.filter { $0 == "'" }.count

        var integerPart = ""
        var fractionPart = ""

        func groupsValid(_ groups: [Substring]) -> Bool {
            guard let head = groups.first, (1...3).contains(head.count) else { return false }
            let rest = groups.dropFirst()
            if rest.allSatisfy({ $0.count == 3 }) { return true }
            // 印度写法 13,30,614.75：最后一组三位，前面两位一组
            return rest.last?.count == 3 && rest.dropLast().allSatisfy { $0.count == 2 }
        }

        if apostrophes > 0 {
            // 瑞士写法 1'234.50
            guard commas == 0, dots <= 1 else { return .failure(.invalid) }
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            let groups = parts[0].split(separator: "'", omittingEmptySubsequences: false)
            guard groupsValid(groups) else { return .failure(.invalid) }
            integerPart = groups.joined()
            fractionPart = parts.count > 1 ? String(parts[1]) : ""
        } else if commas > 0, dots > 0 {
            // 两种分隔符都有：最后出现的是小数点
            let lastComma = text.lastIndex(of: ",")!
            let lastDot = text.lastIndex(of: ".")!
            let decimal: Character = lastComma > lastDot ? "," : "."
            let grouping: Character = decimal == "," ? "." : ","
            guard text.filter({ $0 == decimal }).count == 1 else { return .failure(.invalid) }
            let parts = text.split(separator: decimal, omittingEmptySubsequences: false)
            let groups = parts[0].split(separator: grouping, omittingEmptySubsequences: false)
            guard groupsValid(groups) else { return .failure(.invalid) }
            integerPart = groups.joined()
            fractionPart = String(parts[1])
        } else if commas + dots > 0 {
            let separator: Character = commas > 0 ? "," : "."
            let count = commas + dots
            let parts = text.split(separator: separator, omittingEmptySubsequences: false)
            if count > 1 {
                guard groupsValid(parts) else { return .failure(.invalid) }
                integerPart = parts.joined()
            } else {
                let head = String(parts[0])
                let tail = String(parts[1])
                guard !head.isEmpty, !tail.isEmpty else { return .failure(.invalid) }
                if tail.count == 3, exponent != 3, head.count <= 3, head != "0" {
                    // 三位一组：对小数位不是 3 的币种只能是千位分隔
                    integerPart = head + tail
                } else if tail.count == 3, exponent == 3, head.count <= 3, head != "0" {
                    // KWD 等三位小数币种：1.234 既可能是 1.234 也可能是 1234
                    return .failure(.ambiguous)
                } else if tail.count <= exponent || tail.dropFirst(exponent).allSatisfy({ $0 == "0" }) {
                    integerPart = head
                    fractionPart = tail
                } else {
                    return .failure(.ambiguous)
                }
            }
        } else {
            integerPart = text
        }

        // 「JPY1000.00」：超出币种小数位的部分全是 0，不影响金额
        while fractionPart.count > exponent, fractionPart.hasSuffix("0") { fractionPart.removeLast() }
        guard fractionPart.count <= exponent else { return .failure(.ambiguous) }
        while fractionPart.count < exponent { fractionPart += "0" }
        let combined = (integerPart + fractionPart).drop { $0 == "0" }
        if combined.isEmpty { return .success(0) }
        guard combined.count <= 18, let value = Int64(combined) else { return .failure(.overflow) }
        return .success(value)
    }
}
