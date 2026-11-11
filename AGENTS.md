# AGENTS.md

AI 编程助手的入口文件。Claude Code 通过 `CLAUDE.md` 引用本文件，其他工具直接读取本文件。

## 项目

本地优先的记账 App。默认分支 `ios-swift` 是 iOS 原生 Swift 版。

- **没有服务器**：数据保存在手机本地的 SQLite 里；多台设备之间通过「扫码配对 + 局域网直传」同步。
- **低端机优先**：目标设备包括 2020 年左右的 60Hz 手机，性能、资源占用和稳定性优先于视觉效果。
- **其他分支**：这个仓库只有 `ios-swift`。早期的 Flutter 骨架和前端原型（见 [ADR 0015](docs/decisions/0015-ios-swift-default-branch.md)）留在私有的旧仓库。

## 先查索引

定位问题前先读 [docs/INDEX.md](docs/INDEX.md)。按索引只打开相关的文档和目录，不要通读整个仓库。

## 结构

| 目录 | 内容 | 模块 |
|---|---|---|
| `ios-swift/Bookkeeping/` | App target：SwiftUI 界面、App Intents、性能诊断 | `Bookkeeping` |
| `ios-swift/NotificationContent/` | 通知内容扩展：长按记账结果通知选分类（ADR 0020），只链接 `BKModel` | `NotificationContent` |
| `ios-swift/CategoryActivity/` | 小组件扩展：灵动岛上选分类的实时活动（ADR 0024），只链接 `BKModel` | `CategoryActivity` |
| `ios-swift/Shared/` | App 和 `CategoryActivity` 都编译的文件：实时活动的内容、岛上按钮的动作 | — |
| `ios-swift/Packages/BKCore/` | 纯 Swift 业务核心（见 ADR 0006–0009） | `BKModel` / `BKDatabase` / `BKBackend` |
| `ios-swift/ci/` | GitHub Actions 调用的测试、构建、打包、校验脚本 | — |
| `ios-swift/Localization/` | 界面文字的翻译表（台湾繁体、英文），生成 `Bookkeeping/Localizable.xcstrings`（ADR 0022） | — |
| `docs/` | 文档 | — |

详细说明见 [ios-swift/README.md](ios-swift/README.md)。

## 命令

```sh
# BKCore 测试：Windows 上用 Docker，镜像构建方法见 ios-swift/README.md
docker run --rm -v "<仓库>/ios-swift/Packages/BKCore:/pkg" -w /pkg bk-swift swift test
```

App target 和 IPA 由 GitHub Actions 构建，见 `.github/workflows/ios-swift-build.yml`。

## 硬性规则

1. **依赖方向是单向的**：`App → BKBackend → BKDatabase → BKModel`。
   - App 不能直接 import `BKDatabase`（CI 检查）。
   - `BKCore` 不能依赖 SwiftUI / UIKit。
2. **主线程不做重活**：数据库访问和解析在专用串行队列上执行，不要假设 `async` 会自动离开 MainActor。
3. **性能改动**在真机上测量，一次只改一个变量，用「性能开关与调试指标」做对照，方法见 [docs/guides/ios-swift-device-checklist.md](docs/guides/ios-swift-device-checklist.md)。
4. **引入新的第三方依赖、改变架构或技术选型**时，在 `docs/decisions/` 新增一份 ADR。
5. **新增、移动或删除模块 / 文档 / 决策后**，同步更新 [docs/INDEX.md](docs/INDEX.md)。
6. **包名是临时的**：`BK*` 和 `com.example` 会在项目改名时统一替换，不要再引入新的命名前缀。
