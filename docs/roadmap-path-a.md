# 立项路线图（路径 A 落地计划）

> 2026-10-08 POC 结论落定后整理。选型依据见[调研报告](research/iOS开源视频剪辑框架选型调研报告.md)第 7 节路径 A；POC 验证记录见[poc-verification-checklist.md](archive/poc-verification-checklist.md)。
>
> 执行主体口径：`agent` = 编码类 agent 可独立完成；`人工` = 需人决策/操作；`真机` = 需真机环境验证。

## 待办

### 阶段：v1 执行（当前）

- [ ] **素材库管理 UI**（`agent` 执行；v1 范围已拍板）
  - 内容：网格/缩略图/删除未引用素材；kadr-photos 有 `assets(in:)` 相册列举可用，缩略图需自建 PHImageManager + 缓存
  - 硬约束：**不晚于首个对外发布版本**——导入走 asCopy 落盘占 sandbox，无删除入口则用户存储只增不减
  - 验收：素材库网格展示 + 删除未引用素材后 plan 完整性校验通过
- [ ] **Agent 快照卡片异步加载**（`agent` 执行；App 接入遗留小项）：当前主线程同步读 MB 级 PNG，开发期可接受，后续换缓存/异步加载
- [ ] **Agent 多模型表现评估**（`人工`）：Kimi/Claude 之外的模型在剪辑 Agent 链路的表现

### 阶段：发布前门槛

- [ ] **移除模拟器微扰 `breakRenderSizeEquality`**（`agent` 执行）：发布前改 `targetEnvironment(simulator)` 条件编译（微扰保留至今的理由：POC 开发主战场是模拟器，无条件移除会让模拟器预览回归 -11800）。验收：`PreviewPlaybackTests` 回归全绿
- [ ] **Agent 凭据产品化**（`人工` 决策）：当前为本地文件注入（`Application Support/Jangy/agent-config.json`），产品化发布前再议
- [ ] **4K HDR 预览流畅度/发热**（`真机`，持续观察）：预览/导出都走 AVFoundation 系统管线，即使发现问题也基本无应用层优化空间；真机使用中主观感知到卡顿/发热再记录
- [ ] **SwiftPM 包身份冲突**（外部触发，届时 `agent` 执行）：kadr-captions / kadr-photos 的 Package.swift 指向上游 kadr，与 timehzy 镜像同身份——当前仅警告，官方称未来版本升级为 error。触发时验收：fork 上改写依赖 URL 并打新 tag，全量测试通过后切版本约束

### 阶段：v1 之后

- **音频专项**（已拍板后置，届时开专项再议）：含 kadr-audio 引入评估（Apple Music 集成 / 配音录制 / LUFS 响度归一 / AudioSession 管理）；Kadr core 自带 `AudioTrack` 剪辑侧能力（音量/淡入淡出/ducking/crossfade/变速变调）届时直接用，不依赖新包
- ~~拍摄~~：**已出局**——核心定位是剪辑，拍摄值得单开一个新 App，不在本仓库范围

## 已完成

### 阶段：v1 规划与启动（2026-10-13 ~ 10-14）

- [x] **剪辑 Agent App 接入**（✅ 2026-10-13，真机手动验证 10-14；spec：[agent-app-integration-design](superpowers/specs/2026-10-13-agent-app-integration-design.md)）
  - 要点：EditStore 合一（AgentRunContext 注入共享 store + AgentStoreScheduler 调度，Agent 每步编辑实时落到预览 + autosave）；整任务一步撤销（EditStore 分组事务，组内逐工具校验反馈保留）；连续对话（EditAgentSession 长活、transcript 跨 send 保留，会话间隙 plan 被手动改过则注入「先 get_plan 对齐」提示）；UI = 半屏 sheet 三档 + 全屏态 + iMessage 式对话流 + 运行中停止按钮，运行中全部编辑入口锁定；凭据本地文件注入
  - 验收：125 测试全绿 + App 模拟器构建通过 + CLI 冒烟无回归 + 真 key 冒烟 + 真机手动验证（追问链路 / sheet 三档切换 / 对话流底部锚定 / 整任务一步撤销 / 停止按钮）全过
