# Windows 11 + iPhone：下载 IPA、用 iLoader 安装、设置自动记账

适用：没有 Mac，只有 Windows 11 电脑和 iPhone（本项目按 iPhone 16 Pro / iOS 27.0.1 编写）。
构建在 GitHub Actions 上完成（[ADR 0009](../decisions/0009-ios-swift-ci-sideloadly.md)），签名在你自己的电脑上用你自己的 Apple 账户完成（[ADR 0016](../decisions/0016-ios-swift-iloader.md)）。

> Apple 账户密码只在你本机的 iLoader 里输入。不要放进仓库、GitHub Secrets 或发给任何人。
> iLoader 是第三方工具，它会用你的 Apple 账户向 Apple 申请免费的开发证书；请只从官方渠道下载。

## 1. 下载 IPA

1. 打开仓库的 Actions 页面：`https://github.com/FY0627/REC_IOS/actions/workflows/ios-swift-build.yml`，进入最新一次绿色（成功）的运行。
2. 页面底部 **Artifacts** 里下载名为 `Bookkeeping-<版本>-b<构建号>-<提交前8位>` 的产物（需要登录 GitHub）。
3. 解压得到 `.ipa`、`.ipa.sha256`、`build-info.txt`、`ipa-verification.txt`。
4. 在 PowerShell 中校验：

   ```powershell
   Get-FileHash .\Bookkeeping-*.ipa -Algorithm SHA256
   Get-Content .\Bookkeeping-*.ipa.sha256
   ```

   两个哈希值必须一致；也可以与运行页面上「IPA」注释里的 sha256 对照。

## 2. 安装 iLoader 及其依赖

1. 只从官方渠道下载 Windows 版：<https://github.com/nab138/iloader/releases> 或 <https://iloader.app>。
2. 安装 [iTunes](https://apple.co/ms)，iLoader 靠它连接 iPhone。

## 3. 连接 iPhone 并登录

下面按 [iLoader 官方说明](https://github.com/nab138/iloader#how-to-use) 的顺序写，界面和步骤有变化时以官方为准。

1. 用数据线连接 iPhone 与电脑，解锁 iPhone。弹出「要信任此电脑吗？」时选「信任」并输入锁屏密码。
2. 打开 iLoader，登录你自己的 Apple 账户。**不需要付费开发者账户。**

## 4. 导入 IPA

1. 在 iLoader 里选择导入 IPA（官方功能名是「Import any IPA」），选中第 1 步下载的 `.ipa`。
2. **以后每次安装都用同一个 Apple 账户，不要改 Bundle ID**（默认是 `com.example.bookkeepingApp.swift`），
   否则会被当成另一个 App：数据不能保留，快捷指令里的动作引用也会失效。

## 5. 在 iPhone 上允许运行

按 iOS 实际出现的提示操作（以设备显示为准）：

1. **开发者模式**：`设置 › 隐私与安全性 › 开发者模式` 打开，按提示重启并确认。
   （开发证书签名的 App 在 iOS 16 及以后需要开启；安装过此类 App 后该开关才会出现。）
2. **信任开发者**：`设置 › 通用 › VPN 与设备管理`，在「开发者 App」下找到你的 Apple 账户 → 信任。此步需要联网验证。
3. 打开「REC」，确认能看到首页。

## 6. 确认快捷指令能发现 App 动作

1. 打开「快捷指令」→ 任意新建一个快捷指令 → 添加操作 → 搜索「REC」。
2. 应能看到「记录银行动账通知」。看不到时：先打开一次「REC」App，再回到快捷指令搜索；仍看不到请记录 iOS 版本并反馈。

## 7. 设置自动记账并做一次真实验证

1. 在 App「资产」页点右上角的「+」添加银行卡：银行、后四位（前导 0 会保留）、卡类型、币种，可选填初始余额。
2. 保存后进入「设置自动记账」，按页面里的 5 步在快捷指令里创建**一个**自动化：触发条件「信息」「电子邮件」「App 通知」
   （「信息」**条件不填**；「电子邮件」必须有条件，填**主题包含**「你」）、**立即运行**、动作「记录银行动账通知」、通知内容 = 自动化的输入、来源 =「自动」。
   这个自动化覆盖所有银行卡，之后添加的卡不用再设置。
3. 等下一条**真实**的银行动账短信 / 邮件。不需要打开记账 App。
4. 打开 App → 「我的 › 自动记账状态」里这张卡应变为「已通过真实触发验证 · …」，首页出现这笔流水。
5. 按 [真机验收清单](ios-swift-device-checklist.md) 分别在「其他 App 前台」「锁屏」「App 未启动」「无网络」条件下各验证一次，并记录结果。

## 8. 更新、续签与数据保留

| 情况 | 做法 | 数据 |
|---|---|---|
| 新版本 IPA | 用 iLoader、**同一 Apple 账户、同一 Bundle ID** 直接安装覆盖。**不要先删除旧 App。** | 覆盖安装按 iOS 规则保留 App 数据（需真机确认，见清单） |
| 免费签名到期（约 7 天） | 到期前用同一个 IPA 重新安装一次即可续签 | 保留 |
| 已经过期 | App 打不开、自动化运行失败；重新签名安装后恢复。过期期间到达的通知不会被补记 | 保留（未删除 App 时） |
| 删除 App | 本地账本随之删除，无云备份 | **丢失** |

免费 Apple 账户的已知限制（以 Apple / iLoader 实际提示为准）：签名约 7 天有效；同时安装的侧载 App 数量有限（常见为 3 个）；
每 7 天可注册的 App ID 数量有限（常见为 10 个），频繁更换 Bundle ID 会很快用完。可以在 iLoader 里查看和撤销开发证书与 App ID。

## 9. 常见问题

- **iLoader 检测不到 iPhone**：确认 iPhone 已解锁并信任这台电脑。新版 iTunes 可能不再自带 USB 驱动，到 Windows Update 的可选更新里安装「Apple, Inc. - USBDevice」。
- **iLoader 报错**：日志在 `%APPDATA%\me.nabdev.iloader\logs`。
- **快捷指令每次都问我是否运行**：自动化没选「立即运行」。编辑自动化改为立即运行。
- **每次运行都有系统通知**：在该自动化里关闭「运行时通知」。这是系统行为，不是 App 弹窗。
- **状态一直「待验证」**：在「我的 › 自动记账状态」看接收日志。没有任何记录说明自动化没有触发；有「空输入」说明「通知内容」没有选「快捷指令输入」。
- **记到了待处理**：打开首页的待处理入口，从系统给出的候选账户中确认或忽略。
