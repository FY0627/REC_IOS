# REC · iOS 原生 Swift 版

独立于 Flutter 的 iOS 版本（[ADR 0006](../docs/decisions/0006-ios-native-swift.md)）。只依赖用户自己的 iPhone：
账户、流水、解析规则和设置保存在本机 SQLite；没有服务器、云数据库、远程解析或账号系统。
App 不联网；净资产换算用的汇率由快捷指令下载后导入（[ADR 0011](../docs/decisions/0011-ios-swift-multi-currency-and-rates.md)）。

## 目录

```
ios-swift/
├── Bookkeeping.xcodeproj/         手写工程（objectVersion 77），含共享 scheme「Bookkeeping」
├── Config/                        Info.plist（App）、NotificationContent-Info.plist（通知扩展）
├── NotificationContent/           通知内容扩展：长按记账结果通知时换按钮选分类（ADR 0020，文件夹同步，只链接 BKModel）
├── Bookkeeping/                   App target（文件夹同步，新增 .swift 文件无需改工程）
│   ├── App/                       入口、共享服务 AppServices、界面状态 LedgerStore
│   ├── Intents/                   App Intent「记录银行动账通知」「记录付款截图」、AccountEntity、AppShortcuts
│   ├── UI/                        Shell（系统 TabView）、Home、Assets（卡包与已停用卡包、详情转场、卡片信息、卡面编辑、管理银行卡）、Stats、Profile、Pending
│   ├── Diagnostics/               单变量性能开关、帧率/内存指标、对齐参考线
│   ├── AppIcon*.icon/             App 图标和「我的 › 图标」里选的两个备用图标（Icon Composer 格式：分层、Liquid Glass，见下面「App 图标」）
│   └── Assets.xcassets
├── Packages/BKCore/               纯 Swift 业务核心（无 UI 依赖）
│   ├── Sources/BKModel/           值类型：账户、流水、金额（整数最小单位）
│   ├── Sources/BKDatabase/        SQLite3 封装、迁移、DAO
│   ├── Sources/BKBackend/         解析、匹配、去重、入账、统计（LedgerBackend）
│   └── Tests/                     单元测试（脱敏构造样例）
└── ci/                            GitHub Actions 调用的脚本
```

依赖方向：`App → BKBackend → BKDatabase → BKModel`，App 不 import `BKDatabase`（CI 检查）。

## 构建（GitHub Actions）

工作流 [`.github/workflows/ios-swift-build.yml`](../.github/workflows/ios-swift-build.yml) 在 `xcode-27` runner 上：

1. 打印并校验工具链（Xcode、Swift、iOS SDK、部署目标 ≤ iOS 27.0.1）；
2. `swift test`（macOS 主机）运行 BKCore 测试；这次推送没改 BKCore、测试脚本和工作流（只改 App 界面）时跳过（[`ci/changes.sh`](ci/changes.sh)）。
   iOS 模拟器上那一遍（`xcodebuild test`）最慢，只有手动触发时勾选「simulator_tests」才跑。模拟器按目标设备选择：优先 iPhone 16 Pro，其次其他 iPhone Pro，不使用双屏机型（[`ci/pick-simulator.sh`](ci/pick-simulator.sh)）；
   App 图标没改时不渲染图标预览（第 6 步）。不加缓存：没有第三方依赖可缓存，Xcode 和 SwiftPM 按文件修改时间判断要不要重编，每次检出的文件都是新的，缓存了也会全部重编；
3. 构建 Release / iphoneos / arm64、不签名的 `Bookkeeping.app`；
4. 校验可执行文件、Mach-O 平台、Info.plist、依赖、资源、App Intents 元数据和通知扩展 `PlugIns/NotificationContent.appex`，打包为 `Payload/Bookkeeping.app` 的 IPA；
5. 上传 IPA（含 SHA-256 与 build-info）和诊断产物；
6. 检查 App 图标和两个备用图标编进了 App，用 Xcode 自带的 `ictool` 按默认、深色、着色渲染预览（[`ci/icon-preview.sh`](ci/icon-preview.sh)，
   预览图在诊断产物里，32×32 缩略图在运行页面的注释里），不影响打包。

