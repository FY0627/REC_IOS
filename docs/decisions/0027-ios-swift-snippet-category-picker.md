# 0027 iOS Swift 版：摘要卡片上选分类（和灵动岛对比）

- 状态：试用中（`ios-swift/`），和 [ADR 0024](0024-ios-swift-dynamic-island-category-picker.md) 的灵动岛对比，用户看哪种好
- 日期：2026-11-14

## 背景

灵动岛上选分类（ADR 0024）有两件事 App 管不了：App 不在前台时新开启的岛，系统有时自己先展开几秒；系统展开的、提醒展开的，几秒后不管有没有在点都会收回。
用户想要「截完图直接弹出有分类的那种，不要收起来」，并指定用 Apple 的摘要卡片（[HIG：摘要卡片](https://developer.apple.com/cn/design/human-interface-guidelines/snippets)）。

摘要卡片是用户经快捷指令、Siri、聚焦运行动作时，系统在屏幕上方弹出的紧凑视图，分确认和结果两种。iOS 26 起可以交互：卡片上的按钮运行 App 的动作，
系统接着重新运行卡片的 `SnippetIntent` 换上新的样子；卡片一直在，用户点了才收起（[Displaying static and interactive snippets](https://developer.apple.com/documentation/appintents/displaying-static-and-interactive-snippets)）。

## 决定

**开关**（「我的 › 自动记账」，记账结果选「全部」时出现）：「灵动岛选分类」（只在有灵动岛的手机上出现，默认开）和「摘要卡片选分类」（默认关）只开一个，
打开一个另一个自动关；都关时在通知上选（ADR 0020）。关掉灵动岛时岛上正在选的也收起，留在待分类。

**怎么弹**：记账动作（「记录银行动账通知」「记录付款截图」）记上没分类的支出或收入（和灵动岛同样的条件，`LiveCategoryActivity.eligible`），
这一笔不发记账结果通知，动作返回前用 `requestConfirmation(actionName:dialog:showDialogAsPrompt:snippetIntent:)` 弹卡片。
结果卡片（`.result(snippetIntent:)`）要求动作的返回类型固定带卡片，不能只在开关打开时弹，所以用确认卡片：开关关着时动作和以前完全一样，返回值也不变。
确认卡片下面是系统的两个按钮，写成「完成」「稍后」；没选分类时两个一样，这一笔留在待分类。

**卡片上**（`Bookkeeping/UI/Snippet/CategorySnippetView.swift`）：顶上第 1 页商户、账户和金额，第 2、3 页返回和标题；下面和灵动岛一样的三页按钮（`LiveCategoryPicker`），
一行 5 个，分类是主题色的圆，「全部」「更多」是灰色的圆；每页都占两行高，换页时卡片不变高。底是系统给的，跟着浅色、深色。
点分类马上写进账本（`PickSnippetCategoryIntent`），卡片上换成选中的分类；换页（`ShowSnippetPageIntent`）只改内存里的页。
卡片在的时候系统让 App 留在后台、内存不清，所以页和选中的分类放在内存里（`CategorySnippetStore`）；万一没有了，按账本重新算第 1 页。

**几笔、没弹出来**：一次记了几笔要选的，一张一张弹；点「稍后」后面的不再弹，留在待分类。
`requestConfirmation` 不到 1 秒就返回错误时当作没弹出来（人点不了这么快），这一笔和后面的照常发记账结果通知。
「开发与调试 › 摘要卡片」写上次的结果（完成、稍后、没弹出来和错误）。

## 还不知道（真机验收清单 B14–B17）

- 自动化（信息、App 通知触发、锁屏时）里能不能弹，还是只有轻点背面这种用户自己运行的快捷指令能弹；
- 卡片在的时候快捷指令一直在运行，屏幕上会不会一直有快捷指令的运行标志；
- 卡片上的按钮在 App 被系统挂起后还有没有反应。

## 影响

- 新文件：`Bookkeeping/App/CategorySnippet.swift`（弹卡片、`CategorySnippetStore`）、`Bookkeeping/Intents/CategorySnippetIntent.swift`（卡片和两个按钮的动作）、
  `Bookkeeping/UI/Snippet/CategorySnippetView.swift`；`IngestNotifier.post` 返回要在卡片上选的几笔，`IngestNotifier.send` 拆出来发一笔的通知。
- `package-ipa.sh` 检查三个动作在 App Intents 元数据里。
- 对比完留下一种：留摘要卡片就把灵动岛的开关默认关或者去掉，反过来就删掉这份的代码。
