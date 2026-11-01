import Foundation

/// NSRegularExpression 的薄封装。NSRegularExpression 的匹配是线程安全的，因此可以作为静态常量共享。
struct Rx: @unchecked Sendable {
    let re: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = true) {
        var options: NSRegularExpression.Options = [.useUnicodeWordBoundaries]
        if caseInsensitive { options.insert(.caseInsensitive) }
        do {
            re = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid regex \(pattern): \(error)")
        }
    }

    func matches(_ text: NSString, in range: NSRange? = nil) -> [NSTextCheckingResult] {
        re.matches(in: text as String, options: [], range: range ?? NSRange(location: 0, length: text.length))
    }

    func first(_ text: NSString, in range: NSRange? = nil) -> NSTextCheckingResult? {
        re.firstMatch(in: text as String, options: [], range: range ?? NSRange(location: 0, length: text.length))
    }

    func test(_ text: String) -> Bool {
        let ns = NSString(string: text)
        return first(ns) != nil
    }

    func replace(_ text: String, with template: String) -> String {
        let ns = NSString(string: text)
        return re.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }
}

extension NSTextCheckingResult {
    func group(_ index: Int, in text: NSString) -> String? {
        guard index < numberOfRanges else { return nil }
        let r = range(at: index)
        guard r.location != NSNotFound, r.length > 0 else { return nil }
        return text.substring(with: r)
    }
}