推送 `ios-swift` 分支或在 Actions 页面手动运行（可选指定 Xcode 路径）。

上传到 TestFlight 是另一个工作流 [`.github/workflows/ios-swift-testflight.yml`](../.github/workflows/ios-swift-testflight.yml)，只能手动运行：
用 App Store Connect API 密钥自动签名、归档，直接上传（[`ci/archive-upload.sh`](ci/archive-upload.sh)，ADR 0023）。

## 本地（Windows）运行核心测试

没有 Mac 也可以用 Docker 在 Linux 上跑 `BKCore` 的全部测试（SwiftUI 部分只能在 CI 编译）：

```sh
# 一次性：带 SQLite 头文件的 Swift 镜像
printf 'FROM swift:latest\nRUN apt-get update && apt-get install -y libsqlite3-dev\n' | docker build -t bk-swift -
# 运行测试（PowerShell / Git Bash 均可，路径换成你的仓库位置）
docker run --rm -v "<仓库>/ios-swift/Packages/BKCore:/pkg" -w /pkg bk-swift swift test
```

## 卡包与详情转场

和 Apple 钱包一样用 UIKit + Core Animation（[ADR 0012](../docs/decisions/0012-ios-swift-wallet-core-animation.md)）：
动画交给系统渲染进程播放，主线程读流水、生成列表行都不影响。选中卡上面的卡缩小收到它后面，下面的卡向下落出屏幕，
详情内容从屏幕底下整块升起；返回时内容整块退到屏幕底下。

- `UI/Assets/WalletController.swift`：卡包、卡片位置和转场、手势。每张卡一个视图，在两个滚动区上层按滚动距离摆放；
  打开 / 关闭时改模型位置并加叠加动画，动画途中滚动、再点都从当前位置平滑转向。状态栏高度从窗口读取。
- `UI/Assets/WalletDetailList.swift`：详情列表（`UITableView`，用系统的滑动按钮）。余额区 `AccountDetailSummary`
  和每行流水仍由 SwiftUI 画，放在关掉安全区的 `UIHostingController` 里；行高事先量好，不做自适应高度。
- `UI/Assets/CardMotion.swift`：弹簧和曲线参数（与 SwiftUI 的 `spring(response:dampingFraction:)` 换算一致），
  收到后面的卡的缩放比例 `behindScale`。卡片不做 3D 倾斜（会让卡片之间的上下层错乱）。
- `UI/Assets/WalletTopBar.swift`：顶部按钮，UIKit 液态玻璃（同一个玻璃容器里的三块玻璃，共用部分在 `UI/Common/GlassControls.swift`）。
  卡包里「+」和「更多」合成一个胶囊；打开详情时「+」那一半像水滴一样分出来、冲过一点再弹回，变成选时间段的胶囊，左边凝结出返回按钮；
  返回时沿原路并回去，并好后整个胶囊鼓一下再弹回。移动途中两块玻璃之间拉出水滴一样的细颈，停下时正好断开（融合距离和停下的间距差不多大）。
- 屏幕外的卡隐藏起来不画；打开 / 关闭详情时只有起点或终点在屏幕上的卡做动画（`WalletController.cullCards`）。
- `UI/Assets/AssetsView.swift`：SwiftUI 外壳，标签栏显隐、弹出页面、标题区和净资产卡。
- 卡面仍是 SwiftUI 的 `WalletCardView`，阴影只画在一个圆角矩形上；转场时卡面不重新计算，只是整张移动。

## 多币种与汇率

- 账户有一个主币种，多币种账户另有其他币种；余额按「卡 × 币种」分别推算，流水始终是原币种。
  卡包里的卡都换算成主要币种显示（≈，多币种的卡是合计），打开详情显示原币种、正在看的币种的余额（[ADR 0018](../docs/decisions/0018-ios-swift-charge-currency-and-converted-cards.md)）。
