# 架构总览

## 定位

- **本地优先、没有服务器**：手机上的数据就是主数据，离线可以完整使用，用户不需要部署任何东西。见 [ADR 0001](../decisions/0001-local-first-no-server.md)。
- **只支持 Android + iOS**，用一套 Flutter 代码实现。
- **低端机优先**：2020 年左右的 60Hz 手机要能流畅运行。见 [performance.md](performance.md)。

## 分层

没有服务器，**不等于没有后端**。前端、后端、数据库三层都有，只是后端作为 App 内部的一层运行在手机里。另外，自动记账的采集部分必须用平台原生代码实现，所以再单独加一层原生能力层。

| 层 | 目录 / 包 | 职责 | 允许依赖 |
|---|---|---|---|
| 前端 | `app/` · `bookkeeping_app` | 界面、交互、动画；不包含业务规则 | `bk_backend`、`bk_native`、Flutter |
| 后端 | `backend/` · `bk_backend` | 记账 / 资产 / 统计服务、同步、自动记账文本解析 | `bk_database`、纯 Dart 包 |
| 数据库 | `database/` · `bk_database` | 表结构、DAO、迁移（SQLite + drift） | 纯 Dart 包 |
| 原生能力 | `native/` · `bk_native` | Android：悬浮窗 → 截屏 → OCR；iOS：App Intent 接收快捷指令传来的文本 | Flutter 插件接口 |

```
app ──▶ backend ──▶ database
 │
 └────▶ native        （native 只产出 OCR 文本，解析交给 backend）
```

- 依赖方向是单向的，禁止反向依赖，也禁止跨层访问（例如 `app` 直接使用 `bk_database`）。
- `backend` 和 `database` 保持纯 Dart，可以脱离 Flutter 做单元测试。
- 后端技术栈的选型理由见 [ADR 0002](../decisions/0002-backend-dart.md)。

## 线程模型

| 工作 | 运行在哪里 |
|---|---|
| 构建界面、动画、手势 | UI isolate（每帧不能超过 16.6ms） |
| 数据库读写 | 后台 isolate（drift `NativeDatabase.createInBackground`） |
| 统计汇总 | SQL 聚合，在数据库所在的 isolate 中完成 |
| 同步合并、OCR 文本解析、导入 | `Isolate.run` |
| 截屏、OCR | 原生线程（native 层） |

## 目录约定

- `app/lib/features/<功能>/`：一个功能一个文件夹，放该功能的页面、组件和状态。功能之间不互相 import，共享的东西放进 `app/lib/shared/`。
- `backend/lib/src/<领域>/`：一个领域一个文件夹，放服务和领域模型。只有 `lib/bk_backend.dart` 对外导出。
- `database/lib/src/`：按 `tables/`、`daos/`、`migrations/` 划分。只有 `lib/bk_database.dart` 对外导出。
- `native/lib/`：只放 Dart 接口和数据结构；平台实现分别放在 `native/android/` 和 `native/ios/`。

## 数据模型的共同约定

为了支持多端同步，每张业务表都要包含以下字段。细节见 [features/sync.md](../features/sync.md)。

- `id`：UUIDv7（多台设备各自生成也不会冲突）
- `hlc`：混合逻辑时钟时间戳（Hybrid Logical Clock），用来决定谁的修改更新
- `device_id`：最后修改这一行的设备
- `deleted`：删除标记（tombstone），删除时只打标记，不物理删除
