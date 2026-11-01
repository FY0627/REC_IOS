# 0009 iOS Swift 版构建与分发：GitHub Actions 打包未签名 IPA，用户用 Sideloadly 签名安装

- 状态：已采纳（`ios-swift/`）；签名安装工具已改用 iLoader，见 [ADR 0016](0016-ios-swift-iloader.md)
- 日期：2026-10-24

## 背景

开发者只有 Windows 11 电脑和一台 iPhone 16 Pro（iOS 27.0.1），没有 Mac，也不假设有付费开发者账户。
编译、测试、打包必须在云端 macOS 上完成；签名只能由用户在本地用自己的 Apple 账户完成。

## 备选方案

| 方案 | 结论 |
|---|---|
| 本地 Xcode | 没有 Mac |
| `xcodebuild archive` + `-exportArchive` | 导出需要签名身份与描述文件；未签名 archive 不能用常规导出流程生成 IPA |
| XcodeGen / Tuist 生成工程 | 多一个工具依赖；工程文件可以直接手写并提交 |
| TestFlight / App Store | 需要付费开发者账户 |
| **xcode-27 runner 构建未签名真机 .app → 打包 Payload/ IPA → Sideloadly 本地签名** | 采纳 |

## 决定

- 工作流 `.github/workflows/ios-swift-build.yml`，`runs-on: xcode-27`（GitHub 托管、macOS 27、Apple Silicon，
  2026-10-15 GA）。工具链版本不写死，运行时打印 `xcodebuild -version`、Swift、iOS SDK 并校验部署目标。
- 步骤：BKCore 在 macOS 主机 `swift test` → 同一套测试在 iOS 模拟器 `xcodebuild test` →
  `xcodebuild build -configuration Release -sdk iphoneos ARCHS=arm64 CODE_SIGNING_ALLOWED=NO` →
  校验（arm64、Mach-O 平台为 iOS 真机、Info.plist、依赖、Assets.car、`Metadata.appintents`）→
  按 `Payload/Bookkeeping.app` 打包 → SHA-256。
- 上传 IPA（30 天）与日志 / xcresult / dSYM（14 天）。失败时把错误行写成运行注释，失败不会被标成成功。
- 权限只有 `contents: read`；不使用任何 Secrets；CI 中只有合成测试样例。
- 工程文件 `Bookkeeping.xcodeproj` 手写（objectVersion 77，文件夹同步 + 本地 Swift 包），共享 scheme 一并提交。

## 影响

- 用户需要在 Windows 上安装 Sideloadly（以及其要求的网页版 iTunes / iCloud），用自己的 Apple 账户签名。
  现在的步骤见 [guides/ios-swift-windows-iloader.md](../guides/ios-swift-windows-iloader.md)。
- 免费账户签名约 7 天有效，需要定期重签；Bundle ID 和签名账户保持不变才能覆盖安装并保留数据。
- runner 镜像更新后 Xcode 默认版本可能变化；可用 `workflow_dispatch` 的 `xcode_app` 参数指定。
