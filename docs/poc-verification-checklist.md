# Kadr POC 验证清单

对应调研报告第 10 节三个验证点 + POC 五个关键字的逐项闭环。

## 自动化验证（swift test 全绿即通过）

> 2026-10-08 复核：48 tests, 0 failures。

- [x] 多段拼接：testConcatNoTransitionExportDuration（无转场拼接时长 = 两段之和 5.0s ±0.3）
- [x] 变速：testSpeedChangeExportDuration（0.5x 变速后 3s 素材渲染为 6.0s ±0.3）
- [x] 转场 + 字幕 + 全链路：testSamplePlanExportProducesFullyRenderedOutput（时长 9.5s ±0.2，1080x1920，字幕烧录像素级断言 + 抽帧存 TestArtifacts 供人工核对）
- [x] EditPlan JSON → DSL：SamplePlanTests 黄金契约（testGoldenJSONDecodesToSamplePlan）+ PlanLoader 字段路径（testTypeMismatchReportsFieldPath）
- [x] 快照撤销栈：UndoStackTests / EditStoreTests 全部单测

## CLI 冒烟（验证点①：Agent 链路）

> 2026-10-08 复核：四子命令实际跑通，产物时长 9.5s。

工作目录：`cd KadrPOC`，素材目录参数 `--assets ./Assets`。

- [x] `genassets` → 素材生成，输出 `{"directory":...,"files":[...]}`
- [x] `sample` → 合法 EditPlan JSON（= Agent few-shot 样例）
- [x] `validate` 合法 JSON → exit 0 + `{"valid":true}`
- [x] `validate` 损坏 JSON → exit 1 + stderr 字段路径
- [x] `validate` 语义非法 → exit 2 + stderr 全部问题一次报全
- [x] `export -o <输出路径>` → JSONL 进度流 + `{"done":...}` + exit 0
- [x] export 产物应为 1080x1920 HEVC 单视频轨（ExportVerifier 硬校验，passthrough 会 exit 3）

## App 真机手动清单（iOS 17 真机）

> 2026-10-08 真机验证通过（含导出写入系统相册）。

- [x] 预览流畅播放，字幕叠加层随时间切换
- [x] 五类操作（裁剪/变速/转场/删除/字幕开关）各执行一次，预览重建正确
- [x] 连续编辑 5 次后撤销 5 次回到初始，再重做 5 次恢复
- [x] 非法操作（删空片段）红字报错且撤销栈不变
- [x] App 导出产物与 CLI 同 JSON 导出产物时长一致（±0.3s）

## 验证点③：4K HDR 素材

> 2026-10-08 CLI 侧已验：合成素材（3840x2160@30 HEVC 10-bit，BT.2020 + HLG），走完整 export 管线。

- [x] CLI：`--assets` 指向 4K HDR 素材目录，export 记录耗时 / 产物大小 / 是否成功
  - 单片段 3s → 1080x1920 HEVC，685ms，ExportVerifier 通过（无 passthrough）
  - 双片段 dissolve 0.5s → 5.5s（重叠语义正确），1214ms，单视频轨硬校验通过
  - 色调映射：源帧与产物帧逐像素一致（红段 sat 0.585→0.58，蓝段 0.576→0.571），无发灰/偏色
  - **注意**：产物保留 BT.2020 + HLG 元数据——管线是 HDR 直通而非转 SDR，正式产品需决策这是特性还是问题
  - 注意：纯色合成素材不考验编码器负载，真实 4K HDR 耗时以真机为准
- [ ] App 真机：换 4K HDR 素材预览，记录流畅度与发热（主观记录即可）

## 验证点②：iOS 17 底线覆盖率（人工调研项，代码无法验证）

- [ ] 查目标用户群的 iOS 版本分布（App Store Connect 或第三方统计），确认 iOS 17+ 覆盖率

## POC 结论模板

| 关键字 | 结果 | 备注 |
|---|---|---|
| 多段拼接 | ☑ | 2026-10-08 自动化 + 真机双验证 |
| 转场 | ☑ | 转场重叠语义实测时长：9.5s（dissolve 与相邻片段重叠，Kadr Video.duration 求和值 10.5s ≠ 渲染时长） |
| 变速 | ☑ | 2026-10-08 自动化 + 真机双验证 |
| 字幕 | ☑ | 抽帧人工核对：☑ 通过；真机预览叠加层正常 |
| headless 导出 | ☑ | CLI 冒烟通过；产物 9.5s / 1080x1920 HEVC |
| EditPlan JSON → DSL 端到端 | ☑ | 黄金 JSON 契约 + CLI validate/export 全链路 |
| 4K HDR 预览/导出 | ☑ | CLI 已验（2026-10-08）：导出/转场/色调全部通过；真机流畅度发热待验；产物为 HDR 直通非转 SDR |

结论：☐ 正式立项走路径 A / ☐ 有问题待解（列出）

## 实现期已暴露的 Kadr 上游问题

供后续向 Kadr 上游提 issue。

### Issue 1（Critical）：无音频素材导出静默 passthrough

CompositionBuilder 无条件为 Video 建空音频轨 → AVFoundation HEVC 兼容性检查返回 false → ExportEngine 静默回退 passthrough，丢弃整个 videoComposition（拼接/变速/转场/字幕全部丢失，产物只是首个片段原样拷贝）。无任何报错或日志。

POC 侧修复：静音 WAV 兜底（保证音频轨非空）+ ExportVerifier 硬校验（passthrough 直接 exit 3）。

### Issue 2（macOS 平台）：TextOverlay 的 CATextLayer 在 macOS headless 导出不渲染文字

同一 composition 在 iOS 真机预览正常显示字幕，macOS headless 导出产物中文字完全隐形（CATextLayer 在该路径下不参与渲染）。

POC 侧修复：CaptionImageRenderer 预渲染字幕图片 + ImageOverlay 替代 TextOverlay。
