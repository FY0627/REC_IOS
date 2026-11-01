# 0007 iOS Swift 版数据库：系统 SQLite3 直连

- 状态：已采纳（`ios-swift/`）
- 日期：2026-10-24

## 背景

账本需要事务一致的去重入账、聚合统计和可控的迁移；自动化可能并发调用同一个 App Intent；
锁屏后台运行时要考虑数据保护。项目原则是不轻易引入第三方依赖。

## 备选方案

| 方案 | 优点 | 缺点 |
|---|---|---|
| **系统 SQLite3（`import SQLite3`）+ 自写薄封装** | iOS SDK 自带，零依赖；完整 SQL、UNIQUE 约束、`BEGIN IMMEDIATE`；行为在 Linux 测试环境可复现 | SQL、迁移、类型映射要手写 |
| GRDB.swift | 成熟、功能全 | 第三方依赖，需要锁版本和审计 |
| SwiftData / Core Data | 系统框架 | 去重和并发写语义不透明；跨进程/后台执行时的锁行为难以控制；不便在 Linux 上测试 |
| SQLite.swift | 类型安全 DSL | 第三方依赖，项目规模用不到 |

## 决定

使用系统 SQLite3，`BKDatabase` 提供约 200 行的封装：

- **并发**：一个连接 + 一个专用串行 `DispatchQueue`。所有 SQL 都通过 `Database.read/write` 在该队列执行，
  调用方即使在 MainActor 上也不会阻塞主线程。
- **事务**：写操作统一 `BEGIN IMMEDIATE … COMMIT`，抛错即 `ROLLBACK`，不会留下半条记录。
  多个连接（例如两个并发自动化各自打开连接）由 SQLite 文件锁 + `busy_timeout = 5s` 串行化。
- **去重**：`ingests.fingerprint` 与 `records.dedupe_key` 都是 `UNIQUE`，重复输入在数据库层被拒绝，而不只靠内存判断。
- **日志模式**：`journal_mode = WAL`、`synchronous = NORMAL`、`foreign_keys = ON`。
- **迁移**：版本号存 `PRAGMA user_version`；迁移只追加，每步在事务里执行；有迁移测试。
- **金额**：`INTEGER` 最小货币单位；时间：Unix 秒（REAL），只用于排序和展示，不参与账务运算。
- **数据保护**：数据库目录设置 `NSFileProtectionCompleteUntilFirstUserAuthentication`。
  设备首次解锁后，锁屏时后台入账仍可读写；开机后从未解锁时打开会失败，App Intent 抛出明确错误，不静默丢弃。
- **Linux 本地测试**：通过 `CSQLite` 系统库目标（仅 Linux 条件依赖）在 Docker 中跑同一套测试。

## 影响

- 新增表或字段必须写迁移并补 `DatabaseTests` 中的迁移测试。
- 不引入任何第三方 Swift 包；如以后需要（例如全文搜索），再写 ADR。
- 与 Flutter 版的 drift 数据库（ADR 0003）是两个独立的库，不共享文件。