- [x] **剪辑 Agent headless 链路**（✅ 2026-10-13，按三层拆分落地）
  - LLM 接入：选型 [AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel)（FoundationModels 同 API 的 provider 抽象；Anthropic 官方 `ClaudeForFoundationModels` 因要求 OS 27 beta 出局，OS 达标后可一行切换）；依赖走内部镜像 `timehzy/AnyLanguageModel`，约束 `from: "0.16.0"`
  - 工具层（`JangyAgent` target）：11 个原子编辑工具全经 `EditStore.apply`；一切失败以 `{"status":"error","issues":[...]}` 信封回喂模型自纠，防御性参数解析保证工具不抛错炸轮
  - 编排层：EditAgentRunner outer loop 本体（AnyLanguageModel Anthropic provider 不内部续轮，续轮/终止/轮次上限全在 outer loop，行为依据见 known-pitfalls「LLM 接入」）；snapshot 图片经下一轮 respond 回喂；`maxResponseTokens` 默认 32768；轮次耗尽显式报错
  - CLI `agent` 子命令：stdout JSONL 事件流，exit code 4 = LLM 接入错误（公约 §7.3）；最终 plan 与 draft.json 同格式，可被 validate/export 直接消费
  - 验收：111 测试全绿 + 真 key live 冒烟通过（Kimi coding 端点，6 轮完成「切半 + 加速 + 字幕 + 快照自检」；冒烟暴露并修复两个编排层 bug——provider 不续轮静默收工、max_tokens 缺省过小）
- [x] **v1 三项决策拍板**（✅ 2026-10-13）：范围（拍摄出局 / 音频后置 / 剪辑 Agent 入 v1）、字幕预览（时间对位示意层）、代码起点（基于 POC 演进）——决策内容见下文「决策记录」
- [x] **正式版化收口清单**（✅ 2026-10-13，随 v1 首个任务完成）
  - 命名去 POC 化 + 目录标准化：包与模块 → `Packages/JangyCore`（JangyCore）、CLI → `jangy-cli`、App target → `Jangy`（`Jangy.xcodeproj` 提根，bundle ID `com.haozhenyi.Jangy`）；CI / .vscode / 活文档同步，docs/superpowers 历史文档保留旧名
  - POC 专属代码隔离：`AssetSynthesizer` / `SamplePlan` 移入 `JangyTestSupport`（仅测试与 CLI 依赖，不进正式产物）；App 样例引导整体删除，首发空时间线或恢复草稿即正式版行为；开发期播种用 CLI `genassets --to <dir>` + `sample > <dir>/draft.json`
  - `SilentAudio` 兜底移除（随 fork v1.2.1，见 P0 上游 issue 条目）

### 阶段：POC 技术验证（2026-10-08 ~ 10-13）

入口判断（2026-10-13）：POC 五关键字 ☑、P0/P1 全清、P2 技术项全过且真机验收通过、86 测试全绿——技术验证阶段的门全部关闭，进入正式版开发。

