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
| 4 | POC 取舍清理入 backlog | ✅ 2026-10-09 | backlog 定级完成：合并「POC 已知取舍」为单一清单，按 P0–P3 优先级 + 执行主体（agent/人工/真机）+ 验收标准梳理，见下节 |
| 5 | 音频 / 拍摄 / MCP 化 | ✅ 2026-10-13 已决策 | v1 范围拍板：拍摄出局（单开 App）；音频整体后置（v1 后开专项，含 kadr-audio 评估）；MCP 化改写为「剪辑 Agent」入 v1——见「正式版启动」v1 范围决策记录 |

## Backlog（2026-10-09 第四步清理定级）

定级口径：

- **优先级**：P0 = 有外部时效或暴露正确性风险，尽快；P1 = 影响体验或阻塞后续技术决策，下个迭代；P2 = 功能扩展，随版本排期；P3 = 外部依赖或人工调研，持续观察
- **执行主体**：`agent` = 编码类 agent 可独立完成；`人工` = 需人决策/操作；`真机` = 需真机环境验证
- 每条附验收标准，做完回填日期与结论

### P0

- [x] **向 Kadr 上游提三个 issue**（✅ 2026-10-09，已提交 `SteliyanH/kadr`，跟进回复即可）
  - Issue 1（Critical）：无音频素材导出静默 passthrough → [#201](https://github.com/SteliyanH/kadr/issues/201)
  - Issue 2（macOS 平台）：TextOverlay 的 CATextLayer 在 headless 导出不渲染 → [#202](https://github.com/SteliyanH/kadr/issues/202)
  - Issue 3（iOS 模拟器）：转场双轨 composition + 素材分辨率 == renderSize → CA image queue 拒绝直通 buffer（-11800/-19230），播到转场即停 → [#203](https://github.com/SteliyanH/kadr/issues/203)；POC 侧已用 renderSize+0.5pt 规避（`PreviewBridge.breakRenderSizeEquality`），回归测试 `PreviewPlaybackTests`
  - 提交前已对 v1.1.0 源码逐条核实根因描述；若上游有回复需跟进，回填结论到本节
  - 后续（2026-10-09）：#201 已提修复 PR → [#204](https://github.com/SteliyanH/kadr/pull/204)（根因修复：构建期移除空音频轨 + ClipVolume 仅在真实插入音频时登记；663 测试全绿）。CLA 已签署（提交邮箱已改 yiliforever@qq.com），等作者 review；合并后 POC 侧可评估移除 `SilentAudio` 兜底

### P1

- [x] **素材导入真机验证**（✅ 2026-10-12）：授权弹窗正确 / iCloud 素材下载进度条正确 / HDR 相册视频导入后导出正确（passthrough 保真链路）/ 慢动作视频保帧率正确——四项全过，无新问题立项
- [x] **转场预览直通问题真机验证**（✅ 2026-10-12）：真机无此问题（证实为模拟器 CA image queue 像素格式支持更窄所致）。`breakRenderSizeEquality` 微扰保留——POC 开发主战场仍是模拟器，无条件移除会让模拟器预览回归 -11800；正式版发布前再移除或按 `targetEnvironment(simulator)` 条件编译（届时 `PreviewPlaybackTests` 回归全绿才算完）
- [x] **首次启动同步合成测试素材阻塞主线程**（✅ 2026-10-12）：启动只做目录/草稿装配，合成移入 `AppModel.prepareAssets()`（POCCore 新增 `AssetSynthesizer.synthesizeAsync`，后台线程执行）；进度态 `isPreparingAssets` 门禁导入/导出，完成后才重建预览 + 草稿完整性核对；合成失败显式上报，不再 `preconditionFailure`
  - 验收：首屏渲染不等待素材合成；`swift test` 77 个全绿 + App 模拟器编译通过

### P2

- [ ] **导出帧快照单帧直渲（路线 B）**（`agent`，Kadr fork）：路线 A（导全片再抽帧）每次快照付一次全片导出；触发条件 = Agent 自检链路被导出耗时卡住，或 App 内要交互式「预览 vs 导出真值」比对。做法：fork 上给 `Video` 加导出保真单帧渲染入口（`CompositionBuilder.build` + `OverlayRenderer.buildLayerTree` 挂 animationTool + `AVAssetImageGenerator`），需先验证自定义 compositor / animationTool 过 image generator 的行为（CATextLayer 隐形同类风险区）；护栏用例已就位（`testFrameSnapshotMatchesExportedTruth`）
  - 验收：单帧渲染 <1s 且通过快照==真值锚定用例；`FrameSnapshotter` 内部换实现、对外 API 不变
- [x] **「文件 App 导入」通道**（✅ 2026-10-13，真机验收通过）：UIDocumentPicker（asCopy 系统代拷，免 security-scope 管理）多选导入 → 素材库落盘 → 追加时间线全链路，`AssetOrigin.files` 落地；AppModel 导入尾部抽为 `importPipeline` 两渠道共用（相册渠道行为等价重构，77 测试全绿）；真机验收覆盖多选导入、预览/导出、单撤销步回退、相册导入回归
  - 验收：文件 App 多选导入 → 素材库落盘 → 追加时间线全链路 ✅；设计 spec `docs/superpowers/specs/2026-10-13-files-import-design.md`，实现计划 `docs/superpowers/plans/2026-10-13-files-import.md`
- [ ] **字幕预览近似的正式版决策**（`人工` 决策 + `agent` 执行）：Kadr overlay 仅导出时烧录，POC 用 SwiftUI Text 叠加层近似——「所见即所导」对字幕降级为「预览近似」——**2026-10-13 移入「正式版启动」v1 任务 2**
- [x] **转场重叠语义的时长口径统一**（✅ 2026-10-13）：渲染时长 ≠ `Video.duration` 求和值（实测 9.5s vs 10.5s）。口径统一收进 POCCore `TimelineDuration.swift`：`EditPlan.renderedDuration` = Σ 片段输出时长（源区间/倍速）− Σ 转场重叠量（dissolve 全额重叠、fade 不重叠，与 Kadr CompositionBuilder `overlap(during:)` 一致）；`EditPlanValidator` 转场适配检查改用同一 `outputDuration`。UI 侧 TimelineView 总时长与单片段输出时长均走此口径；e2e 时长断言改为锚定 `renderedDuration`（与真实导出产物互相锚定，样例 9.5s 锚点由 `TimelineDurationTests` 固定）
  - 验收：App 各处时长展示与导出实测时长一致 ✅（85 测试全绿 + App 模拟器编译通过）
- [x] **导出管线 HDR→SDR 降级选项**（✅ 2026-10-13，真机验收通过）：HDR 直通已定调为特性，但分享到不支持 HDR 平台的发灰问题需导出侧提供 SDR 降级（SDR 路径 POC 已验证：Kadr Codec.h264 或 709 composition）。实现：新增 `ExportOptions`（POCCore 状态层，struct 预留扩展）承载导出配置；SDR 档映射为同几何/帧率的 `Codec.h264` preset，由 AVAssetExportSession 自动色调映射到 BT.709；`ExportRunner`/`ExportVerifier` 透传配置，SDR 档校验编码 avc1；App 侧点「导出」先弹 `ExportPanel` 配置面板（HDR 开关默认开启），确认后才导出；e2e 新增 SDR 专项（avc1 + 分辨率/时长不变）
  - 验收：导出设置提供 HDR 直通 / SDR 降级两档 ✅；SDR 档产物在不支持 HDR 设备上显示正常 ✅（真机验证通过）；86 测试全绿 + App 模拟器编译通过 + CLI 冒烟通过

### P3

- [ ] **App 真机 4K HDR 预览流畅度/发热**（`真机`，2026-10-12 自 P1 降级）：不优先——预览/导出都走 AVFoundation 系统管线，即使发现问题也基本没有应用层可做的优化空间；真机使用中若主观感知到卡顿/发热再记录
- [ ] **iOS 17 底线覆盖率调研**（`人工`）：App Store Connect 或第三方统计，确认目标用户群 iOS 17+ 覆盖率
- [ ] **SwiftPM 包身份冲突预警**（外部依赖；届时 `agent` 执行）：kadr-captions / kadr-photos 的 Package.swift 指向上游 kadr，与 timehzy 镜像同身份——当前仅警告，官方称未来版本升级为 error
  - 验收（触发时）：在 fork 上改写依赖 URL 并打新 tag，全量测试通过后切版本约束

### 已关闭

- [x] ~~HDR 直通产品决策~~ → 已定调为特性（2026-10-09，见「已定论的结论」）
- [x] ~~App 内素材库管理 UI~~ → 2026-10-13 移入「正式版启动」v1 范围候选（理由：纯表现层功能，不验证技术风险、不阻塞技术决策；删除正确性已被 `DraftStore.verify` 完整性守卫覆盖；缩略图缓存与正式版时间线 UI 共建避免返工）

## 正式版启动（v1 规划）

> 2026-10-13 入口判断：技术验证阶段的门已全部关闭（POC 五关键字 ☑、P0/P1 全清、P2 技术项全过且真机验收通过、86 测试全绿、POC 清单遗留项全部收口），可以进入正式版开发。剩余 P3 项（4K HDR 流畅度 / iOS 17 覆盖率 / SwiftPM 身份冲突）均为发布前门槛或外部触发项，不阻塞开发入口。

v1 头两个任务（均为 `人工` 决策项，决策后交 `agent` 执行）：

1. **v1 范围决策**（✅ 2026-10-13 已拍板）：从差异化候选（音频 / 拍摄 / MCP 化，见「落地顺序」#5）与已推迟项中圈定 v1 范围。结论：
   - **拍摄：出局**。核心定位是剪辑，拍摄值得单开一个新 App，不在本仓库范围
   - **音频：整体后置到 v1 之后**，将来开音频专项再议（含 kadr-audio 引入评估——它是「音频获取/处理入口」桥：Apple Music 集成 / 配音录制 / LUFS 响度归一 / AudioSession 管理；Kadr core 自带的 `AudioTrack` 剪辑侧能力——音量/淡入淡出/ducking/crossfade/变速变调——届时直接用，不依赖新包）
   - **MCP 化：改写为「剪辑 Agent」并入 v1**。理由：MCP 是跨产品工具互操作协议，App 内没有第二个消费方，内嵌 LLM 直接 function calling 即可，套 MCP 只多一层序列化开销；且剪辑真正难的是编排（镜头选择/节奏/叙事），不是工具调用——这是 Agent 本体问题。架构分三层：
     1. **工具层**：`EditStore` 操作封装为 agent-facing function schema（编辑必经 `EditStore.apply`，自带校验护栏）
     2. **编排层**：agent loop + 剪辑领域 prompt + `EditPlanValidator` 报错回喂的反馈环
     3. **headless 先行**：`jangy-cli` 扩展 agent 子命令，先跑通「自然语言 → EditPlan JSON → validate → export」全链路再进 App UI
   - **MCP server：显式降级为未来分发渠道**（如桌面 AI 客户端远程驱动剪辑）；工具层设计干净后 MCP 只是一层薄包装
   - **已确定纳入候选**（不变）：
     - **App 内素材库管理 UI**（自 P2 移入）：网格/缩略图/删除未引用素材；kadr-photos 有 `assets(in:)` 相册列举可用，缩略图需自建 PHImageManager + 缓存。**约束：不晚于首个对外发布版本**——导入走 asCopy 落盘占 sandbox，无删除入口则用户存储只增不减
     - 验收（移入时沿用）：素材库网格展示 + 删除未引用素材后 plan 完整性校验通过
2. **字幕预览决策**（✅ 2026-10-13 已拍板，自 P2 移入）：**接受近似，但收窄定义为「字幕时间对位示意层」**。调研结论：业界专业编辑器（LumaFusion/VN/剪映）收敛于「自定义合成器、预览导出同一渲染管线」；混合 UI 叠加路线在真实产品中存活但天花板低（drift 投诉 + 复杂度上限）。决策：
   - **UI 合成预览只承担字幕**（静态；v1 不做字幕动画），定位是时间对位示意——不承诺像素一致，只承诺时间/位置模板正确。字幕是唯一例外的理由：预览诉求是时间对位而非像素保真，且文字恰是 UI 渲染优于烧录预览的内容类型
   - **UI 口禁入清单**：贴纸/水印（静态也暂不）、属性动画、资产驱动动画。各自正确路径：几何变换（裁剪/旋转）与多镜头/PiP 走 videoComposition（预览原生精确，转场双轨已验证此管线）；动态贴纸走 HEVC-with-alpha 视频轨道（LumaFusion 同款路线）；程序化特效（粒子/shader）v1 不做
   - **护栏**：导出帧快照入口（当前时间点走导出管线渲一帧），人工比对 + 给 Agent 链路留自检工具（✅ 2026-10-13 路线 A 落地：`FrameSnapshotter`（JangyCore）+ CLI `snapshot` 子命令，完整导出临时 mp4 后零容差抽帧 PNG，多 `--at` 共享一次导出；e2e 锚定「快照帧 ≈ 全片导出同刻抽帧」。单帧直渲优化见 P2 backlog）
   - **未来触发条件**：出现第一个「必须精确预览」的效果（滤镜/调色、HDR 字幕观感投诉等）→ 启动自定义 `AVVideoCompositing` 专项（动 Kadr fork 渲染管线，预览导出共享合成器，弃 CoreAnimationTool 路线）；`PreviewBridge` 抽象已为此预留
3. **代码起点决策**（✅ 2026-10-13 已拍板）：**基于 POC 直接演进，不新开工程/仓库**。理由：POC 三层分层本就是为正式版设计的（状态层纯 Swift / Kadr 收敛引擎适配层 / App 壳薄），v1 任务（剪辑 Agent、素材库管理 UI、导出帧快照）全为增量，无一项需推翻现有结构；86 测试 + CLI 契约 + e2e + git 历史/已知坑记录是 Agent 链路与后续开发的地基，重写纯损耗。配套「正式版化收口」清单（随 v1 首个任务一起做）：
   - **命名去 POC 化**（✅ 2026-10-13）：同步完成目录结构标准化（布局：xcodeproj 提根 + `Packages/`，标准 iOS App 工程结构）。最终命名：包与模块 `KadrPOC`/`POCCore` → `Packages/JangyCore`（`JangyCore`）、CLI `kadrpoc-cli` → `jangy-cli`、App target `JangyPOC` → `Jangy`（`Jangy.xcodeproj` 提根、源码 `Jangy/`、bundle ID `com.haozhenyi.Jangy`、@main `JangyApp`）；CI / .vscode / 活文档同步，docs/superpowers 历史文档保留旧名（时间快照不改）。验证：86 测试全绿 + CLI 冒烟 + xcodebuild 模拟器构建通过
   - **POC 专属代码隔离**（✅ 2026-10-13）：`AssetSynthesizer` / `SamplePlan` 移入新 target `JangyTestSupport`（仅测试与 jangy-cli 依赖，App 不可见 → 不进正式产物为硬保证）；App 侧样例引导整体删除（`prepareAssets` / `isPreparingAssets` 门禁 / 初始与「新建」的样例工程），首发空时间线或恢复草稿即正式版行为；`synthesizeAsync` 及其测试随删除（无消费方）。开发期想要样例内容可用 CLI 播种：往模拟器沙盒 `Application Support/Jangy/` 跑 `genassets --to <dir>` + `sample > <dir>/draft.json`。验证：85 测试全绿（减去的 1 个是随 `synthesizeAsync` 删除的用例）+ CLI 冒烟 + xcodebuild 模拟器构建通过
   - **模拟器微扰**：`breakRenderSizeEquality` 发布前改 `targetEnvironment(simulator)` 条件编译（沿 P1 既定口径）
   - **`SilentAudio` 兜底**：上游 [#204](https://github.com/SteliyanH/kadr/pull/204) 合并后评估移除
   - **不动**：CLI stdout JSON 契约、draft.json 格式、测试套件、三层依赖方向（Agent 链路与自动化依赖）

## 素材导入选型记录（2026-10-09）

对比 kadr-photos / YPImagePicker / 原生 PhotosPicker 后选定 **kadr-photos fork**：

- YPImagePicker 出局：选中后强制 AVAssetExportSession 重编码才给回调——HDR/full-range 元数据有丢失先例（issue #806）、4K 大文件有内存爆炸史（#498），与「HDR 直通特性」直接冲突；内置 trimmer/滤镜与 Kadr 管线重复建设；需 readWrite 全量授权；不支持文件 App 导入；Stevia/PryntTrimmerView 双 `.exact` 依赖。
- 原生 PhotosPicker 出局（作为长期方案）：`loadTransferable` 可用但 iCloud 进度、慢动作保帧率、Live Photo、typed error 都要自建；且系统选择器 UI 零定制，撑不起未来的 App 内素材库。
- kadr-photos 入选：PHAsset→文件 URL 的异步桥（iCloud 进度/慢动作/Live Photo/typed error）正是缺的；`assets(in:)` 相册列举可支撑未来自建素材库 UI；Apache-2.0 与镜像策略同构。弱项（选择器 UI 零定制、无缩略图/持久化）反正都要自建。

## 下一步任务的入口

任务 #4 已完成（2026-10-09）：backlog 定级见上节。**2026-10-13 更新：技术验证阶段已收口，「正式版启动（v1 规划）」三项决策均已拍板**——v1 范围（拍摄出局 / 音频后置 / 剪辑 Agent 入 v1）、字幕预览（UI 口冻结为字幕对位示意层）、代码起点（基于 POC 直接演进 + 正式版化收口）。v1 进入执行阶段：命名收口与 POC 专属代码隔离已完成（见上节收口清单），任务从「正式版启动」节圈定范围里排（素材库管理 UI、剪辑 Agent headless 链路、导出帧快照等）。进会话后先读 [AGENTS.md](../AGENTS.md)，关键约束：编辑必经 `EditStore.apply`、素材引用走 `assets` 登记表 + `assetID`、Kadr 依赖收敛在引擎适配层、CLI stdout 只走结构化 JSON、草稿读写必经 `DraftStore`。
