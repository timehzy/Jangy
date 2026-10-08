# Kadr POC 验证清单

对应调研报告第 10 节三个验证点 + POC 五个关键字的逐项闭环。

## 自动化验证（swift test 全绿即通过）

- [ ] 多段拼接：testConcatNoTransitionExportDuration（无转场拼接时长 = 两段之和 5.0s ±0.3）
- [ ] 变速：testSpeedChangeExportDuration（0.5x 变速后 3s 素材渲染为 6.0s ±0.3）
- [ ] 转场 + 字幕 + 全链路：testSamplePlanExportProducesFullyRenderedOutput（时长 9.5s ±0.2，1080x1920，字幕烧录像素级断言 + 抽帧存 TestArtifacts 供人工核对）
- [ ] EditPlan JSON → DSL：SamplePlanTests 黄金契约（testGoldenJSONDecodesToSamplePlan）+ PlanLoader 字段路径（testTypeMismatchReportsFieldPath）
- [ ] 快照撤销栈：UndoStackTests / EditStoreTests 全部单测

## CLI 冒烟（验证点①：Agent 链路）

工作目录：`cd KadrPOC`，素材目录参数 `--assets ./Assets`。

- [ ] `genassets` → 素材生成，输出 `{"directory":...,"files":[...]}`
- [ ] `sample` → 合法 EditPlan JSON（= Agent few-shot 样例）
- [ ] `validate` 合法 JSON → exit 0 + `{"valid":true}`
- [ ] `validate` 损坏 JSON → exit 1 + stderr 字段路径
- [ ] `validate` 语义非法 → exit 2 + stderr 全部问题一次报全
- [ ] `export -o <输出路径>` → JSONL 进度流 + `{"done":...}` + exit 0
- [ ] export 产物应为 1080x1920 HEVC 单视频轨（ExportVerifier 硬校验，passthrough 会 exit 3）

## App 真机手动清单（iOS 17 真机）

- [ ] 预览流畅播放，字幕叠加层随时间切换
- [ ] 五类操作（裁剪/变速/转场/删除/字幕开关）各执行一次，预览重建正确
- [ ] 连续编辑 5 次后撤销 5 次回到初始，再重做 5 次恢复
- [ ] 非法操作（删空片段）红字报错且撤销栈不变
- [ ] App 导出产物与 CLI 同 JSON 导出产物时长一致（±0.3s）

## 验证点③：4K HDR 素材

- [ ] CLI：`--assets` 指向 4K HDR 素材目录，export 记录耗时 / 产物大小 / 是否成功
- [ ] App 真机：换 4K HDR 素材预览，记录流畅度与发热（主观记录即可）

## 验证点②：iOS 17 底线覆盖率（人工调研项，代码无法验证）

- [ ] 查目标用户群的 iOS 版本分布（App Store Connect 或第三方统计），确认 iOS 17+ 覆盖率

## POC 结论模板

| 关键字 | 结果 | 备注 |
|---|---|---|
| 多段拼接 | ☐ | |
| 转场 | ☐ | 转场重叠语义实测时长：9.5s（dissolve 与相邻片段重叠，Kadr Video.duration 求和值 10.5s ≠ 渲染时长） |
| 变速 | ☐ | |
| 字幕 | ☐ | 抽帧人工核对：☐ 通过 |
| headless 导出 | ☐ | |
| EditPlan JSON → DSL 端到端 | ☐ | |
| 4K HDR 预览/导出 | ☐ | |

结论：☐ 正式立项走路径 A / ☐ 有问题待解（列出）

## 实现期已暴露的 Kadr 上游问题

供后续向 Kadr 上游提 issue。

### Issue 1（Critical）：无音频素材导出静默 passthrough

CompositionBuilder 无条件为 Video 建空音频轨 → AVFoundation HEVC 兼容性检查返回 false → ExportEngine 静默回退 passthrough，丢弃整个 videoComposition（拼接/变速/转场/字幕全部丢失，产物只是首个片段原样拷贝）。无任何报错或日志。

POC 侧修复：静音 WAV 兜底（保证音频轨非空）+ ExportVerifier 硬校验（passthrough 直接 exit 3）。

### Issue 2（macOS 平台）：TextOverlay 的 CATextLayer 在 macOS headless 导出不渲染文字

同一 composition 在 iOS 真机预览正常显示字幕，macOS headless 导出产物中文字完全隐形（CATextLayer 在该路径下不参与渲染）。

POC 侧修复：CaptionImageRenderer 预渲染字幕图片 + ImageOverlay 替代 TextOverlay。
