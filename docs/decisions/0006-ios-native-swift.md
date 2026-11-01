# 0006 iOS 新版改用原生 Swift

- 状态：已采纳（仅适用于 `ios-swift/` 下的 iOS 版本；Flutter 版本的决策不变）
- 日期：2026-10-24

## 背景

iOS 端的自动记账需要由系统「快捷指令」在后台调用 App 提供的 App Intent。App Intent 只能用 Swift 声明，
而且要在 App 自己的 target 里才能被系统发现和在后台运行。如果继续用 Flutter，iOS 上的 App Intent 仍要写在
原生层，后台执行时还要额外拉起 Flutter 引擎；业务逻辑要么在 Dart 与 Swift 之间重复，要么每次入账都要等引擎启动。

项目所有者明确授权：iOS 新版本改用 Swift，独立放在 `ios-swift/`，不依赖 Flutter 运行时。

## 备选方案

| 方案 | 优点 | 缺点 |
|---|---|---|
| Flutter + 原生 App Intent 桥接 | 与 Android 共用界面代码 | 后台入账要拉起 Flutter 引擎，冷启动慢、内存占用高；解析逻辑要么跨语言重复，要么依赖引擎 |
| **原生 Swift（SwiftUI）** | App Intent、SQLite、界面在同一进程同一语言；后台执行只加载需要的代码；能用 iOS 26 起的系统控件 | 与 Flutter 版本不共用代码 |
| Kotlin Multiplatform 共享业务层 | 业务层可跨端共享 | 引入新工具链与依赖；没有 Mac 时调试困难 |

## 决定

`ios-swift/` 采用 Swift 6 工具链、SwiftUI 界面，继承项目的原则：本地优先、分层、重任务离开主线程、性能优先。

| 层 | 位置 | 对应 Flutter 版 |
|---|---|---|
| 界面（SwiftUI） | `ios-swift/Bookkeeping/UI/` | `app/` |
| App Intents | `ios-swift/Bookkeeping/Intents/` | `native/ios/` |
| 业务层 `BKBackend` | `ios-swift/Packages/BKCore/Sources/BKBackend/` | `backend/` |
| 数据库层 `BKDatabase` | `ios-swift/Packages/BKCore/Sources/BKDatabase/` | `database/` |
| 值类型 `BKModel` | `ios-swift/Packages/BKCore/Sources/BKModel/` | — |

- 依赖方向：`App → BKBackend → BKDatabase → BKModel`；App 不 import `BKDatabase`（CI 检查）。
- `BKCore` 是纯 Swift 本地包，不依赖 SwiftUI / UIKit，可以在 macOS、iOS 模拟器和 Linux（本地 Docker）上跑测试。
- 单个 App target，不建 App Extension，不使用 App Groups、推送、iCloud、Network Extension 等能力，
  免费 Apple 账户签名即可安装。
- 部署目标 iOS 26.0（不高于用户设备的 iOS 27.0.1），以使用 `IntentModes.background` 等 iOS 26 起的接口。
- App target 使用 Swift 5 语言模式 + 完整并发检查（`SWIFT_STRICT_CONCURRENCY = complete`）；`BKCore` 使用 Swift 6 语言模式。

## 影响

- Flutter 专用规则（例如 `app` 不能 import `bk_database`、用 `Isolate.run` 做重活）继续约束 Flutter 版本；
  Swift 版本以对应的 Swift 方式落实：数据库访问与解析在专用串行队列上执行，不假设 `async` 会自动离开 MainActor。
- 包名、Bundle ID 延续临时命名：`com.example.bookkeepingApp.swift`、`BK*` 模块前缀。
- 数据库选型见 [0007](0007-ios-swift-sqlite.md)，自动记账接入见 [0008](0008-ios-swift-shortcuts-app-intent.md)，
  构建分发见 [0009](0009-ios-swift-ci-sideloadly.md)。
