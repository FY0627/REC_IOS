# 文档与代码索引

用途：从「问题」直接定位到「该读的文档」和「该看的代码」，不用通读整个仓库。

> **维护规则**：新增、移动或删除模块、文档、决策时，必须同步更新本文件。

## 按问题查

| 问题 / 关键词 | 先读文档 | 再看代码 |
|---|---|---|
| Flutter 版：架构、性能规范、同步、截图自动记账、开发环境 | [architecture/overview.md](architecture/overview.md)、[architecture/performance.md](architecture/performance.md)、[features/sync.md](features/sync.md)、[features/auto-bookkeeping.md](features/auto-bookkeeping.md)、[guides/development.md](guides/development.md) | `main` 分支（见 [decisions/0015](decisions/0015-ios-swift-default-branch.md)） |
| 为什么选 X 而不选 Y | [decisions/](decisions/) | — |
| 原型里某个效果是怎么实现的 | [architecture/performance.md#原型参考](architecture/performance.md#原型参考) | `prototype` 分支的 `lib/` |
| **iOS Swift 版**：整体结构、分层 | [ios-swift/README.md](../ios-swift/README.md)、[decisions/0006](decisions/0006-ios-native-swift.md) | `ios-swift/` |
| iOS Swift 版：短信 / 邮件自动记账、解析、去重、待处理 | [features/ios-swift-auto-bookkeeping.md](features/ios-swift-auto-bookkeeping.md)、[decisions/0008](decisions/0008-ios-swift-shortcuts-app-intent.md) | `ios-swift/Bookkeeping/Intents/` → `ios-swift/Packages/BKCore/Sources/BKBackend/` |
| iOS Swift 版：用户在本机做的识别模板（自己添加、编辑、从待处理做、去敏、模板优先） | [features/ios-swift-auto-bookkeeping.md#识别模板用户在本机做](features/ios-swift-auto-bookkeeping.md#识别模板用户在本机做) | `ios-swift/Bookkeeping/UI/Pending/Template*.swift`、`ios-swift/Packages/BKCore/Sources/BKBackend/Parsing/MessageTemplates.swift` |
| iOS Swift 版：表结构、迁移、事务、并发 | [decisions/0007](decisions/0007-ios-swift-sqlite.md) | `ios-swift/Packages/BKCore/Sources/BKDatabase/` |
| iOS Swift 版：卡包、详情转场、添加卡「+」、卡片信息与卡号、卡面编辑（自定义图片、图片上金额的描边和位置）、管理银行卡（启用停用、拖动排序）、初始余额（在卡片信息里） | [ios-swift/README.md](../ios-swift/README.md)、[decisions/0010](decisions/0010-ios-swift-card-number-and-face.md) | `ios-swift/Bookkeeping/UI/{Assets,Shell}/` |
| iOS Swift 版：卡包转场卡顿、卡片位置、详情列表、顶部玻璃按钮和时间段胶囊（UIKit + Core Animation） | [decisions/0012](decisions/0012-ios-swift-wallet-core-animation.md) | `ios-swift/Bookkeeping/UI/Assets/{WalletController,WalletDetailList,WalletTopBar,CardMotion}.swift`、`ios-swift/Bookkeeping/UI/Common/GlassControls.swift`（玻璃按钮共用部分） |
| iOS Swift 版：多币种账户、主要币种、汇率换算（快捷指令导入） | [decisions/0011](decisions/0011-ios-swift-multi-currency-and-rates.md) | `ios-swift/Bookkeeping/App/ExchangeRateStore.swift`、`ios-swift/Bookkeeping/Intents/ImportExchangeRatesIntent.swift`、`ios-swift/Bookkeeping/UI/Assets/AssetsView.swift`（净资产卡）、`ios-swift/Packages/BKCore/Sources/BKBackend/{LedgerBackend,ExchangeRateFeed}.swift` |
| iOS Swift 版：修改 / 删除 / 搜索流水（列表里滑动编辑、删除）；外币交易按主币种扣款；汇率按天保存 | [decisions/0013](decisions/0013-ios-swift-record-editing-and-foreign-charges.md) | `ios-swift/Bookkeeping/UI/Common/{RecordRowView,RecordEditor,RecordSwipe}.swift`、`ios-swift/Bookkeeping/UI/Assets/WalletDetailList.swift`（卡片详情的左滑按钮）、`ios-swift/Bookkeeping/UI/Home/{HomeView,HomeTopBar}.swift`（标题行和搜索）、`ios-swift/Packages/BKCore/Sources/BKBackend/{LedgerBackend,ChargeCalculator}.swift`、`ios-swift/Packages/BKCore/Sources/BKDatabase/DAO.swift`（`RecordDAO`、`RateDAO`） |
| iOS Swift 版：多币种账户余额不够时整笔换主币种扣（恒生）、流水的扣款币种（记一笔、编辑里选）、可用余额减冻结、卡包里的卡都换算成主要币种（多币种卡是合计）、详情卡面跟着选的币种 | [decisions/0018](decisions/0018-ios-swift-charge-currency-and-converted-cards.md) | `ios-swift/Packages/BKCore/Sources/BKModel/Records.swift`（`chargeCurrency`、`chargedCurrency(in:)`、`setCharge`）、`ios-swift/Packages/BKCore/Sources/BKBackend/{Ingest/IngestEngine,LedgerBackend,ChargeCalculator}.swift`（`lacksBalance`、`balanceSummaries`）、`ios-swift/Packages/BKCore/Sources/BKDatabase/DAO.swift`（`RecordDAO.chargedCurrency`、`forBalance`）、`ios-swift/Bookkeeping/UI/Assets/{WalletCardView,WalletController,AssetsView}.swift`（`stackText`、`cardBalance`）、`ios-swift/Bookkeeping/UI/Home/AddRecordView.swift`、`ios-swift/Bookkeeping/UI/Common/RecordEditor.swift`、`ios-swift/Bookkeeping/App/IngestNotifier.swift` |
| iOS Swift 版：添加银行卡搜银行名称、选币种页面、卡片信息改卡类型 / 主币种 / 初始余额、详情按币种和时间段看流水 | [decisions/0013](decisions/0013-ios-swift-record-editing-and-foreign-charges.md) | `ios-swift/Packages/BKCore/Sources/BKModel/BankCatalog.swift`、`ios-swift/Bookkeeping/UI/Common/CurrencyPicker.swift`、`ios-swift/Bookkeeping/UI/Assets/{AddAccountView,CardInfoView,AccountDetailSummary}.swift` |
| iOS Swift 版：学习分类（商户归一化、候选排序、连续 3 次才自动归类、改掉重新学、分类删除合并时学到的怎么处理）、记账结果通知上选分类（通知代理、动态注册的通知类别、后台写入）、分类建议体检（重放已有流水算命中率）、模拟消费（编短信体验分类建议、一键清除） | [decisions/0017](decisions/0017-ios-swift-learned-categories.md)、[features/ios-swift-auto-bookkeeping.md#自动归类分类](features/ios-swift-auto-bookkeeping.md#自动归类分类) | `ios-swift/Packages/BKCore/Sources/BKBackend/{CategoryLearner,MerchantName,Categorizer,CategoryCheckupReplay,Simulation}.swift`、`ios-swift/Bookkeeping/UI/Profile/{CategoryCheckupView,SimulationView}.swift`、`ios-swift/Packages/BKCore/Sources/BKDatabase/DAO.swift`（`MerchantCategoryDAO`、迁移 11）、`ios-swift/Bookkeeping/App/{IngestNotifier,BookkeepingApp}.swift`、`ios-swift/Bookkeeping/UI/Pending/PendingView.swift`、`ios-swift/Bookkeeping/UI/Common/CategoryGrid.swift`（`SuggestedCategories`） |
| iOS Swift 版：支出 / 收入 / 转帐、分类（自定义、通知写明的直接归类、待分类）、首页一笔钱一行、首页本月合计换算成主要币种、手动记一笔（先选币种再选账户，账户没有的币种按主币种扣款）、现金和电子钱包（钱包通知自动记账）、编辑转帐的另一边、转帐填到账金额和币种、同卡换汇、合成一单和选几笔拆开、按时间段统计（默认本周；看全部账户（换算成主要币种）、一个账户或一个币种，上面总览、下面按分类）、删除停用的账户（流水保留，写「已删除」）、首页搜索（模糊金额、按类型筛选）、校准余额 | [decisions/0014](decisions/0014-ios-swift-entry-types-and-categories.md) | `ios-swift/Packages/BKCore/Sources/BKModel/{Categories,Records}.swift`、`ios-swift/Packages/BKCore/Sources/BKBackend/{Categorizer,LedgerBackend,ChargeCalculator}.swift`、`ios-swift/Packages/BKCore/Sources/BKDatabase/{DAO,Migrations}.swift`（`CategoryDAO`、迁移 8；删除账户的标记是迁移 9）、`ios-swift/Packages/BKCore/Sources/BKModel/Banks.swift`（`WalletDirectory`）、`ios-swift/Bookkeeping/UI/Common/{RecordRowView,RecordDisplay,CategoryGrid,RecordEditor,TransferSideFields,TitleBar}.swift`、`ios-swift/Bookkeeping/UI/Home/AddRecordView.swift`、`ios-swift/Bookkeeping/UI/Profile/CategoryManagerView.swift`、`ios-swift/Bookkeeping/UI/Stats/StatsView.swift`、`ios-swift/Bookkeeping/UI/Common/ConvertedTotalsView.swift`（首页和统计页的换算合计） |
| iOS Swift 版：App 图标（Icon Composer 分层图标、深色 / 着色外观、和界面外观分开选的备用图标、CI 渲染预览） | [ios-swift/README.md#app-图标](../ios-swift/README.md#app-图标) | `ios-swift/Bookkeeping/{AppIcon,AppIconLight,AppIconDark}.icon/`、`ios-swift/Bookkeeping/App/BookkeepingApp.swift`（`AppearanceMode.applyIcon`）、`ios-swift/ci/icon-preview.sh` |
| iOS Swift 版：「我的」页（分组、二级页面标签栏动画、通知开关、主题色）、选币种的水滴搜索框 | [ios-swift/README.md](../ios-swift/README.md) | `ios-swift/Bookkeeping/UI/Profile/ProfileView.swift`、`ios-swift/Bookkeeping/UI/Profile/ThemeColorSheet.swift`、`ios-swift/Bookkeeping/UI/Theme/AppTheme.swift`（`ThemeColor`）、`ios-swift/Bookkeeping/UI/Common/GlassSearchBar.swift` |
| iOS Swift 版：导出全部数据（CSV + 数据库副本打成 zip）、导入时选增量或覆盖、撤销上次导入 | [decisions/0019](decisions/0019-ios-swift-export-and-import.md) | `ios-swift/Packages/BKCore/Sources/BKBackend/{DataExport,BackupImport,ZipStore}.swift`、`ios-swift/Bookkeeping/UI/Profile/{DataExportView,DataImportView}.swift`、`ios-swift/Bookkeeping/App/LedgerStore.swift`（导入前自动存的副本） |
| iOS Swift 版：卡顿、性能开关、帧率指标 | [guides/ios-swift-device-checklist.md](guides/ios-swift-device-checklist.md) | `ios-swift/Bookkeeping/Diagnostics/` |
| iOS Swift 版：CI 构建、IPA、iLoader 安装与续签 | [guides/ios-swift-windows-iloader.md](guides/ios-swift-windows-iloader.md)、[decisions/0009](decisions/0009-ios-swift-ci-sideloadly.md)、[decisions/0016](decisions/0016-ios-swift-iloader.md) | `.github/workflows/ios-swift-build.yml`、`ios-swift/ci/` |

## 按目录查

| 目录 | 职责 |
|---|---|
| `ios-swift/` | iOS 原生 Swift 版，见 [ios-swift/README.md](../ios-swift/README.md) |
| `ios-swift/Bookkeeping/` | App target：SwiftUI 界面、App Intents、性能诊断 |
| `ios-swift/Packages/BKCore/` | 纯 Swift 业务核心：`BKModel` 值类型、`BKDatabase` SQLite、`BKBackend` 解析与入账 |
| `ios-swift/ci/` | GitHub Actions 调用的测试、构建、打包、校验脚本 |
| `docs/` | 文档（见下表） |

## 文档目录

| 目录 | 内容 |
|---|---|
| [assets/](assets/) | 仓库首页 README 用的图标、演示动图和截图 |
| [architecture/](architecture/) | [overview.md](architecture/overview.md)：分层与约定；[performance.md](architecture/performance.md)：性能规范与待验证项 |
| [decisions/](decisions/) | 架构决策记录（ADR）：[0001 本地优先](decisions/0001-local-first-no-server.md)、[0002 后端 Dart](decisions/0002-backend-dart.md)、[0003 数据库](decisions/0003-database-sqlite-drift.md)、[0004 同步](decisions/0004-sync-qr-lan.md)、[0005 自动记账](decisions/0005-auto-bookkeeping-screenshot-ocr.md)、[0006 iOS 改用原生 Swift](decisions/0006-ios-native-swift.md)、[0007 iOS Swift 数据库](decisions/0007-ios-swift-sqlite.md)、[0008 iOS Swift 自动记账接入](decisions/0008-ios-swift-shortcuts-app-intent.md)、[0009 iOS Swift 构建与分发](decisions/0009-ios-swift-ci-sideloadly.md)、[0010 iOS Swift 卡号与卡面](decisions/0010-ios-swift-card-number-and-face.md)、[0011 iOS Swift 多币种与汇率](decisions/0011-ios-swift-multi-currency-and-rates.md)、[0012 iOS Swift 卡包转场改用 UIKit + Core Animation](decisions/0012-ios-swift-wallet-core-animation.md)、[0013 iOS Swift 流水修改删除与外币扣款](decisions/0013-ios-swift-record-editing-and-foreign-charges.md)、[0014 iOS Swift 支出收入转帐与分类](decisions/0014-ios-swift-entry-types-and-categories.md)、[0015 ios-swift 作为默认分支](decisions/0015-ios-swift-default-branch.md)、[0016 iOS Swift 改用 iLoader 安装](decisions/0016-ios-swift-iloader.md)、[0017 iOS Swift 学习分类和通知上选分类](decisions/0017-ios-swift-learned-categories.md)、[0018 iOS Swift 多币种扣款币种和卡包换算成主要币种](decisions/0018-ios-swift-charge-currency-and-converted-cards.md)、[0019 iOS Swift 导出全部数据和导入](decisions/0019-ios-swift-export-and-import.md) |
| [features/](features/) | 功能设计：[sync.md](features/sync.md)、[auto-bookkeeping.md](features/auto-bookkeeping.md)、[ios-swift-auto-bookkeeping.md](features/ios-swift-auto-bookkeeping.md) |
| [guides/](guides/) | [development.md](guides/development.md)：Flutter 版的环境、命令、性能测量方法；[ios-swift-windows-iloader.md](guides/ios-swift-windows-iloader.md)：Windows 下载 IPA、iLoader 安装与续签；[ios-swift-device-checklist.md](guides/ios-swift-device-checklist.md)：真机验收清单 |