- 卡里没有的币种的交易按主币种扣款，计入主币种余额：用户在流水编辑里填的实际扣款优先，
  否则按交易当天的汇率估算（那天没有用记录当天的，再没有用最近的一天；`BKBackend/ChargeCalculator.swift`，[ADR 0013](../docs/decisions/0013-ios-swift-record-editing-and-foreign-charges.md)）。
- 多币种账户这个币种的可用余额不够这笔消费时，整笔从主币种扣（恒生的规则）；扣款币种存在流水上，记一笔、编辑时可以改
  （`LedgerRecord.chargeCurrency`，[ADR 0018](../docs/decisions/0018-ios-swift-charge-currency-and-converted-cards.md)）。
- 币种从汇率数据源支持的全部 160 多个币种里选（`UI/Common/CurrencyPicker.swift`，按拼音首字母分组、侧边 A–Z 索引，搜索框在最下面）。
- 「我的 › 记账 › 主要币种」选择主要币种；有汇率时资产页净资产按主要币种换算合计（`App/ExchangeRateStore.swift`）。
- 汇率来源：共享的快捷指令「导入汇率」（「获取 URL 内容」→ App 动作「导入汇率」，`Intents/ImportExchangeRatesIntent.swift`），
  「我的 › 记账 › 汇率」点「添加快捷指令」打开 iCloud 链接添加，用户再建一个「打开 REC 时」运行它的自动化（`UI/Profile/ExchangeRateGuideView.swift`）。
  链接只认做链接时那个 App 的标识（含签名团队后缀）；别人自己侧载的 App 标识不同，页面改成自己搭的 4 步。
  导入成功后发一条本机通知（没有通知权限就不发；设置说明里点按钮离开 App 前先要权限）。
  数据源每天更新一次，在 UTC 0 点刚过（北京时间早上 8 点左右）。
  完整的汇率表原样保存：最新一份在本机缓存，另外按天存进账本（`RateDAO`），以前的日期都保留。

## 流水

参考 MOZE 的基础记账（[ADR 0014](../docs/decisions/0014-ios-swift-entry-types-and-categories.md)）：只看支出 / 收入 / 转帐三种类型，每笔有分类和备注。

- 首页一笔钱只占一行：转帐两边合成「招行 → 工行」，同一条通知拆出的手续费写在那一笔下面，合成的一单只占一行；失败、冻结只在卡片详情里。
  标题按「备注 → 交易对方 → 分类名」，图标是分类图标（`UI/Common/{RecordRowView,RecordDisplay}.swift`）。
  首页按收到那天分组，每一笔只写时间（`Fmt.recordClock`）；通知写的交易日期不是那天时才写上日期。完整时间在流水详情里。
- 分类在「我的 › 分类」里自己管（`UI/Profile/CategoryManagerView.swift`），选分类的格子在 `UI/Common/CategoryGrid.swift`
  （放在列表的分组里：点有小类的大类先选上它，小类在下一行展开，分组的框往下变大，大类那一行不动；只会有一个选中）。
  自动记账把手续费、扣息、工资、利息和退款归类；同一个商户连续 3 次选同一个分类后，下一笔自动归类，标题旁写「自动」
  （在本机学习，[ADR 0017](../docs/decisions/0017-ios-swift-learned-categories.md)）。
  其余是「待分类」，流水行的标题旁标着「待分类」，点这一笔直接选分类、点「确定」（「待处理」里也列着）：最可能的几个分类排在面板上面，这个商户选过的预先选好。
  记账结果通知选「全部」时，通知上也能直接选分类，不用打开 App。
