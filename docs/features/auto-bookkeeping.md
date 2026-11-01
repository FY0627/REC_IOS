# 自动记账：截图 + OCR

选型理由见 [ADR 0005](../decisions/0005-auto-bookkeeping-screenshot-ocr.md)。

## 流水线

```
截图 ─▶ OCR ─▶ 文本 ─▶ 规则解析 ─▶ 账单候选 ─▶ 去重 ─▶ 用户确认 / 自动入账
└──── native/（平台各自实现）────┘  └──── backend/lib/src/auto_entry/（两端共用）────┘
```

native 层只输出「识别出的文本 + 来源信息」，解析和记账都由 backend 负责。

## Android：点击悬浮窗 → 截屏 → OCR → 记账

代码位置：`native/android/`（Kotlin），Dart 接口在 `native/lib/`。

- **悬浮窗**：平时收在屏幕侧边，需要时点出来。需要「显示在其他应用上层」权限。
- **常驻**：前台服务，类型为 `mediaProjection`。
- **截屏**：使用 MediaProjection，首次启用时由用户授权一次屏幕录制。
  - Android 14 起，每次授权只能创建一次 VirtualDisplay。所以授权后让 VirtualDisplay 常驻：空闲时调用 `VirtualDisplay.setSurface(null)` 暂停渲染；点击悬浮窗时再挂上 ImageReader 抓一帧，抓完立即卸下。
  - 这样每次点击都不用重新弹授权框，空闲时也几乎不耗电、不占 GPU。
  - 截屏前先隐藏悬浮窗，避免它遮挡内容。
- **OCR**：先用 ML Kit 中文识别（模型打包进 App），封装成接口，以后可以替换为 PaddleOCR。
- 截图只在内存中处理，识别完就丢弃，不保存到相册或磁盘。

## iOS：快捷指令完成截图 → OCR → 交给 App 记账

代码位置：`native/ios/`（Swift）。

- 快捷指令依次执行：「截屏」→「从图像中提取文本」（系统 OCR）→ 调用 App 提供的 App Intent，把文本作为参数传进来。
- 触发方式：轻点背面，或者操作按钮。
- 通过 `AppShortcutsProvider` 让 App Intent 自动出现在「快捷指令」App 里；同时提供一份图文引导，教用户配置。
- App 内不需要 OCR 模型。

## 规则解析（backend）

- 按来源分别写模板：微信支付、支付宝、各家银行。每个模板负责识别特征文本，并提取金额、商户、时间、支付方式。
- 输出账单候选，带置信度。置信度低时必须由用户确认。
- **去重**：同一笔交易可能被截图多次，按「金额 + 时间窗口 + 商户」判断是否重复。
- 解析放在 `Isolate.run` 中执行；每个模板都要有对应的测试样例（脱敏后的 OCR 文本）。

## 待真机验证

- 2020 年机型上的 OCR 耗时（目标是点击后 1 秒内出结果）
- 在没有 GMS 的机型上，ML Kit 打包模型能否正常工作
- 各厂商系统是否会杀掉前台服务，以及悬浮窗权限的引导流程
- iOS 快捷指令截屏时，能否截到目标 App 的画面
