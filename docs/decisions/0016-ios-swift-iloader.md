# 0016 iOS Swift 版改用 iLoader 签名安装

- 状态：已采纳（替换 [ADR 0009](0009-ios-swift-ci-sideloadly.md) 里的签名安装工具，构建流程不变）
- 日期：2026-10-31

## 背景

ADR 0009 选了 Sideloadly。2026-10-24 在真机上，Sideloadly 0.71.1 登录失败（`-80046`）；
换成 [iLoader](https://github.com/nab138/iloader) v2.4.0 后能登录、安装，App 可以正常使用。

## 决定

- 用户在 Windows 上用 iLoader 和自己的 Apple 账户，给 CI 生成的未签名 IPA 签名并安装。
- iLoader 只从官方渠道下载：GitHub Releases 或 <https://iloader.app>。
- CI 不变：继续生成未签名 IPA，不使用证书和 Secrets。

## 影响

- 安装指南改为 [guides/ios-swift-windows-iloader.md](../guides/ios-swift-windows-iloader.md)。
- Windows 上需要 iTunes。设备检测不到时检查 USB 驱动。
- iLoader 的官方说明没有写续签方式和 Bundle ID 的处理，指南只写已确认的做法：到期前用同一个 Apple 账户重新安装。
- iLoader 只是用户本机的工具，不进入 App，也不进入 CI。
