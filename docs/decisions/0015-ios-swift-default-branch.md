# 0015 `ios-swift` 作为默认分支，Flutter 骨架留在 `main`

- 状态：已采纳
- 日期：2026-10-31

## 背景

实际开发都在 iOS 原生 Swift 版（[ADR 0006](0006-ios-native-swift.md)）上进行。`app/`、`backend/`、`database/`、`native/` 还是没有业务代码的
Flutter 骨架：四个目录的 `lib/` 合计 68 行 Dart，另有 15 个只放 `.gitkeep` 的占位目录，`ios-swift/` 也不依赖它们。

## 决定

- 仓库默认分支从 `main` 改为 `ios-swift`。
- `ios-swift` 分支删除 `app/`、`backend/`、`database/`、`native/`，以及只为它们服务的 `pubspec.yaml`、`pubspec.lock`、`.github/workflows/ci.yml`。
- `main` 不变，继续保存 Flutter 骨架。

## 影响

- 需要 Flutter 骨架时从 `main` 取。`ci.yml` 本来就只在 `main` 上触发，`ios-swift` 的构建不受影响。
- 把 `ios-swift` 合并进 `main` 会删掉 Flutter 骨架。
- Flutter 版的文档和 ADR 0002–0005 留在 `docs/`，里面的代码路径指的是 `main` 分支。
