# 文档与代码索引

按关键词找该读的文档和该看的目录。函数名直接搜代码，这里不列。新增、移动或删除模块、文档、决策时同步更新本文件；目录职责见 [AGENTS.md](../AGENTS.md)。

代码路径：`App/`、`UI/`、`Intents/` 在 `ios-swift/Bookkeeping/` 下；`BKModel/`、`BKDatabase/`、`BKBackend/` 在 `ios-swift/Packages/BKCore/Sources/` 下。自动记账文档在 [features/ios-swift-auto-bookkeeping/](features/ios-swift-auto-bookkeeping/README.md)（下表简写 `自动记账/`）。

| 关键词 | 文档 | 代码 |
|---|---|---|
| 整体结构、分层、构建、App 图标、卡片信息与卡面 | [ios-swift/README.md](../ios-swift/README.md)、[0006](decisions/0006-ios-native-swift.md) | `ios-swift/` |
| 短信 / 邮件 / App 通知解析、哪些记成交易、Apple 钱包通知 | [自动记账/parsing](features/ios-swift-auto-bookkeeping/parsing.md)、[0008](decisions/0008-ios-swift-shortcuts-app-intent.md) | `Intents/`、`BKBackend/Parsing/`、`BKBackend/Ingest/` |
| 账户匹配、电子钱包、去重、待处理 | [自动记账/accounts](features/ios-swift-auto-bookkeeping/accounts.md) | `BKBackend/Ingest/`、`UI/Pending/` |
| 识别模板、「不记」、朝朝宝 | [自动记账/templates](features/ios-swift-auto-bookkeeping/templates.md) | `UI/Pending/Template*.swift`、`BKBackend/Parsing/MessageTemplates.swift` |
| 冻结、完成扣款、内部转账 / 还款 / 退款、余额 | [自动记账/holds-transfers-balance](features/ios-swift-auto-bookkeeping/holds-transfers-balance.md) | `BKBackend/Ingest/IngestEngine.swift`、`BKBackend/LedgerBackend.swift` |
| 微信、支付宝付款页截图 | [自动记账/screenshots](features/ios-swift-auto-bookkeeping/screenshots.md)、[0021](decisions/0021-ios-swift-payment-screenshots.md) | `Intents/RecordPaymentScreenshotIntent.swift`、`App/ScreenshotReader.swift`、`BKBackend/Parsing/ScreenshotParser.swift`、`ScreenshotIcon.swift`（对勾颜色） |
| 学习分类、饭点、小词库、分类建议体检、模拟消费 | [自动记账/categories](features/ios-swift-auto-bookkeeping/categories.md)、[0017](decisions/0017-ios-swift-learned-categories.md)、[0026](decisions/0026-ios-swift-meal-time-learning-and-lexicon.md) | `BKBackend/{CategoryLearner,MealTime,CategoryLexicon,Categorizer,CategoryCheckupReplay,Simulation}.swift` |
| 记账结果通知、通知扩展选分类 | [自动记账/notifications](features/ios-swift-auto-bookkeeping/notifications.md)、[0020](decisions/0020-ios-swift-notification-category-picker.md) | `App/IngestNotifier.swift`、`ios-swift/NotificationContent/` |
| 灵动岛选分类（实时活动） | [0024](decisions/0024-ios-swift-dynamic-island-category-picker.md) | `ios-swift/CategoryActivity/`、`ios-swift/Shared/`、`BKModel/LiveCategoryPicker.swift`、`App/LiveCategoryActivity.swift` |
| 支出 / 收入 / 转帐、分类管理、合成转帐、统计、首页、校准余额 | [0014](decisions/0014-ios-swift-entry-types-and-categories.md) | `BKModel/{Categories,Records}.swift`、`UI/{Common,Home,Stats}/`、`UI/Profile/CategoryManagerView.swift` |
| 修改 / 删除 / 搜索流水、外币扣款、按天存汇率、添加银行卡 | [0013](decisions/0013-ios-swift-record-editing-and-foreign-charges.md) | `UI/Common/{RecordRowView,RecordEditor,RecordSwipe}.swift`、`BKBackend/ChargeCalculator.swift` |
| 多币种账户、主要币种、汇率导入 | [0011](decisions/0011-ios-swift-multi-currency-and-rates.md) | `App/ExchangeRateStore.swift`、`Intents/ImportExchangeRatesIntent.swift` |
| 扣款币种、卡包换算成主要币种 | [0018](decisions/0018-ios-swift-charge-currency-and-converted-cards.md) | `BKModel/Records.swift`、`UI/Assets/` |
| 卡包、卡号、卡面、管理银行卡 | [0010](decisions/0010-ios-swift-card-number-and-face.md) | `UI/{Assets,Shell}/`、`BKModel/BankCatalog.swift` |
| 卡包转场卡顿、玻璃按钮（UIKit + Core Animation） | [0012](decisions/0012-ios-swift-wallet-core-animation.md) | `UI/Assets/{WalletController,CardMotion}.swift`、`UI/Common/GlassControls.swift` |
| 表结构、迁移、事务、并发 | [0007](decisions/0007-ios-swift-sqlite.md) | `BKDatabase/` |
| 导出、导入 | [0019](decisions/0019-ios-swift-export-and-import.md) | `BKBackend/{DataExport,BackupImport,BackupExtras,ZipStore}.swift`、`UI/Profile/Data*View.swift` |
| 演示数据 | [0025](decisions/0025-ios-swift-demo-ledger.md) | `App/DemoMode.swift`、`BKBackend/DemoLedger.swift` |
| 「我的」页、主题色、反馈、新手引导 | [ios-swift/README.md](../ios-swift/README.md) | `UI/Profile/`、`UI/Shell/OnboardingView.swift` |
| 语言、翻译表 | [0022](decisions/0022-ios-swift-languages.md) | `App/AppLanguage.swift`、`ios-swift/Localization/` |
| 真机验收、性能改动怎么测 | [guides/ios-swift-device-checklist.md](guides/ios-swift-device-checklist.md) | — |
| CI、IPA、iLoader 安装与续签 | [guides/ios-swift-windows-iloader.md](guides/ios-swift-windows-iloader.md)、[0009](decisions/0009-ios-swift-ci-sideloadly.md)、[0016](decisions/0016-ios-swift-iloader.md) | `.github/workflows/ios-swift-build.yml`、`ios-swift/ci/` |
| TestFlight、Bundle ID、隐私清单 | [0023](decisions/0023-ios-swift-testflight.md) | `.github/workflows/ios-swift-testflight.yml`、`ios-swift/ci/archive-upload.sh` |
| 为什么选 X 不选 Y | [decisions/](decisions/)（文件名就是标题） | — |
| Flutter 旧版：架构、同步、截图记账、开发环境 | `architecture/`、`features/{sync,auto-bookkeeping}.md`、`guides/development.md` | 私有旧仓库（[0015](decisions/0015-ios-swift-default-branch.md)） |
