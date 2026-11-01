import SwiftUI
import UIKit
import BKModel

/// 「设置自动记账」：一个自动化，用「信息」「电子邮件」「App 通知」触发，全部交给 App，只需设置一次。
/// 「信息」条件不填；「电子邮件」快捷指令要求至少一个条件，只能按主题：填「你」。恒生、众安的动账邮件主题都有「你」
/// （「你剛以恒生…」「你已成功轉賬」「你已收到CNY…」「你已转出CNY…」），有的不写银行名；其他邮件交给 App 也不会保存。
/// 来源选「自动」：App 分不出是哪一种时，同一笔交易的短信、邮件、App 通知合并成一笔或进待处理，不会重复记账。
///
/// 不按关键词或尾号筛选：繁体（銀行）、英文银行写法各不相同，「信息包含」又只能填一个词。
/// 由 App 判断是不是动账通知：认出尾号（固定写法，或正文里出现已添加的卡的尾号）才入账；
/// 不是动账通知的短信不保存。
/// iOS 不允许 App 创建、导入或查询快捷指令自动化，这里只给出最少的手动步骤。
/// 只放设置步骤；各卡收到过没有、接收日志在「自动记账状态」（`AutomationStatusView`）。
struct AutoSetupGuideView: View {
    /// 作为添加流程的最后一步出现时，右上角显示「完成」
    var onDone: (() -> Void)?

    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                Button("打开快捷指令", systemImage: "arrow.up.forward.app") {
                    if let url = URL(string: "shortcuts://") { openURL(url) }
                }
            } footer: {
                Text("只需设置一次，之后添加的卡不用再设置。")
            }

            Section {
                ForEach(Array(Self.smsSteps.enumerated()), id: \.offset) { index, step in
                    StepRow(number: index + 1, text: step)
                }
            } header: {
                Text("5 步完成")
            }
        }
        .navigationTitle("设置自动记账")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if let onDone {
                    Button("完成", systemImage: "checkmark", action: onDone)
                }
            }
        }
        // 添加银行卡后紧接着出现时不显示返回（卡已经保存，返回会回到已提交的表单）
        .navigationBarBackButtonHidden(onDone != nil)
    }

    static let smsSteps: [LocalizedStringKey] = [
        "点上面 **打开快捷指令**，在底部选 **自动化**，点右上角 **+**，选 **信息**，条件都不填。",
        "在同一个自动化里再加 **电子邮件** 触发，条件选 **主题** 包含，填 **你**（银行邮件的主题不一定写银行名，但都有「你」；别的邮件 App 不会保存）；再加 **App 通知** 触发，只选银行 App，**不要选「邮件」**：邮件 App 的通知只有开头几行，完整的邮件由「电子邮件」触发交给 App。",
        "选 **立即运行**，添加操作 **记录银行动账通知**。",
        "**通知内容** 选自动化的输入（显示为 **快捷指令输入** 或 **通知**）。",
        "**来源** 选 **自动**，点 **完成**。不是动账通知的内容不会保存。",
    ]
}

struct StepRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.tint, in: Circle())
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            Text(text).font(.body)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct HelpView: View {
    var body: some View {
        List {
            Section("会记录") {
                Text("消费、收入、转账、退款、还款、利息、手续费、存取款、冲正。")
            }
            Section("不会记录") {
                Text("验证码、营销、提醒、账单、额度变化、只有余额的通知。")
            }
            Section("识别不了的") {
                Text("进入「待处理」，由你确认或忽略。也可以把它做成识别模板，以后同样写法的通知按模板记账。")
            }
            Section("数据") {
                Text("只保存在这台 iPhone，App 不联网。汇率由快捷指令下载后导入。")
            }
        }
        .navigationTitle("使用说明")
        .navigationBarTitleDisplayMode(.inline)
    }
}
