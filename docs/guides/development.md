# 开发指南

## 环境

- Flutter 3.47.6（stable），Dart 3.13.5。CI 固定使用这个版本，见 `.github/workflows/ci.yml`。
- Android SDK；iOS 开发需要 macOS + Xcode。

## 常用命令

```sh
flutter pub get                 # 在仓库根目录执行，一次解析全部包（pub workspace）
flutter analyze                 # 在仓库根目录执行
cd app && flutter test          # 前端测试
cd native && flutter test       # 原生插件的 Dart 侧测试
cd app && flutter devices       # 列出已连接的设备
cd app && flutter run -d <设备ID>
```

真机调试：手机开启 USB 调试并连接电脑，然后在 `app/` 目录下运行 `flutter run`。

## 分支

| 分支 | 用途 |
|---|---|
| `main` | 正式开发 |
| `prototype` | 前端原型，只作参考，不合并进 main。查看文件用 `git show prototype:<路径>` |

## 性能测量

1. 在测试机（2020 年 60Hz 手机）上用 profile 模式运行：`cd app && flutter run --profile`。
2. 打开 DevTools 的 Performance 页，录制目标操作，观察 UI 线程和 raster 线程每帧的耗时。
3. 在关键时刻用 `developer.Timeline.instantSync('<模块>.<事件>', arguments: {...})` 打标记，方便在时间线上定位。
4. 对照实验：
   - 把要比较的实现做成编译期开关：`const x = bool.fromEnvironment('FLAG', defaultValue: ...)`。
   - 用 `flutter run --profile --dart-define=FLAG=false` 跑对照组。
   - 每次只改一个开关，其余开关保持一致。
5. 录制得到的 DevTools JSON 不要提交（已在 `.gitignore` 中排除）。
6. 结论和数据记录到 [performance.md](../architecture/performance.md) 或对应的 ADR 中。
