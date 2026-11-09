# 0023 iOS Swift 版：付费开发者账号签名，经 TestFlight 分发

- 状态：已采纳（`ios-swift/`；安装方式取代 [ADR 0016](0016-ios-swift-iloader.md) 的 iLoader 侧载，未签名 IPA 的构建流程不变）
- 日期：2026-11-09

## 背景

- 以前用免费 Apple ID 加 iLoader 侧载：要电脑，每 7 天续签一次。大陆的朋友内测时最难的是安装和续签（mainland beta）。
- 2026-11-09 付费开发者账号批下来了。TestFlight 装的 App 正式签名，不用电脑、不用续签，每个构建 90 天有效。
- 原来的 Bundle ID `com.example.bookkeepingApp.swift` 是示例前缀，Apple 不让注册。

## 决定

**Bundle ID 改成 `com.fy0627.rec`**，通知扩展 `com.fy0627.rec.NotificationContent`。
在 App Store Connect 建好 App 以后就不能再改。`BK*` 模块名不在这次改（AGENTS.md 规则 6 的改名另做）。

**上传**：工作流 [`.github/workflows/ios-swift-testflight.yml`](../../.github/workflows/ios-swift-testflight.yml)，
只能手动触发（Actions › iOS Swift TestFlight › Run workflow），脚本是 [`ios-swift/ci/archive-upload.sh`](../../ios-swift/ci/archive-upload.sh)：

1. `xcodebuild archive`，自动签名，`-allowProvisioningUpdates` 加 App Store Connect API 密钥：
   证书和描述文件由 Xcode 在线创建、下载（分发证书由 Apple 云端管理），仓库和 Secrets 里没有证书、没有描述文件；
2. `xcodebuild -exportArchive`，`method = app-store-connect`、`destination = upload`：签名导出后直接上传，不另用 altool / Transporter。
3. 构建号 = 这个工作流的运行次数 × 10 + 重跑次数，重跑不会和已上传的重复。版本号仍是 `MARKETING_VERSION`。

需要的仓库 Secrets：`ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_KEY_P8`（.p8 文件全文）、`APPLE_TEAM_ID`。
API 密钥的角色要「管理」（Admin）：创建云端管理的分发证书需要这个权限。
自动签名归档时要生成开发描述文件，开发者账号里至少要登记一台设备。

**隐私清单**：`ios-swift/Bookkeeping/PrivacyInfo.xcprivacy`，App Store Connect 收上传时检查。
不跟踪、不收集数据；用到的「需要说明理由的 API」只有 `UserDefaults`（`CA92.1`，只在 App 自己里读写）。
以后用到文件时间、开机时间、磁盘空间、键盘列表这几类 API 时要加进去。

**推送照旧**：`ios-swift-build.yml` 每次推送仍测试、出未签名 IPA，校验 Bundle ID 是新的。

## 没有选的

- **每次推送都上传**：用户推得勤，TestFlight 里会堆很多版，测试的人一直收到更新；需要时手动点一下。以后想改，在工作流里加 `push` 触发即可。
- **手动管理证书**（把 .p12 和描述文件放进 Secrets）：要自己续证书、导出、编码，过期还要换 Secrets；自动签名加 API 密钥一个密钥就够了。
- **fastlane**：多一个 Ruby 依赖，这里两条 `xcodebuild` 命令就能完成。

## 影响

- Bundle ID 变了：iOS 当成另一个 App。侧载的旧 App 和 TestFlight 装的新 App 可以同时在手机上；
  账本用「我的 › 隐私与数据 › 导出数据」从旧 App 导出、在新 App 里导入（ADR 0019）。快捷指令自动化要指向新 App 重新建。
- 汇率的共享快捷指令按 App 标识找动作（ADR 0011），现在的链接是用旧标识做的：`ExchangeRateGuideView.shortcutBundleID` 先不改，
  新 App 对不上就显示自己搭的步骤；用 TestFlight 装的 App 重新做一份链接后，把 `shortcutURL` 和 `shortcutBundleID`（`com.fy0627.rec`，没有团队后缀）一起改。
- 外部测试员（不在 App Store Connect 团队里的朋友）第一次要等 Apple 审核这个测试版；内部测试员（团队成员，最多 100 人）不用审。
- 构建 90 天后过期，要再跑一次工作流。
- iLoader 侧载仍然能用（CI 照旧出未签名 IPA），只是 Bundle ID 变成了新的。