- 首页右上角「+」手动记一笔（`UI/Home/AddRecordView.swift`）：现金、电子钱包，或通知还没接上的消费。
  先选币种（任何一种，默认主要币种；选币种页面和添加账户时一样，最上面先列自己的账户里有的币种）再选账户；账户没有这个币种时按它的主币种扣款（入账），
  空着按当天汇率估算（提示大概多少），银行实际扣了多少可以直接填。编辑流水也一样。
  转帐还要选到账的币种、填到账多少（`UI/Common/TransferSideFields.swift`）：币种相同时空着就是一样多，币种不同必须填；
  多币种账户可以转给自己的另一个币种（换汇）。到账比转出少的部分只体现在余额上，不算支出，首页写「HK$100.00 → ¥91.00」。
- 首页最上面的本月支出、本月收入、结余换算成「我的」里选的主要币种（外币交易有实际扣款用实际扣款，否则按当天汇率；
  没有汇率的币种不算进去，下面写一行小字）。
- 流水详情里分类只显示（改分类在「编辑」里），备注直接写；一单用了几张卡时可以「合并」成一单，「拆开」时选拆出去哪几笔。
  「合并」里换到「转帐」：一笔支出和另一个账户的一笔收入（微信提现到银行卡）合成转帐，不算收支，「拆开」回到原来的两笔。
  「合并」「拆开」「删除」只有文字、靠左（`ActionLabel`，分类管理里的删除也一样）。
- 流水详情右上角「编辑」（`UI/Common/RecordEditor.swift`）：支出 / 收入 / 转帐、退款、金额、币种、分类、账户、交易对方、时间、备注、实际扣款；
  转帐还能选另一边是哪个账户和到账多少（那边有对得上的一笔就配成一对，没有就补记一笔；手动补记的那笔跟着这一笔改）。
  来源和通知原文不能改。只在详情最下面删除（首页不能左滑删除），点了在按钮旁边弹出小菜单确认；
  收到它的那条通知仍记着，再来也不会重新记上。首页金额太长时缩小一点，不换行。余额从校准余额那一刻算起，比它早的流水换账户不影响余额（编辑页会写明）。
- 首页搜索（`UI/Home/HomeTopBar.swift`，和资产页顶部按钮同一种 UIKit 液态玻璃，共用 `UI/Common/GlassControls.swift`）：
  标题右边是「+」（记一笔）和圆形搜索按钮，点搜索后「+」先像水滴一样并进圆里，搜索框紧接着从圆里向左分出来，
  标题的位置再分出「全部 / 支出 / 收入 / 转帐」的下拉按钮，圆留在原地变成关闭按钮；关闭时把展开动画倒过来播放，
  快缩完时「+」从圆里分出来、冲过一点再弹回。圆不用系统的交互玻璃（按住时它浮在上层、不和分出来的玻璃融合），按下的反馈自己做；
  列表滚到标题行下面时垫一层磨砂背景（`UI/Common/TitleBar.swift` 的 `TopBarBackdrop`，搜索展开时也一直在）；
  交易对方、备注、分类、账户、银行、尾号、类型、金额都能搜（空格分开的几个词都要对上）。金额是模糊的：只写整数时找差不多的，
  上下差 10%、至少差 1（38 找 34.20～41.80），按主币种的实际扣款也算；写了小数的按原样找（`RecordDAO.amountRanges`）。
  下拉按钮选支出 / 收入 / 转帐时不用打字也只列这一类，选全部就是全部；收起搜索回到全部。
  查过的条件记住结果（`HomeView` 的 `cache`，按数据版本作废），来回切换类型不重新查；只换类型时先从已有的结果里挑出这一类显示，
  查回来再换成完整的。只有打字时停一下再查。首页不用系统导航栏，标题和按钮在同一行，和资产页一样；不做下拉刷新。
