import SwiftUI
import BKModel

/// 转帐的另一边：钱到了哪个币种、到账多少（编辑转入的一笔时是从哪个币种、转出多少）。
/// 到账可以和转出不一样：有手续费，或者换汇（同一个账户的两个币种之间也可以转）。差额只体现在余额上，不算支出。
/// 币种相同时空着就是一样多；币种不同必须填，空着时提示按汇率大概多少。
struct TransferSideFields: View {
    /// 另一边的账户
    let account: Account
    /// 这一边的账户、金额和币种
    let sourceAccountID: String?
    let sourceAmount: Int64?
    let sourceCurrency: CurrencyCode?
    let time: Date
    /// true：这一边转出，这里填到账；false：这一边转入，这里填转出
    var receiving = true
    @Binding var currency: CurrencyCode?
    @Binding var amountText: String

    @Environment(LedgerStore.self) private var store
    @State private var estimate: Int64?

    /// 写在分组下面的说明
    static let note = "到账比转出少的部分（手续费、汇损）只体现在余额上，不算支出。"

    private var sameAccount: Bool { account.id == sourceAccountID }

    /// 同一个账户不能转到同一个币种；这一笔原来的币种不在账户里时也留着
    private var options: [CurrencyCode] {
        var list = account.currencies
        if let currency, !list.contains(currency) { list.append(currency) }
        return sameAccount ? list.filter { $0 != sourceCurrency } : list
    }

    var body: some View {
        if options.count > 1 {
            Picker(receiving ? "到账币种" : "转出币种", selection: $currency) {
                ForEach(options, id: \.self) { Text($0.chineseName).tag(CurrencyCode?.some($0)) }
            }
        } else {
            LabeledContent(receiving ? "到账币种" : "转出币种", value: currency?.chineseName ?? "")
        }
        HStack {
            Text(receiving ? "到账金额" : "转出金额")
            TextField(placeholder, text: $amountText)
                .keyboardType(currency?.minorUnitExponent == 0 ? .numberPad : .decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
        }
        .task(id: estimateKey) { await updateEstimate() }
    }

    private var placeholder: String {
        guard let currency else { return "" }
        if currency == sourceCurrency { return sourceAmount.map { Fmt.money($0, currency) } ?? "" }
        return estimate.map { "约 " + Fmt.money($0, currency) } ?? "必填"
    }

    private var estimateKey: String {
        let day = Calendar.current.startOfDay(for: time).timeIntervalSince1970
        return "\(sourceAmount ?? 0)|\(sourceCurrency?.rawValue ?? "")|\(currency?.rawValue ?? "")|\(day)"
    }

    /// 币种不一样时按汇率提示大概多少
    private func updateEstimate() async {
        guard let currency, let sourceCurrency, let sourceAmount, currency != sourceCurrency else {
            estimate = nil
            return
        }
        let charge: RecordCharge? = await store.estimateCharge(amountMinor: sourceAmount, currency: sourceCurrency, to: currency, at: time)
        guard !Task.isCancelled else { return }
        estimate = charge?.amountMinor
    }

    /// 选了另一边的账户后默认的币种：账户有这一边的币种就用它；同一个账户（换汇）用另一个币种
    static func defaultCurrency(in account: Account, sourceAccountID: String?, sourceCurrency: CurrencyCode?) -> CurrencyCode {
        if account.id != sourceAccountID, let sourceCurrency, account.currencies.contains(sourceCurrency) { return sourceCurrency }
        return account.currencies.first { $0 != sourceCurrency } ?? account.currency
    }

    /// 另一边的金额：币种相同时空着就是一样多。返回金额，或者要提示的错误
    static func resolve(
        text: String, currency: CurrencyCode, account: Account, sourceAccountID: String?, sourceAmount: Int64, sourceCurrency: CurrencyCode,
        receiving: Bool = true
    ) -> (minor: Int64?, error: String?) {
        if account.id == sourceAccountID, currency == sourceCurrency { return (nil, "同一个账户要转到另一个币种") }
        let title = receiving ? "到账金额" : "转出金额"
        switch MoneyInput.parse(text, negative: false, currency: currency) {
        case .empty:
            return currency == sourceCurrency ? (sourceAmount, nil) : (nil, "币种不一样，请填\(title)")
        case .valid(let minor) where minor > 0:
            return (minor, nil)
        default:
            return (nil, "\(title)：" + MoneyInput.invalidAmountMessage(currency))
        }
    }
}
