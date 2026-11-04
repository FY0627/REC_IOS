# 0020 iOS Swift 版：加通知扩展，长按记账结果通知时大类、小类在一处选完

- 状态：已采纳（`ios-swift/`）；取代 [ADR 0017](0017-ios-swift-learned-categories.md) 里「记账结果通知」的按钮和「通知类别在发通知前注册」两部分
- 日期：2026-11-05

## 背景

用户刚开始用时没有记录可学：长按通知只有 3 个大类和「更多分类」，常常没有想要的；选了有小类的大类，还要等第二条通知、再长按一次才能选小类。用户要：

1. 刚开始能看到全部大类自己选，用久了常选的排在前面；
2. 选完大类马上选小类，不用等第二条通知。

系统最多给一条通知 4 个按钮（展开时），10 个大类一次放不下；按钮点完，App 自己不能在原来的通知上换一组。
只有通知内容扩展（Notification Content Extension）能在用户点了按钮之后当场换按钮（`extensionContext.notificationActions`，iOS 12 起）。

## 决定

**加一个通知内容扩展** `NotificationContent`（`ios-swift/NotificationContent/`，Bundle ID `com.example.bookkeepingApp.swift.NotificationContent`），只管换按钮：

- 记账结果通知的类别固定是 `ingest.pick`，扩展的 `Info.plist` 认这个类别（`Config/NotificationContent-Info.plist`）；App 启动时和发通知前注册它。
- App 发通知时把要显示的大类、小类和顺序写进 userInfo（`BKModel/NotificationPicker.swift`，JSON）。扩展不读账本，不需要 App Group，数据库不用挪。
- 按钮（一页 3 个选项，第 4 个翻页、返回或打开 App）：
  - 第一层：这个商户选过的分类（有的话，点了直接记），再是全部大类，常选的在前（这个商户选过的、最近 200 笔里用得多的），没用过的按分类顺序；「更多大类」翻页，最后一页是「打开 App」；
  - 点有小类的大类：当场换成它的小类，常选的在前，最后是「只记这个大类」；「更多」翻页，最后一页是「返回」；
  - 点到一个分类（`pick.分类`）：扩展把这次点击交回 App（`dismissAndForwardAction`），App 在后台保存，和原来点按钮一样，不打开 App、不用解锁。
- 刚开始没有记录时就是分类页的顺序，全部大类都能翻到；用久了常选的在第一页，要翻的就少了。
- 不再发「选小类」的第二条通知；一次就选到小类，学习时只记一次。
- 分类建议体检按这套按钮算「第一页就有」和「点几下」（`NotificationPicker.taps`）。

`NotificationPicker` 放在 `BKModel`（只用 Foundation），App、扩展和体检共用，在 Linux 上也能测。扩展只链接 `BKModel`。

## 没有选的

- **只用 App 自己的按钮**：最多 4 个，放不下全部大类；选了大类只能再发一条通知。
- **扩展里画一整格分类**：要能点自己的界面，选好之后还得把结果交回 App，只能借按钮或 App Group；换按钮已经够用，也最像系统的样子。
- **扩展直接写账本**：要 App Group，数据库挪到共享目录，免费签名下多一个限制，迁移也有风险。
- **继续每组候选注册一个类别（ADR 0017）**：扩展只认 Info.plist 里写死的类别，动态类别用不上扩展。

## 影响

- IPA 里多一个 `PlugIns/NotificationContent.appex`。iLoader 签名时要多签它，免费账号每周 10 个 App ID 的额度里多用一个。CI 的 `package-ipa.sh` 检查扩展在不在、Bundle ID、类别、构建号和架构。
- 扩展没起来时（没签上、被系统停用），通知只有「打开 App」，点了照样打开选分类面板。
- 单元测试覆盖不到扩展本身，要真机验证：长按通知看第一页、翻页、点大类换小类、点小类后流水有了分类。