- 卡片详情：多币种的卡按币种分开看流水（币种在「交易记录」旁边选），时间段在右上角的胶囊里选；余额在卡片上，校准余额在卡片信息里。
- 统计（`UI/Stats/StatsView.swift`）：右上角两个胶囊，右边选看哪段时间（和卡片详情一样），默认本周（本月的首页上有）；
  左边选看哪些数据（记住上次选的）：全部账户、一个账户（包括停用的）或一个币种。三种一个样子：上面是支出、收入、结余
  （`UI/Common/ConvertedTotalsView.swift`），下面是支出分类、收入分类（点进去看小类和每一笔）。
  全部账户换算成主要币种（和首页的本月合计一样算，分类也按换算后的金额，`StatsCalculator.converted`）；
  一个账户、一个币种不换算，账户用了几个币种就分开几组（`LedgerBackend.stats(accountID:)`）。转帐不算收支。
  标题「统计」和两个胶囊在同一行，和资产页一样高（`UI/Common/TitleBar.swift`，放不下时左边的胶囊截断）。
- 「我的」的标题行也和资产页一样高，滚动时的磨砂背景和首页一样。推进二级页面时标签栏滑出、回来时滑入（`ProfileView` 外层管标签栏，列表和导航栈在 `ProfileList`）。系统导航栏在「我的」首屏也留着、里面是空的，首屏不让出它的位置（`ignoresSafeArea`），从屏幕顶端排：藏起来的话，从二级页面返回时系统要把导航栏收走，顶上的东西会往中间收再往上消失。列表和首页、统计是同一种（`.insetGrouped`），第一个白框和灰字自然一样；资产页不是系统列表，位置跟着首页排（`FirstBoxLayout`）。
- 「我的」分组，常用的在前、设一次的在后：自动记账（设置自动记账、设置截图记账、识别模板、记账结果通知）、记账（分类、主要币种、汇率和更新时间、导入汇率通知）、数据（导出、导入、原始通知保留天数）、显示（外观、图标、主题色、语言：跟随系统、简体中文、繁體中文、English，ADR 0022）、关于（使用说明、版本、汇率数据源链接）、开发与调试（分类建议体检、模拟消费、性能开关；平时藏着，连点 7 次版本号在最下面显示，再连点 7 次藏起来）。
- **导出数据、导入数据**（[ADR 0019](../docs/decisions/0019-ios-swift-export-and-import.md)；`UI/Profile/{DataExportView,DataImportView}.swift`，`BKBackend/{DataExport,BackupImport,ZipStore}.swift`）：
  导出打开就生成一个 zip，点一下用分享菜单存到「文件」或发出去。里面每种数据一个 CSV——流水、账户（含完整卡号、账号）、余额（每个币种的初始余额、推算余额、冻结、可用）、分类、学到的分类、识别模板、汇率、待处理、原始通知（含原文）、通知里的余额——和一份完整的数据库副本（导入用）。卡面图片不导出。CSV 金额按币种小数位、不加千位分隔，流水流入为正、流出为负；开头带 BOM 让 Excel 认出中文；几个文件之间用编号对上。
  导入选这个 zip，先看里面有几笔流水、几个账户，再选增量（现在的数据不动，只加没有的；同一张卡、同一条通知不重复）或覆盖（在按钮弹出的小菜单里再点一下）。导入前自动存一份现在的数据，可以撤销上次导入。
- **主题色**（`ThemeColor`，`UI/Theme/AppTheme.swift`；弹窗 `UI/Profile/ThemeColorSheet.swift`）：点「显示 › 主题色」弹出和记一笔一样的弹窗，点现成的色块（每块是它自己的颜色），或者用系统色盘（`ColorPicker`）自己调，存成 `#RRGGBB`。选的时候只有弹窗里跟着变，右上角确定才换到整个 App，取消不变。根视图 `.tint`，UIKit 部分跟窗口的 `tintColor`；代码里用 `.tint`，不写 `Color.accentColor`。流水里进账的金额也用主题色。菜单样式的选择行（外观、图标等）右边的文字换了主题色不会马上重画，这几行按主题色重建（`.id`）；`themeColor` 在「我的」里比 App 那层的 `.tint` 先变，所以列表上自己也 `.tint` 一次，否则重建时拿到的是上一个颜色。
- 选币种页面的搜索框在最下面（`UI/Common/GlassSearchBar.swift`）：点进去时关闭按钮像水滴一样从搜索框里分出来，退出时并回去（`GlassEffectContainer` + `glassEffectID`）。列表不跟着键盘变矮（收起键盘时搜索框后面不会露出一块）。

