# Android 经典布局与内存优化

本次以 `c0410c2`（官方 1.4.0 功能基础）为起点，仅调整 Android。布局参考官方
[v1.2.6 Release](https://github.com/wanghongenpin/proxypin/releases/tag/v1.2.6)，不回退功能或依赖。

## 改动范围

- 底部导航、配置/设置卡片、图标及工具箱恢复经典样式，移除 Android 上额外的色块、SVG 装饰和卡片裁剪。
- 保留全部工具和配置入口，包括弱网、环境变量、MCP、证书、脚本、请求映射、断点及重放任务。
- Android 来源应用图标按包名和版本共享字节，缓存最多 128 项，五分钟后允许刷新；每条请求仍保留独立的连接信息。
- 图标按照实际显示像素解码；Android UI 图标缓存最多 128 项，异步加载复用未完成的 Future。
- Android 请求列表预加载从两个视口降到半个视口，域名列表在 100ms 窗口内合并刷新。
- 取消已卸载列表的待执行刷新，清理失效响应回调和空域名桶，避免 WebSocket 升级重复加入域名列表。
- 保留原有 `ListQueue`。Dart 的 `ListQueue.elementAt` 已是常数时间读取，无需增加全量数组副本或新的索引层。

没有增加依赖、改动抓包协议处理、截断流量正文、默认清空请求、改变历史保留策略或修改 iOS/桌面专属文件。

## 云沙箱对照结果

使用仓库 CI 固定的 Flutter 3.47.7 / Dart 3.13.5，在 Linux ARM64 Flutter 测试引擎执行。
下列数据是受控工作负载的局部实测，不是 Android 整机 RSS/PSS 或真机帧率：

| 指标及工作负载 | 原路径 | Android 优化路径 | 降幅 |
| --- | ---: | ---: | ---: |
| 2000 条同应用请求，每次传回 32KiB 图标，统计仍被引用的不同图标缓冲区 | 62.5MiB | 32KiB | 99.95% |
| 仓库真实 256px PNG，在 3× DPR 的 40dp 图标场景，Flutter 解码缓存 | 262144B | 57600B | 78.03% |
| 2000 个不同域名的连续请求，开启域名搜索时的筛选调用次数 | 2003000 | 4000 | 99.80% |
| 相同 400×800 视口和滚动操作，2000 条请求中的已挂载行（含屏外缓存） | 55 | 22 | 60.00% |

图标字节测试通过真实 MethodChannel 编解码和模拟原始映射路径进行对照。解码测试使用真实 PNG 和
`ImageCache.currentSizeBytes`；域名和行数测试使用保留的原渲染路径作为控制组。

补丁相关的 29 项测试全部通过，修改文件静态分析没有问题。额外的多选、MQTT、WebSocket 持久化、
HTTP/2 转换和证书链回归合计另有 18 项通过；需要私有 P12 文件的 1 项测试跳过。
现有 `search_controller_test.dart` 在本 SDK 下因未初始化 WidgetsBinding 失败，其源文件和测试均未修改。

复现命令：

```sh
flutter test --reporter expanded test/android_process_info_test.dart test/android_capture_benchmark_test.dart
flutter test test/android_classic_ui_test.dart test/android_domain_list_test.dart test/android_request_sequence_test.dart
```

## 尚未完成的真机验收

云沙箱没有 Android 真机/模拟器，因此不能宣称“整机内存大幅下降、真机滚动已流畅”已经验收。
流量正文、协议状态和编辑器仍正常保留，它们的占用不等于上表的图标或 UI 缓存占用。

应在同一 Android 设备上，分别安装原 `c0410c2` 和补丁版本的 release/profile APK：

1. 固定相同请求数量、响应正文大小、来源应用、HTTPS/MQTT/WS 比例与历史/MCP/内存清理设置。
2. 在空闲、连续抓包、深度滚动、请求详情打开/关闭、清空抓包后的阶段分别记录
   `adb shell dumpsys meminfo com.network.proxy.debugversion` 的 TOTAL PSS、Java/Native/Graphics 内存。
3. 通过 `flutter run --profile -d <device-id>` 的 DevTools Performance 记录滚动时的 UI/raster 帧耗时和卡顿帧数。
4. 复核多选、搜索、排序、删除、导出、重放、脚本、请求映射/断点、证书链和 MQTT/WS 详情均可用。

为避免云沙箱磁盘变只读，本次不下载完整 Android SDK/NDK，也不在此构建 APK；APK 使用仓库已有的
GitHub Actions Android release 构建工作流生成。
