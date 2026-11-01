<p align="center">
  <img src="docs/assets/icon.png" width="96" alt="REC 图标">
</p>

<h1 align="center">REC</h1>

<p align="center"><b>Record Every Cent</b><br>花了钱，账自动记好。</p>

REC 是一款 iPhone 记账 App。你付完款，银行短信一到，它就在后台把账记好，连 App 都不用打开。

<table>
  <tr>
    <td align="center"><img src="docs/assets/demo/auto-bookkeeping.gif" width="260" alt="付款后银行短信到达，App 在后台自动记好这笔账"></td>
    <td align="center"><img src="docs/assets/demo/wallet.gif" width="260" alt="资产页的银行卡像钱包一样叠放，点开可以看详情"></td>
  </tr>
  <tr>
    <td align="center">自动记账</td>
    <td align="center">银行卡像钱包一样管理</td>
  </tr>
</table>

## 为什么用它

- **不用手动记账**：设置一次快捷指令，之后银行短信、邮件和 App 通知都能自动入账。
- **账本只在你手机里**：App 不联网，没有服务器，不用注册账号。
- **认不准就先问你**：看不懂的通知放进「待处理」等你确认。同一笔钱收到短信和邮件，也只记一笔。
- **多币种不头疼**：一张卡可以放多个币种，净资产按你的主要币种换算。
- **用起来就像系统自带的 App**：用 SwiftUI 原生开发，界面和手感都跟 iPhone 一致。

<p align="center">
  <img src="docs/assets/demo/home.jpg" width="23%" alt="首页：本月支出和流水">
  <img src="docs/assets/demo/stats.jpg" width="23%" alt="统计：按分类查看收支">
  <img src="docs/assets/demo/pending.jpg" width="23%" alt="待处理：等你确认的流水，验证码不保存内容">
  <img src="docs/assets/demo/profile.jpg" width="23%" alt="我的：外观、币种和自动记账设置">
</p>

## 现在能用吗

还在测试，没有上架 App Store。需要 iOS 27 或更高版本，目前要用 [iLoader](https://github.com/nab138/iloader) 自己签名安装，步骤见[安装指南](docs/guides/ios-swift-windows-iloader.md)。

有些银行的短信还认不准，可以在 App 里自己做识别模板。演示里的「日常记账」是 REC 改名前的名字。

## 开发

代码在 [`ios-swift/`](ios-swift/README.md)，文档从 [docs/INDEX.md](docs/INDEX.md) 开始看。

## 许可证

[Apache License 2.0](LICENSE)：可以自由使用、修改和商用，分发时需要保留版权声明和 [NOTICE](NOTICE)。许可证不授予使用 REC 名称的权利。