## 卡片信息与卡面

- **添加银行卡**：银行直接输入，按输入列出对得上的银行全称（`BKModel/BankCatalog.swift`，约 180 家，中英文、繁体、拼音首字母、
  日文、韩文都能搜），列表里没有的用输入的名称；每个币种的初始余额紧跟在选好的币种下面（下拉选余额或欠款，再填金额；不填从 0 开始）。
  点输入框以外的地方收起键盘（整个 App 都是，`UI/Common/KeyboardDismissal.swift`），键盘上方不加按钮。
  卡面先问「用自己的照片」（默认不用）：不用就列出配色；用就从相册选一张，保存账户后换上（和卡面编辑同一套裁剪、存图）。
- **现金、电子钱包**：添加账户时选「现金」或「电子钱包」，只填名称、币种和初始余额。没有卡号（尾号存占位 `0000`），不参与尾号匹配。
  现金用「记一笔」手动记；电子钱包选了是哪个钱包（支付宝、微信支付……），它发来的、没写银行卡号的通知自动记到这里，
  同一个钱包有几个账户时进待处理让你选。
- **卡片信息**：左上角返回；右上角「编辑」，编辑时换成勾（保存），这时返回是回到查看、不保存。
- **卡片信息 › 编辑**：账户名称、卡类型、主币种、其他币种、各币种的校准余额（就是初始余额：余额对不上时填现在实际有多少）、卡号、账号；
  银行和尾号不能改。校准余额的输入框空着，原来的金额灰色显示在框里，不填就不变。
- **卡号**：自动记账只用后四位匹配。完整卡号是选填的，在卡片详情 › 卡片信息里填写，只保存在本机 SQLite，默认遮住显示。
- **卡面图片**：选图时用 ImageIO 一次性按卡片比例居中裁剪、缩小到卡片的屏幕像素（最大 1200px 宽）存成 JPEG，
  放在 `Application Support/Ledger/CardFaces/`，数据库只存文件标识。显示时后台画成卡片屏幕像素大小、带圆角的位图并缓存（`CardFaceImages`），
  卡面不再加圆角遮罩，卡包滚动和详情转场只绘制这张位图。金额和描边也合成一张小位图。换图、移除或取消编辑时删除不再使用的文件。
  用图片时卡面上只有金额（默认白字黑边、在右上角），编辑页不显示配色；编辑页的卡片固定在最上面，改金额颜色、描边颜色、大小时实时看到变化。
  金额位置可以在卡片上拖动，或用滑杆微调，按比例保存（0–1），金额变长、屏幕大小不同都不会跑出卡片（迁移 10）。
- **停用**：卡片信息里，或资产页「更多 › 管理银行卡」里停用（`accounts.archived`）。停用的卡不参与自动记账匹配和净资产，
  流水保留，在资产页最下方以灰色卡包显示，可以点开详情，也可以重新启用。
- **删除**：只有停用的卡能删除（卡片信息最下面，确认后删除，不能恢复）。只做标记（`accounts.deleted_at`，`AccountDAO.markDeleted`）：
  卡不再出现在资产页、账户列表、净资产和自动记账里，卡面图片删除；**流水都留着**，首页、详情、统计里账户名称后面写「（已删除）」，
  转帐两边照样配对。通知的指纹保留，同一条通知再来不会重新记上；同银行同尾号的卡可以重新添加，之后的通知记到新卡上。
- **排序**：「管理银行卡」里按住一行上下拖动，用系统列表的 `.onMove`（不用进编辑模式）：按住的行浮在上层，其他行自动让开、补位。
  顺序存在 `accounts.sort_order`，资产页的卡包跟着变，新卡排在最后。拖动的回调里要同步改好界面上的顺序（`LedgerStore.reorderAccounts`），否则松手时行会先弹回去再跳过来。