- [x] **P0：向 Kadr 上游提三个 issue**（✅ 2026-10-09 提交，10-13 收口）
  - [#201](https://github.com/SteliyanH/kadr/issues/201)（Critical）：无音频素材导出静默 passthrough → 已提修复 PR [#204](https://github.com/SteliyanH/kadr/pull/204)（CLA 已签，等作者 review）；修复分支已先合入 fork main（v1.2.1），POC 侧 `SilentAudio` 兜底与 `assetHasAudio` 探测随之删除。**行为变化：无音频素材的导出产物从此不含音频轨**（原先是静音轨）；`ExportVerifier` 保留为纯防御性硬校验
  - [#202](https://github.com/SteliyanH/kadr/issues/202)（macOS）：TextOverlay 的 CATextLayer 在 headless 导出不渲染
  - [#203](https://github.com/SteliyanH/kadr/issues/203)（iOS 模拟器）：转场双轨 composition + 素材分辨率 == renderSize → CA image queue 拒绝直通 buffer（-11800/-19230）；POC 侧已用 renderSize+0.5pt 规避（`PreviewBridge.breakRenderSizeEquality`），回归测试 `PreviewPlaybackTests`
- [x] **P1：素材导入真机验证**（✅ 2026-10-12）：授权弹窗 / iCloud 下载进度 / HDR passthrough 保真 / 慢动作保帧率四项全过，无新问题立项
- [x] **P1：转场预览直通真机验证**（✅ 2026-10-12）：真机无此问题，证实为模拟器 CA image queue 像素格式支持更窄所致；`breakRenderSizeEquality` 微扰保留（见发布前门槛）
- [x] **P1：首启同步合成素材阻塞主线程**（✅ 2026-10-12）：启动只做目录/草稿装配，合成移入后台 + 进度态门禁导入/导出；该套样例引导后随 POC 代码隔离整体删除（见 v1 收口）
- [x] **P2：导出帧快照单帧直渲（路线 B）**（✅ 2026-10-13）：fork 新增 `Video.renderedFrame(at:)`（v1.2.0），导出同款构建经 `AVAssetImageGenerator` 单帧渲染，跳过全片编码；`FrameSnapshotter` 对内换实现、对外 API 不变；锚定用例改按「结构一致」设阈（直接渲染帧 vs 编码往返帧有系统性色调偏移）
- [x] **P2：「文件 App 导入」通道**（✅ 2026-10-13，真机验收通过）：UIDocumentPicker（asCopy 系统代拷，免 security-scope 管理）多选导入 → 素材库落盘 → 追加时间线；AppModel 导入尾部抽为 `importPipeline` 两渠道共用。spec：[files-import-design](superpowers/specs/2026-10-13-files-import-design.md)
- [x] **P2：转场重叠语义的时长口径统一**（✅ 2026-10-13）：`EditPlan.renderedDuration` = Σ 片段输出时长 − Σ 转场重叠量（dissolve 全额重叠、fade 不重叠），收口于 POCCore `TimelineDuration.swift`；UI 展示、`EditPlanValidator` 转场适配检查、e2e 时长断言统一走此口径
- [x] **P2：导出管线 HDR→SDR 降级选项**（✅ 2026-10-13，真机验收通过）：新增 `ExportOptions` 承载导出配置；App 点「导出」先弹 `ExportPanel`（HDR 开关默认开启）；SDR 档映射为同几何/帧率的 `Codec.h264` preset，由 AVAssetExportSession 自动色调映射到 BT.709；e2e 新增 SDR 专项
- [x] **落地顺序 #1~#5**（✅ 2026-10-08 ~ 10-13）
  - #1 Kadr fork 内部镜像 + 锁版本（2026-10-08）
  - #2 素材导入（2026-10-09）：EditPlan v2 素材登记表（`assets` + `assetID` 引用）+ kadr-photos fork v0.11 + App 相册多选导入（passthrough 优先 → 素材库落盘 → 追加时间线）
  - #3 草稿持久化（2026-10-09）：草稿 = EditPlan JSON（与 Agent 契约同格式）；`DraftStore` 原子写入 + sortedKeys 字节稳定 + schema 版本守卫 + 完整性守卫（存在性 + 元数据重探测比对）；**决策：不引入 kadr-persistence**（它持久化引擎层 `Video`，恢复需反向桥且丢素材登记表语义），不做 SHA-256 内容寻址
  - #4 POC 取舍清理入 backlog 定级（2026-10-09）
  - #5 音频 / 拍摄 / MCP 化决策（2026-10-13，结论见「决策记录」v1 范围）
- [x] ~~素材导入侧的 P3 项~~ iOS 17 底线覆盖率调研：**已移除**（2026-10-14）——iOS 17 以下用户占比已可忽略，不构成决策依据

### 阶段：立项（2026-10-08 ~ 10-09）

- [x] **路径 A 立项：Kadr 全家桶直达**（2026-10-08）：POC 五关键字（多段拼接 / 转场 / 变速 / 字幕 / headless 导出）+ EditPlan JSON → DSL 端到端 + 4K HDR CLI 侧全部 ☑
- [x] **HDR 直通定调为特性**（2026-10-09，见「决策记录」）

## 决策记录（长期有效）

- **HDR 直通是特性**（2026-10-09）：导出保留 BT.2020 + HLG 元数据，定位「HDR 全链路」；素材导入侧 passthrough 优先（不重编码、保 HDR/高帧率）；分享到不支持 HDR 平台的发灰问题由导出侧 SDR 降级选项消化（已落地）
- **Kadr 依赖走内部镜像 fork**（2026-10-08）：`timehzy/kadr`、`timehzy/kadr-captions`、`timehzy/kadr-photos`，版本约束不变。fork 不自动跟随上游：第一次需要上游修复时给三个 fork 配 `upstream` remote，手动同步、跑完全部测试再合入
- **v1 范围**（2026-10-13）：拍摄出局；音频整体后置；MCP 化改写为「剪辑 Agent」入 v1——MCP 是跨产品工具互操作协议，App 内没有第二个消费方，内嵌 LLM 直接 function calling 即可，套 MCP 只多一层序列化开销；剪辑真正难的是编排（镜头选择/节奏/叙事），不是工具调用。**MCP server 显式降级为未来分发渠道**（如桌面 AI 客户端远程驱动剪辑），工具层设计干净后 MCP 只是一层薄包装
- **剪辑 Agent 架构三层**（2026-10-13）：① 工具层 = `EditStore` 操作封装为 agent-facing function schema（编辑必经 `EditStore.apply`，自带校验护栏）；② 编排层 = agent loop + 剪辑领域 prompt + `EditPlanValidator` 报错回喂的反馈环；③ headless 先行 = CLI 跑通「自然语言 → EditPlan JSON → validate → export」全链路再进 App UI
- **字幕预览 = 时间对位示意层**（2026-10-13）：UI 合成预览只承担静态字幕（v1 不做字幕动画），只承诺时间/位置模板正确、不承诺像素一致——字幕是唯一例外的理由：预览诉求是时间对位而非像素保真，且文字恰是 UI 渲染优于烧录预览的内容类型。**UI 口禁入清单**：贴纸/水印（静态也暂不）、属性动画、资产驱动动画——各自正确路径：几何变换（裁剪/旋转）与多镜头/PiP 走 videoComposition；动态贴纸走 HEVC-with-alpha 视频轨道（LumaFusion 同款路线）；程序化特效（粒子/shader）v1 不做。护栏 = 导出帧快照（`FrameSnapshotter` + CLI `snapshot` 子命令，人工比对 + Agent 自检）。**未来触发条件**：出现第一个「必须精确预览」的效果（滤镜/调色、HDR 字幕观感投诉等）→ 启动自定义 `AVVideoCompositing` 专项（动 Kadr fork 渲染管线，预览导出共享合成器，弃 CoreAnimationTool 路线）；`PreviewBridge` 抽象已为此预留
- **代码起点 = 基于 POC 直接演进**（2026-10-13）：不新开工程/仓库——POC 三层分层本就是为正式版设计的，v1 任务全为增量；测试 + CLI 契约 + e2e + git 历史/已知坑记录是地基，重写纯损耗。**不动清单**：CLI stdout JSON 契约、draft.json 格式、测试套件、三层依赖方向
- **素材导入选型 = kadr-photos fork**（2026-10-09）：YPImagePicker 出局（选中后强制重编码才给回调，HDR/full-range 元数据有丢失先例、4K 大文件内存爆炸史，与 HDR 直通特性直接冲突；内置 trimmer/滤镜与 Kadr 管线重复建设；需 readWrite 全量授权；双 `.exact` 依赖）；原生 PhotosPicker 出局作为长期方案（`loadTransferable` 可用但 iCloud 进度、慢动作保帧率、Live Photo、typed error 都要自建，选择器 UI 零定制撑不起 App 内素材库）；kadr-photos 入选（PHAsset→文件 URL 异步桥——iCloud 进度/慢动作/Live Photo/typed error 正是缺的；`assets(in:)` 相册列举可支撑自建素材库 UI；Apache-2.0 与镜像策略同构）
