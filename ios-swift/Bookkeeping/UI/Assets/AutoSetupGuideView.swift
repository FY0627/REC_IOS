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
/// iOS 不允许 App 创建、导入或查询快捷指令自动化，自动化（触发条件）只能用户自己建。
/// TestFlight / App Store 装的：点一下添加共享的快捷指令「自动记账」。
/// iOS 27 的自带触发条件，只要选银行 App。
/// iOS 26 的不带触发条件，一个自动化只有一个触发，「信息」条件也不能空（用户在 iOS 26 上试过）：
/// 「信息包含」空格、「。」、「，」、「】」各建一个，「电子邮件」主题包含空格、「你」、「您」各建一个，都运行「自动记账」。
/// 自己侧载的（用不了共享链接）列手动步骤，iOS 26、iOS 27 分开写。
/// 添加银行卡后不再弹出这一页：第一次打开时在新手引导里设置（`OnboardingView`）。
struct AutoSetupGuideView: View {
    var body: some View {
        List { AutoSetupSections() }
            .navigationTitle("设置自动记账")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// 「设置自动记账」的内容：「我的」里的设置页和新手引导共用，两边一样
struct AutoSetupSections: View {
    @Environment(\.openURL) private var openURL

    private var useShared: Bool { SharedShortcuts.available }
    private var choosesApps: Bool {
        if #available(iOS 27, *) { return true }
        return false
    }

    var body: some View {
        if useShared {
            Section {
                // 点「添加快捷指令」已经进了快捷指令 App，不再放「打开快捷指令」
                Button("添加快捷指令", systemImage: "plus.square.on.square") { openURL(SharedShortcuts.bankMessage) }
            }
            if choosesApps {
                Section {
                    Text(Self.sharedLine)
                }
            } else {
                steps(Self.shared26Steps)
            }
        } else {
            Section {
                Button("打开快捷指令", systemImage: "arrow.up.forward.app") {
                    if let url = URL(string: "shortcuts://") { openURL(url) }
                }
            } footer: {
                Text("只需设置一次，之后添加的卡不用再设置。")
            }

            steps(choosesApps ? Self.smsSteps : Self.sms26Steps)
        }
    }

    private func steps(_ steps: [LocalizedStringKey]) -> some View {
        Section {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                StepRow(number: index + 1, text: step)
            }
        } header: {
            Text("\(steps.count) 步完成")
        }
    }

    static let sharedLine: LocalizedStringKey = "添加后打开 **自动记账**，在 **App 通知** 里选银行 App；银行 App 记得打开通知。"

    static let shared26Steps: [LocalizedStringKey] = [
        "点 **添加快捷指令**。",
        "在快捷指令底部点 **自动化** → **+** → **信息**，**信息包含** 填一个 **空格**，选 **立即运行** → **下一步** → **自动记账**。",
        "照上一步再建三个，**信息包含** 分别填 **。**、**，**、**】**。",
        "再建三个 **电子邮件** 自动化，**主题包含** 分别填 **空格**、**你**、**您**，其余同第 2 步。",
    ]

    static let sms26Steps: [LocalizedStringKey] = [
        "点 **打开快捷指令** → **自动化** → **+** → **信息**，**信息包含** 填一个 **空格**，选 **立即运行** → **下一步** → **新建空白自动化**。",
        "添加操作 **记录银行动账通知**，**通知内容** 选 **快捷指令输入**，**来源** 选 **自动**，点 **完成**。",
        "照上两步再建三个，**信息包含** 分别填 **。**、**，**、**】**。",
        "再建三个 **电子邮件** 自动化，**主题包含** 分别填 **空格**、**你**、**您**，其余同第 1、2 步。",
    ]

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
