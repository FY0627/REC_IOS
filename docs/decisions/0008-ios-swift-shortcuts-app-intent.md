# 0008 iOS Swift 版自动记账：快捷指令短信 / 邮件自动化 + 后台 App Intent

- 状态：已采纳（`ios-swift/`；对 iOS Swift 版取代 [0005](0005-auto-bookkeeping-screenshot-ocr.md) 中的「截图 + OCR」方案）
- 日期：2026-10-24

## 背景

目标是记录银行卡账户实际发生的全部资金变动，并且日常记账时不打断用户：不切换前台 App、不拉起记账 App、
锁屏时不点亮界面。银行动账通知通常以短信或邮件送达。

已核实的平台事实（2026-10，Apple 文档与支持页面）：

- 快捷指令的「信息」自动化可按**发件人**和**信息包含**（正文）筛选；「电子邮件」自动化可按**发件人、主题包含、账户、收件人**筛选，
  **不能按正文筛选**（[Apple 支持：通讯触发器](https://support.apple.com/guide/shortcuts/apdd711f9dff/ios)）。
- 自动化可以设为「立即运行」，此时不需要用户确认；系统可能显示自己的运行通知，可在自动化里关闭。
- 分享或导入的快捷指令**不携带自动化触发器**；App 没有创建、导入或查询个人自动化的 API。
- iOS 26 起 `AppIntent.supportedModes` 用 `IntentModes` 声明前台 / 后台执行方式，`.background` 表示完全在后台执行；
  `openAppWhenRun` 已被它取代（[supportedModes](https://developer.apple.com/documentation/appintents/appintent/supportedmodes)、
  [IntentModes](https://developer.apple.com/documentation/appintents/intentmodes)）。
- App Intent 在 App 自己的进程中执行。

## 备选方案

| 方案 | 结论 |
|---|---|
| 截图 + 系统 OCR（ADR 0005） | 需要用户每次手动触发，且截屏会出现在用户当前界面，不满足「不打断」 |
| 读取短信 / 邮件数据库 | iOS 不允许第三方 App 读取 |
| 通知服务扩展读取其他 App 的推送 | iOS 不允许读取其他 App 的通知 |
| 打开 App 的 URL Scheme / `openAppWhenRun = true` | 会切换前台，违背要求 |
| **快捷指令「信息 / 电子邮件」自动化 → 后台 App Intent** | 采纳 |

## 决定

- 提供一个 App Intent「记录银行动账通知」（`RecordBankMessageIntent`）：
  - `supportedModes = .background`，`authenticationPolicy = .alwaysAllowed`；
  - 不实现 `ProvidesDialog`，不调用 `requestValue` / `requestConfirmation`，所有参数可选，缺失时不追问；
  - 参数：通知内容、来源（短信/邮件/其他）、发件人、主题、接收时间、消息标识、绑定账户（`AccountEntity`）。
    系统没提供的元数据留空，App 不伪造。
- 快捷指令只负责「触发 + 取输入 + 调用动作」；归一化、解析、账户匹配、去重、入账都在 `BKBackend`。
- 用 `AppShortcutsProvider` 让动作安装后即可在快捷指令里搜索到。
- App 内的「设置自动记账」给出最少步骤，提供「复制关键词」「打开快捷指令」，并只展示可观测状态：
  「自动化状态 App 无法读取」「最近一次真实接收时间 / 待验证」。
- **修订（第一次真机测试后）**：改为**一个**「信息」自动化覆盖所有银行卡——筛选条件只填「信息包含：银行」，
  尾号由 App 在正文中匹配到具体的卡。关键词会让少量普通短信也触发自动化，所以解析器新增类别
  「没有金额和尾号（不是动账通知）」：只记在接收日志里，不进待处理。「通知内容」参数设置
  `inputConnectionBehavior: .connectToPreviousIntentResult`，让快捷指令尽量自动填入「快捷指令输入」（由系统决定，步骤里保留确认）。
- **修订（2026-10-26，恒生银行繁体短信测试后）**：改为**一个不加任何条件**的「信息」自动化，所有短信都交给 App。
  「银行」触发不了繁体短信（「銀行」），也覆盖不了英文银行；按尾号触发又要每张卡一个（「信息包含」只能填一个词）。
  用户实测不填条件可以正常触发。是否动账由 App 判断：没有尾号、看不出银行、没有绑定账户的不保存、不写日志。
  新版快捷指令一个自动化可以有多个触发条件（「信息」「电子邮件」「App 通知」用「或」连接），
  动作的「来源」新增「自动」（默认）和「App 通知」；来源为「自动」时，去重把每条输入都当作可能来自另一渠道。
- **修订（2026-10-26，长银行邮件被截断）**：「App 通知」触发只选银行 App，**不选「邮件」App**。
  邮件 App 的通知只带开头几行，长邮件的金额、尾号常被截掉，App 无法补回；完整的邮件由「电子邮件」触发交给 App。
- 「快捷指令中心」（Gallery）由 Apple 编辑，第三方不能上架模板；分享的快捷指令（iCloud 链接 / .shortcut 文件）不带自动化触发器，
  且需要在 Apple 设备上生成签名。因此不提供模板链接。
- 无法确定的通知进入待处理，后台保存，不拉起 App。

## 影响

- 用户需要在快捷指令里手动建一次自动化（所有卡共用）；这是平台限制，文档如实说明。
- 每条短信都会在后台运行一次 App 动作；非动账短信只做解析，不写数据库。
- 邮件自动化只能按发件人/主题触发，尾号由 App 在正文中校验。
- 免费 Apple 账户签名约 7 天到期，到期后 App 与自动化都无法运行，需续签。
- iOS 27 新增的「通知」触发器属于「通用应用通知接入」，本轮不做。
