# 性能规范

## 目标

- **测试机**：2020 年购买的 60Hz 手机。
- **帧预算**：每帧 16.6ms。UI 线程和 raster 线程都要在这个时间内完成。
- 原型的经验表明，**主要瓶颈在前端渲染（raster 线程）**，不在业务逻辑。

## 规则

1. 只用 profile 模式在真机上测量性能，不用 debug 模式或模拟器的数据下结论。
2. 一次只改一个变量。对照组和实验组用 `--dart-define` 开关切换，其余参数保持一致。
3. 先测量再优化：每项优化都要有数据证明它有收益；没有收益的复杂实现要删掉。
4. 长列表用懒加载（Sliver），只挂载视口和缓冲区内的元素。
5. 静态内容用 `RepaintBoundary` 隔离，动画只驱动绘制或变换，不触发重新构建和重新布局。
6. 谨慎使用代价高的效果：`BackdropFilter`、大半径模糊阴影、`saveLayer`（`Opacity`、`ShaderMask`、带抗锯齿的裁剪）。
7. 缓存要有上限：按像素字节数设预算，并且考虑设备的内存档位，不能随数据量无限增长。
8. 重计算放到后台 isolate（见 [overview.md](overview.md#线程模型)）。

## 原型参考

原型代码保存在 `prototype` 分支，可以用 `git show prototype:<路径>` 查看。下面这些优化**正式开发时可以沿用**，但移植到 main 之前要先在测试机上用对照实验确认收益。移植目标目录是 `app/lib/shared/rendering/`。

| 技术 | 原型文件（prototype 分支） | 作用 |
|---|---|---|
| 懒加载卡堆 Sliver | `lib/widgets/sliver_wallet_cards.dart` | 只挂载视口及缓冲区内的卡片，坐标由 Sliver 计算，不用 GlobalKey |
| 遮挡裁剪 | `lib/widgets/wallet_card_occlusion.dart` | 被下一张不透明卡片完全盖住的区域不绘制 |
| 共享阴影位图 | `lib/widgets/wallet_card_shadow.dart` | 所有卡片复用同一张模糊阴影图片 |
| 卡面纹理缓存 | `lib/widgets/wallet_card_paint_cache.dart`、`lib/widgets/wallet_card_texture_layout.dart` | 只把露出的区域紧凑打包成纹理，批量绘制；有像素预算和 LRU |
| 保留图层的页面条 | `lib/widgets/cached_page_strip.dart` | 切页时复用各页面的图层，只更新偏移 |
| 详情转场 | `lib/widgets/account_detail_motion.dart`、`lib/pages/assets_page.dart` | 卡片飞行动画、控件淡入淡出时序 |
| 对照实验方法 | `README.md`、`implementation_plan.md` | Timeline 标记 + `--dart-define` 开关 + 单变量对照 |

## 待验证风险

| # | 风险 | 说明 | 建议的验证方法 |
|---|---|---|---|
| 1 | 悬浮在滚动内容上方的 `BackdropFilter` | 原型的导航胶囊用了 σ16 的模糊，加号按钮和记账弹窗也有模糊。只要背后的内容在动，每一帧都要重新采样模糊，在低端 GPU 上很可能是主要开销 | 加一个开关，把模糊换成半透明纯色，对比 raster 耗时 |
| 2 | 固定 64MiB 的纹理预算 | 对 3–4GB 内存的机型可能偏大；`toImageSync` 第一次生成纹理时可能出现卡顿尖峰 | 按分辨率或设备内存缩放预算；用 Timeline 观察首次滚动时的帧耗时 |
| 3 | 自定义 RenderObject 的复杂度 | 卡堆用了 5 个自定义渲染组件，维护成本和出 bug 的风险都高 | 逐项关闭做对照，只保留在测试机上有明确收益的部分 |

## 测量方法

见 [guides/development.md](../guides/development.md#性能测量)。