- **滑动操作流水**：首页、搜索结果、统计的明细、卡片详情都是左滑露出「编辑」「删除」两个系统的滑动按钮，删除要在系统的下拉菜单里再确认一次（`UI/Common/RecordSwipe.swift`）。
  卡片详情里右滑仍是返回卡包。转帐在首页合成一行，但删除只删这一笔，所以确认时写明另一边还留着。
- 再点一次标签栏的「资产」，卡包滚回顶部：卡包是 UIKit 的滚动区，系统不会替它滚，由 `RootView` 记下再点一次，交给 `WalletController`。

## App 图标

`Bookkeeping/AppIcon.icon` 是 Icon Composer 格式的分层图标（iOS 26 起的 Liquid Glass 图标），替代原来资源目录里的 `AppIcon.appiconset`；
构建设置 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` 对应它的文件名。按苹果的做法准备：

- 画布 1024×1024，每种颜色一个 SVG 图层（`Assets/`，编号从后往前），图层里不带背景、阴影、透明度和圆角遮罩；
  背景色、深色和着色外观的颜色写在 `icon.json` 的 `fill-specializations` 里，高光、阴影、半透明和裁切由系统按 Liquid Glass 画。
- 三组：最后面是背景上三横三竖的网格线（不做玻璃、没有阴影），中间是小票（纸和分隔线），
  前面是票面元素（¥、标题条、三个分类色块、三条横线、对勾）。`icon.json` 里排在前面的组和图层在上层。
- 图形和颜色取自设计稿（Apple 蓝单色玻璃 + 柔和的网格，线宽 5.2）的白天、晚上、色调三版。设计稿里小票 88% 不透明，
  所以小票组的半透明设成 12%，透出一点后面的网格；分隔线在设计稿里以 78% 叠在纸上，这里直接写成混合后的颜色。
  色调版里 ¥ 和对勾、分类块、标题条的灰度不同，所以分成不同图层。
- 没有 Mac 也能看效果：CI 用 Xcode 自带的 `ictool` 渲染各个外观（见上面「构建」第 6 步）。

### 自己选图标

系统只能让所有 App 的图标一起变深色。「我的 › 图标」和界面的「外观」分开选；选浅色或深色时，App 用 `setAlternateIconName`
换成备用图标，这样可以只让这个 App 的图标变深色（或保持浅色），其他 App 不受影响：

| 「我的 › 图标」 | 桌面图标 |
|---|---|
| 跟随系统 | `AppIcon`：白天浅色、晚上深色，跟系统一起变 |
| 浅色 | `AppIconLight`：深色外观也用浅色的颜色 |
| 深色 | `AppIconDark`：默认外观也用深色的颜色 |

- 三个 `.icon` 的图层一样，只有 `icon.json` 里的颜色不同；改图形或颜色时三个一起改。着色外观三个都一样。
- 构建设置 `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = "AppIconLight AppIconDark"` 让 actool 把两个备用图标编进去，
  写进 Info.plist 的 `CFBundleAlternateIcons`（CI 第 6 步检查）。
- 每次换图标系统都会弹一个「已更改图标」的提示，这是系统行为，去不掉；所以图标已经对了就不再调用。
  跟随系统时系统自己换主图标的深浅，不弹提示。重装后系统可能换回主图标，打开 App 时按选的再换一次；
  还没选过（从图标跟着外观换的版本升上来）就记下现在的图标，不去动它（`AppearanceMode.applyIcon`）。

## 安装到 iPhone

用 TestFlight 安装（ADR 0023）；不用付费账号时见 [Windows + iLoader 安装指南](../docs/guides/ios-swift-windows-iloader.md)。验收见 [真机验收清单](../docs/guides/ios-swift-device-checklist.md)。

## 自动记账

见 [features/ios-swift-auto-bookkeeping.md](../docs/features/ios-swift-auto-bookkeeping.md)。
