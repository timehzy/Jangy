# 立项路线图（路径 A 落地计划）

> 2026-10-08 POC 结论落定后整理。选型依据见[调研报告](iOS开源视频剪辑框架选型调研报告.md)第 7 节路径 A；POC 验证记录见[poc-verification-checklist.md](poc-verification-checklist.md)。

## 已定论的结论

- **正式立项走路径 A：Kadr 全家桶直达**（2026-10-08）。POC 五个关键字（多段拼接 / 转场 / 变速 / 字幕 / headless 导出）+ EditPlan JSON → DSL 端到端 + 4K HDR CLI 侧全部 ☑。
- Kadr 依赖已切内部镜像 fork（`timehzy/kadr`、`timehzy/kadr-captions`、`timehzy/kadr-photos`），版本约束不变。fork 不会自动跟随上游：第一次需要上游修复时给三个 fork 配 `upstream` remote，手动同步、跑完全部测试再合入。
- **HDR 直通已定调为特性**（2026-10-09）：导出保留 BT.2020 + HLG 元数据，定位「HDR 全链路」；分享到不支持 HDR 平台的发灰问题留到正式版导出管线处理。素材导入侧相应采用 passthrough 优先策略（不重编码、保 HDR/高帧率）。

## 落地顺序（按优先级）

| # | 事项 | 状态 | 说明 |
|---|---|---|---|
| 1 | Kadr fork 内部镜像 + 锁版本 | ✅ 2026-10-08 | 风险登记册「单作者依赖」的核心缓解，成本极低，第一天就做 |
| 2 | 素材导入 | ✅ 2026-10-09 | EditPlan v2 素材登记表（`assets` + `assetID` 引用，为素材管理打底）；kadr-photos fork（v0.11）；App 相册多选导入（passthrough 优先 → 素材库落盘 → 追加时间线）；64 测试全绿 + CLI 契约不变 |
| 3 | 草稿持久化 | ✅ 2026-10-09 | 草稿 = EditPlan JSON（与 Agent 契约同格式，一鱼两吃）：`DraftStore` 原子写入 + sortedKeys 字节稳定 + schema 版本守卫（过新拒绝加载）；完整性守卫 = 存在性 + 元数据重探测比对，缺失/漂移显式报告；App 启动恢复 + 防抖 autosave + 「新建草稿」（经 `EditStore.apply`，可撤销）。**决策**：不引入 kadr-persistence 包（它持久化引擎层 `Video`，恢复需反向桥且丢素材登记表语义），只借鉴理念；不做 SHA-256 内容寻址 |
| 4 | POC 取舍清理入 backlog | 待做 | 见下节 |
| 5 | 音频（kadr-audio）/ 拍摄（NextLevel）/ MCP 化 | 🔜 下一个任务候选 | 差异化功能，遵循「UI 用 kadr-ui 原型，差异化后置」原则，素材导入 + 持久化已跑通，可排期 |

## POC 遗留跟进项（backlog，不阻塞立项）

- [ ] App 真机 4K HDR 预览流畅度/发热（清单验证点③最后一格，主观记录即可）
- [ ] iOS 17 底线覆盖率调研（人工项：App Store Connect 或第三方统计）
- [x] ~~HDR 直通产品决策~~ → 已定调为特性（2026-10-09，见「已定论的结论」）
- [ ] 向 Kadr 上游提三个 issue（前两个草稿已写在[清单](poc-verification-checklist.md)第 69 行起）：
  - Issue 1（Critical）：无音频素材导出静默 passthrough
  - Issue 2（macOS 平台）：TextOverlay 的 CATextLayer 在 headless 导出不渲染
  - Issue 3（iOS 模拟器）：转场双轨 composition + 素材分辨率 == renderSize → CA image queue 拒绝直通 buffer（-11800/-19230），播到转场即停。复现线索已沉淀为 POCCore `PreviewPlaybackTests`（iOS 回归测试）；POC 侧已用 renderSize+0.5pt 规避（`PreviewBridge.breakRenderSizeEquality`）
- [ ] 转场预览直通问题真机验证：若真机无此问题（模拟器 CA image queue 像素格式支持更窄），正式版移除 renderSize 微扰
- [ ] SwiftPM 包身份冲突预警：kadr-captions / kadr-photos 的 Package.swift 指向上游 kadr，与 timehzy 镜像同身份（当前仅警告，官方称未来版本升级为 error）——届时在 fork 上改写依赖 URL 并打新 tag
- [ ] 素材导入真机验证：授权弹窗 / iCloud 素材下载进度 / HDR 相册视频导入后导出（passthrough 保真链路）/ 慢动作视频保帧率
- [ ] 「文件 App 导入」通道（UIDocumentPicker，AssetOrigin.files 已预留）
- [ ] App 内素材库管理 UI（网格/缩略图/删除未引用素材；kadr-photos 有 `assets(in:)` 相册列举可用，缩略图需自建 PHImageManager + 缓存）

## POC 已知取舍（正式版要处理）

- 首次启动同步合成测试素材阻塞主线程数秒——正式版移出启动关键路径
- 字幕预览以 SwiftUI Text 叠加层近似（Kadr overlay 仅导出时烧录）——「所见即所导」对字幕降级为「预览近似」，正式版需决策是否接受
- 转场重叠语义：渲染时长 ≠ `Video.duration` 求和值（实测 9.5s vs 10.5s）——e2e 断言基于实测值，UI 时长显示同样要用实测口径

## 素材导入选型记录（2026-10-09）

对比 kadr-photos / YPImagePicker / 原生 PhotosPicker 后选定 **kadr-photos fork**：

- YPImagePicker 出局：选中后强制 AVAssetExportSession 重编码才给回调——HDR/full-range 元数据有丢失先例（issue #806）、4K 大文件有内存爆炸史（#498），与「HDR 直通特性」直接冲突；内置 trimmer/滤镜与 Kadr 管线重复建设；需 readWrite 全量授权；不支持文件 App 导入；Stevia/PryntTrimmerView 双 `.exact` 依赖。
- 原生 PhotosPicker 出局（作为长期方案）：`loadTransferable` 可用但 iCloud 进度、慢动作保帧率、Live Photo、typed error 都要自建；且系统选择器 UI 零定制，撑不起未来的 App 内素材库。
- kadr-photos 入选：PHAsset→文件 URL 的异步桥（iCloud 进度/慢动作/Live Photo/typed error）正是缺的；`assets(in:)` 相册列举可支撑未来自建素材库 UI；Apache-2.0 与镜像策略同构。弱项（选择器 UI 零定制、无缩略图/持久化）反正都要自建。

## 下一步任务的入口

任务 #3 已完成（2026-10-09）。下一个任务从 #4（POC 取舍清理）或 #5（音频/拍摄/MCP 化）中排。进会话后先读 [AGENTS.md](../AGENTS.md)，关键约束：编辑必经 `EditStore.apply`、素材引用走 `assets` 登记表 + `assetID`、Kadr 依赖收敛在引擎适配层、CLI stdout 只走结构化 JSON、草稿读写必经 `DraftStore`。
