# 基于 AVFoundation 的 iOS 开源视频剪辑框架选型调研报告

> 调研日期：2026-09-28 · 目标：Apple 平台通用视频剪辑 App（iOS 优先，兼顾 macOS）· 团队规模：1-2 人 side project · 扩展方向：AI 剪辑 Agent（CLI/MCP 化）

---

## 摘要（TL;DR）

在「纯开源 + AVFoundation + Swift + 持续维护」四个条件取交集后，真正值得认真评估的只有四个框架：**Kadr**、**Cabbage**、**VideoLab**、**VideoEditorKit**。其中 **Kadr** 是唯一同时满足「活跃维护 + Swift 6 现代技术栈 + 引擎与 UI 分包 + 功能近全覆盖 + DSL 可被 Agent 生成与序列化」的选项，是本报告的首推；Cabbage 是经得起时间考验的保守底座；VideoLab 是最好的架构参考书。

两个补充约束让结论进一步收敛：**1-2 人 side project** 意味着「fork 并长期自养一个停更框架」的隐性成本被放大——Cabbage 的 47 个 open issue 和 VideoLab 始终躺在 TODO 里的变速功能，在小团队手里都是真实的时间黑洞；**未来要接入 AI 剪辑 Agent（CLI/MCP 化）** 意味着框架的「时间线表达方式」必须能被程序生成与序列化——一个只能被 UI 手势驱动的命令式 API，在 Agent 场景下等于不存在。在这两条约束下，Kadr 的优势从「领先」变成了「几乎唯一可选」：它的 result-builder DSL 本身就是一段可被 LLM 生成、可被 JSON 序列化、可在无 UI 环境下执行的代码。

---

## 1. 背景与调研范围

本项目的目标是基于 AVFoundation 构建一款 Apple 平台通用视频剪辑 App，功能至少覆盖：多段视频的裁剪、调色、滤镜、转场、BGM、变速、画幅调整、字幕、贴纸。团队希望基于优秀的开源框架开发以减少前期成本，对框架的要求包括：设计优秀、数据逻辑清晰、UI 与逻辑分离（如带 UI）、较强扩展性、持续维护、Swift 技术栈。后续补充了两个关键背景：团队仅 1-2 人，属于个人 side project；同时需要接入 AI 做剪辑 Agent，框架既要满足现有的 UI 驱动，也要能够支持未来的 CLI/MCP 化。

调研范围限定为「基于 AVFoundation 的纯开源框架」，商业 SDK（Banuba、img.ly VE.SDK、美摄、BytePlus 等）仅作背景参照，未纳入评估。候选发现渠道包括 GitHub topic 检索（avfoundation / video-editing / video-editor 等）、中文社区选型文章与 awesome-ios 清单交叉验证。仓库指标（star、最后提交、License、语言）为 2026-09-28 通过 GitHub API 实时查询，功能覆盖判断基于各仓库 README、Wiki 与官方文档原文。

一个值得注意的时代背景是：视频处理生态在 2025 年经历了一次「清场」——FFmpegKit 官方退役（2025-01，且其非 AVFoundation 技术路线）、PixelSDK 宣布停服（2025-02，且导出需商业 API key，无 key 带水印，本就不满足纯开源前提）、MetalPetal 作者失联后由社区 fork 出 Raster 接续（2026-08）。老牌选项大面积熄火的同一年，Kadr、VideoEditorKit 等 Swift 6 原生新框架开始冒头。此刻入场选型，本质上是在「成熟但停更」与「新锐但稚嫩」之间做权衡，本报告所有分析都围绕这个权衡展开。

---

## 2. 生态全景：12 个候选仓库

一个完整的剪辑 App 技术栈至少包含五层：剪辑内核（时间线/合成）、渲染与滤镜引擎、编辑 UI、拍摄、素材选择。下表汇总了全部候选的实时 GitHub 指标。

| 仓库 | 分类 | 定位 | Stars | 最后提交 | License | 平台 | 状态 |
|---|---|---|---|---|---|---|---|
| [Kadr](https://github.com/SteliyanH/kadr) | 剪辑内核 | 新锐首选：引擎与 UI 分离的全家桶 | 56 | 2026-09-01 | Apache-2.0 | iOS · macOS · tvOS · visionOS | **活跃维护** |
| [kadr-ui](https://github.com/SteliyanH/kadr-ui) | 编辑 UI | Kadr 的 SwiftUI 组件包 | 6 | 2026-09-01 | Apache-2.0 | iOS · macOS | 活跃维护 |
| [VideoEditorKit](https://github.com/didisouzacosta/VideoEditorKit) | 剪辑内核 | 观察项：门槛过高、功能尚浅 | 19 | 2026-04-30 | MIT | iOS（iPhone） | 活跃维护 |
| [Raster](https://github.com/aldealabs/raster) | 渲染引擎 | MetalPetal 的官方接续 fork | 11 | 2026-08-15 | MIT | iOS · macOS · tvOS · Catalyst | 活跃维护 |
| [Cabbage](https://github.com/VideoFlint/Cabbage) | 剪辑内核 | 经典设计：时间线内核的保守选择 | 1,578 | 2023-11-08 | MIT | iOS | 休眠 |
| [MetalPetal](https://github.com/MetalPetal/MetalPetal) | 渲染引擎 | 滤镜引擎事实标准（原作者已失联） | 2,190 | 2024-04-10 | MIT | iOS · macOS · tvOS | 休眠 |
| [PryntTrimmerView](https://github.com/HHK1/PryntTrimmerView) | 编辑 UI | UIKit 裁剪 UI 的成熟零件 | 907 | 2024-12-11 | MIT | iOS | 低频维护 |
| [GPUImage 3](https://github.com/BradLarson/GPUImage3) | 渲染引擎 | 老牌 Metal 滤镜链，PixelSDK 底层依赖 | 2,876 | 2024-07-25 | BSD-3-Clause | iOS · macOS · Linux | 休眠 |
| [VideoLab](https://github.com/ruanjx/VideoLab) | 剪辑内核 | 设计蓝本：适合作为自研架构参考 | 921 | 2022-10-31 | MIT | iOS | 停止维护 |
| [NextLevel](https://github.com/NextLevel/NextLevel) | 拍摄 | 若 App 含拍摄功能的首选 | 2,332 | 2026-06-08 | MIT | iOS | 活跃维护 |
| [YPImagePicker](https://github.com/Yummypets/YPImagePicker) | 素材选择 | Instagram 式素材选择器 | 4,483 | 2026-07-28 | MIT | iOS | 活跃维护 |
| [SCRecorder](https://github.com/rFlex/SCRecorder) | 拍摄 | Objective-C 时代遗物 | 3,037 | 2021-05-25 | Apache-2.0 | iOS | 停止维护 |

读表需要注意：star 数反映历史共识而非当前健康度——SCRecorder（3,037★）和 GPUImage 3（2,876★）都已实质停更；反之 Kadr（56★）与 Raster（11★）虽然数字寒酸，却是 2026 年仍在以周为单位提交的项目。对「持续维护」有硬要求的选型，应以最后提交时间和版本发布节奏为第一筛子，star 数只作为成熟度的辅助参考。

### 2.1 维护生命线

从创建到最后提交的生命周期图中，有三个值得记住的时刻：**2021 年**，SCRecorder 与 VideoLab 先后定格，标志第一代（Objective-C）与第二代（Swift 4/5）剪辑框架相继退场；**2025 年初**，FFmpegKit 退役、PixelSDK 停服，商业/跨平台路线同时收缩；**2026 年**，Kadr、VideoEditorKit、Raster 三个 Swift 6 时代项目几乎同时出现——生态完成了一次换代。对维护性的判断不能只看「最后一次提交距今多久」，还要看项目是否处于其生命周期的上升段。

---

## 3. 核心候选深度评析

四个进入决赛圈的框架代表了四种不同的设计哲学：Kadr 的「声明式 DSL」、Cabbage 的「最小正交抽象」、VideoLab 的「AE 图层模拟」、VideoEditorKit 的「UI 先行」。

### 3.1 Kadr —— 新锐首选

**元信息**：SteliyanH/kadr · Apache-2.0 · v1.1（2026-09）· iOS 17+ / macOS 14+ / tvOS / visionOS · Swift 6

**双层架构：DSL 外壳 + AVFoundation 引擎。** 公开层是不可变值类型构成的 result-builder DSL（Video / VideoClip / Transition / AudioTrack / Filter），引擎层是 internal 的 CompositionBuilder、FilterProcessor、KadrVideoCompositor（自定义 AVVideoCompositing）、OverlayRenderer、ExportEngine。DSL 冻结于 v1.0 并承诺 semver：1.x 内不删不改不改义，引擎可随意重构。这是四个候选里唯一把「API 稳定性」写成契约的。

**全家桶分包：UI、持久化、字幕、音频、相册各自独立。** kadr-ui（SwiftUI 时间线/预览/转场选择器/关键帧编辑器）、kadr-persistence（工程文件存取 + 完整性守卫）、kadr-audio（LUFS 响度、配音录制）、kadr-captions（SRT/VTT/iTT/ASS/SSA）、kadr-photos（PHAsset 桥接）五个伴随包全部只依赖 kadr 的公开 API。另有一个完全基于公开 API 构建的参考编辑器 Kadr Studio——作者称正是用「外部消费者」视角发现了 7 个内部测试看不见的 API 空洞。

**数据逻辑：声明即时间线，天然 Agent 可读。** 剪辑状态就是一棵不可变的 DSL 树：片段裁剪是 `trimmed(to:)` 闭区间，转场是时间线里的一等元素，变速是 `.flat` 与 `.curved` 的编译期互斥枚举，音频 ducking/crossfade 按声明顺序语义化。关键帧以片段相对时间定义，预览（`makePlayerItem`）与导出（`export`）共用同一套动画驱动。这不仅是 UI 友好的设计，更是让 LLM 能「写出合法剪辑程序」的关键——Agent 生成的是意图，不是命令序列。

```swift
let url = try await Video {
    VideoClip(url: introURL).trimmed(to: 0...3)
    Transition.dissolve(duration: 0.5)
    VideoClip(url: actionURL).trimmed(to: 0...4)
        .speed(0.5)                          // 半速慢放，保调
        .filter(.brightness(0.05), .contrast(1.1), .saturation(1.2))
}
.overlay(
    TextOverlay("CHAPTER ONE", style: TextStyle(fontSize: 80, weight: .bold))
        .visible(during: 0.0...2.0)
        .animation(.fadeIn(duration: 1.0))
)
.audio {
    AudioTrack(url: musicURL).volume(0.6).ducking(0.2)  // BGM 闪避人声
}
.preset(.reelsAndShorts)                   // 9:16 画幅预设
.export(to: outputURL)
```

一段 DSL 同时覆盖：多段裁剪、转场、变速、调色、字幕动画、BGM 闪避、画幅预设、导出。

**优势**：

- 唯一同时满足：活跃维护 + Swift 6 严格并发 + UI/逻辑分离 + 功能近全覆盖
- DSL 可序列化（kadr-persistence），headless 导出（`exporter.run()`），Agent/CLI/MCP 化路径最短
- 变速 0.25x–4x 保调（spectral/timeDomain/varispeed 三算法）且支持曲线变速，竞品全无
- 字幕链路完整：从 SRT/ASS 解析到动画烧录一体打通
- Apache-2.0 附带明确专利授权条款，对视频编解码场景比 MIT 更稳妥
- iOS / macOS / tvOS / visionOS 全平台，契合「Apple 平台通用」目标

**风险**：

- 单作者项目，2026-04 才创建，56 star，无生产环境大规模验证
- iOS 17 起步意味着放弃老设备；UIKit 项目接入需包一层 SwiftUI
- 自定义 Metal shader 能力目前依赖 CIFilter/compositor 桥接，不如 VideoLab 直接
- 缓解措施：Apache-2.0 允许自由 fork；建议 fork 一份内部镜像并跟进其 semver 节奏；对 1-2 人团队，「不自养依赖」的价值大于「完全掌控」

### 3.2 Cabbage —— 经典设计，保守底座

**元信息**：VideoFlint/Cabbage · MIT · 1,578★ · 最后提交 2023-11 · iOS 9+ · Swift（4 时代代码风格）

**四层概念：Resource → TrackItem → Timeline → CompositionGenerator。** Resource 抽象数据源（视频/图片/音频，可继承扩展出 GIF 等自定义源），TrackItem 挂视频配置（transform/透明度/自定义滤镜链）与音频配置（音量/自定义处理节点），Timeline 是带 videoChannel/audioChannel 双通道的时间轴容器，CompositionGenerator 负责把 Timeline 翻译成 AVPlayerItem / AVAssetExportSession / AVAssetImageGenerator 三件套。概念少而正交，学习曲线平缓。

**扩展协议设计干净。** VideoConfigurationProtocol 接自定义图像滤镜、AudioConfigurationProtocol 接自定义音频处理、Resource 子类化接自定义数据源、videoTransition/audioTransition 接自定义转场。作者在 Wiki 里有一篇高质量的《iOS 视频编辑核心架构》长文，把 AVFoundation 原生 API 的繁琐之处（轨道时间信息易被变速/转场破坏、photo 与 video 难以混排、仅支持 transform 和音量两个基础操作）分析得非常透，本身就是优秀的架构教材。

```swift
// 1. 创建资源
let resource = AVAssetTrackResource(asset: asset)
// 2. TrackItem 挂载配置
let trackItem = TrackItem(resource: resource)
trackItem.configuration.videoConfiguration.baseContentMode = .aspectFill
// 3. 放入时间线
let timeline = Timeline()
timeline.videoChannel = [trackItem]
timeline.audioChannel = [trackItem]
// 4. 生成 AVFoundation 三件套
let generator = CompositionGenerator(timeline: timeline)
generator.renderSize = CGSize(width: 1920, height: 1080)
let playerItem = generator.buildPlayerItem()
let exportSession = generator.buildExportSession(presetName: AVAssetExportPresetMediumQuality)
```

四步完成合成：资源 → 配置 → 时间线 → 生成器。扩展点全部走协议。

**优势**：1.5k star + 多年生产使用，设计共识充分；概念模型简单正交，二次开发心智负担低；MIT + iOS 9 起步兼容性极宽；中文文档与架构文章完善，国内团队友好。

**风险**：2023-11 后零提交，47 个 open issue 无人处理，实质进入社区托管状态；Swift 4 时代代码，无 async/await 与严格并发，接入 Swift 6 工程需自行改造；无内置滤镜/字幕/贴纸实现，变速需自处理时间映射——大量功能要搭配 MetalPetal/Raster 或自研补齐；纯逻辑无 UI，编辑界面从零搭建。Agent 化方面，Agent 需要理解并生成大量命令式配置（TrackItem 逐字段赋值），且 Timeline 无持久化层，草稿/Agent 指令格式要自己造。

### 3.3 VideoLab —— 架构蓝本，适合阅读不适合依赖

**元信息**：ruanjx/VideoLab · MIT · 921★ · 最后提交 2022-10 · iOS 11+ · Swift · AVFoundation + Metal

**AE 式图层模型：RenderLayer / RenderComposition / VideoLab。** 直接把 After Effects 的合成思想搬进 AVFoundation：每个视频/图片/音频/特效都是 RenderLayer，RenderComposition 是画布（帧率、尺寸、CALayer 矢量动画），VideoLab 负责产出播放器与导出会话。自定义 AVVideoCompositing 合成器用 Metal 逐帧渲染，性能上限高于纯 instruction 方案。

**动画系统是唯一真完整的。** Animatable 协议 + KeyframeAnimation（keyPath/values/keyTimes/timingFunctions）可以对 Transform、透明度乃至自定义特效参数（如变焦模糊的 blurSize）做关键帧动画；RenderLayerGroup 实现 AE 式预合成。这套设计直接启发了后来者对「剪辑引擎动画系统该怎么写」的认知。

**正确用法**：2022-10 停更至今 4 年，变速功能始终是 TODO，无人认领；CocoaPods 分发为主，无 SPM 一等支持。fork 或阅读其设计文档作为自研蓝本，而不是直接依赖。Agent 化方面，AE 式图层模型对 UI 友好，但 Agent 需要理解图层坐标、锚点、预合成等视觉概念，且 RenderComposition 无持久化方案，是四个候选中 Agent 化成本最高的。

### 3.4 VideoEditorKit —— 思路相反的一极

**元信息**：didisouzacosta/VideoEditorKit · MIT · 19★ · 创建于 2026-04 · iOS 18.6+ / Swift 6 · SwiftUI

直接提供一个可 present 的完整 SwiftUI 编辑器（裁剪、速度、裁剪预设、画布缩放平移、旋转镜像、亮度对比度饱和度、字幕覆盖层、导出质量选择），编辑状态可序列化，宿主通过配置项控制行为。技术栈极新：Swift 6 + Observation + PhotosUI + Swift Testing。真正开箱即用，从零到有编辑界面只需几十行代码；可序列化编辑状态是刚需功能的现成实现。

但 iOS 18.6+ 起步等于只服务 2026 年后的系统版本，安装基数极小；仅支持单视频编辑：无多段拼接、无转场、无贴纸、无多音轨——与目标功能清单差距大；单作者、19 star，方向是「嵌入式轻编辑器」而非「通用剪辑引擎」。本项目场景下仅作观察。

---

## 4. Agent / CLI / MCP 亲和性

这是本次选型最容易被忽略、但对「AI 剪辑 Agent」目标最致命的一个维度。剪辑框架的 API 风格决定了 Agent 是「生成一段意图」还是「模拟一堆点击」。同时，MCP 生态里已有 [mcp-video](https://mcpmarket.com/server/video-editor-4)（Python/FFmpeg，26 个结构化工具）和 [BlitzReels](https://blitzreels.com/agents)（云端 MCP/CLI/API）等参照——它们的共同点是**把剪辑抽象为「结构化工具调用」而非「UI 操作回放」**。一个 Apple 平台框架能否进入这个生态，取决于它的 DSL 能否被序列化、被 LLM 稳定生成、在无 UI 环境执行。

| 维度 | Kadr | Cabbage | VideoLab | VideoEditorKit |
|---|---|---|---|---|
| DSL 可生成性 | result-builder 树，LLM 可直接写出合法剪辑程序 | 命令式配置，Agent 生成的是胶水代码 | 图层对象组装，概念偏重 | UI 配置项，非剪辑抽象 |
| 序列化 | kadr-persistence 内置（内容寻址+完整性守卫） | 无，需自建 schema | 无，需自建 | 内置（编辑状态可序列化） |
| headless 导出 | `exporter.run()` 返回 AsyncThrowingStream，不依赖 UI | 可行但需自行封装 | 可行但代码路径与预览分叉 | 绑定 SwiftUI 场景 |
| 综合评价 | **AGENT-READY** | REQUIRES ADAPTER | REQUIRES ADAPTER | 轻量场景可用 |

结论：Kadr 是四个候选中唯一把「可被程序生成」作为设计目标的——它的 DSL 冻结承诺（semver）意味着 Agent 生成的代码不会在下个小版本失效；`EditPlan → DSL → Export` 的链路已经被 persistence 包打通。Cabbage 和 VideoLab 并非不能 CLI 化，而是需要你在框架之上再包一层「意图 → 命令」的翻译器，对 1-2 人团队来说这是额外且长期的维护负担。

---

## 5. 功能覆盖矩阵

以目标功能清单为行、四个核心候选为列。✅ 开箱即用、◐ 有扩展点但需自建、— 不支持。

| 功能 | Kadr | Cabbage | VideoLab | VideoEditorKit |
|---|---|---|---|---|
| 多段视频拼接 / 裁剪 | ✅ DSL 多轨 + `trimmed(to:)` | ✅ Timeline 双通道 | ✅ RenderLayer timeRange | — 仅单视频 |
| 调色 | ✅ 内置亮度/对比/饱和/曝光等可动画滤镜 | ◐ 需自接 CIFilter | ◐ 需自定义 Metal Operation | ✅ 亮度/对比度/饱和度 |
| 滤镜 / LUT / 自定义特效 | ✅ 滤镜目录+LUT+KadrVideoCompositor 自定义逐帧合成 | ◐ 扩展协议完备但需全自写 | ✅ BasicOperation 自定义 Metal 特效，自带 LUT | — 无滤镜目录 |
| 转场 | ✅ `Transition.fade/dissolve/slide` 一等公民 | ✅ videoTransition 可自定义 | ✅ Transform+透明度动画构造 | — |
| BGM / 音频混合 | ✅ 时间锚定音轨、ducking、crossfade；kadr-audio 提供 LUFS 响度 | ✅ 独立通道+音频处理协议 | ✅ 音高+音量渐变 | ◐ 单录制音轨混合 |
| 变速 | ✅ 0.25x–4x 保调（三算法）+ 曲线变速 | ◐ 需自行处理时间映射 | — README TODO，从未实现 | ✅ 播放速度调节 |
| 画幅 / 画布调整 | ✅ 画幅预设 + crop + renderSize | ✅ renderSize + baseContentMode | ✅ renderSize + 每层 Transform | ✅ 裁剪预设+画布缩放平移 |
| 字幕 | ✅ kadr-captions 解析五种格式→动画烧录 | ◐ 需自建 | ◐ CALayer 文字动画需自搭建 | ✅ 转写生成+可编辑覆盖层 |
| 贴纸 / 图片覆盖 | ✅ StickerOverlay/ImageOverlay 可动画 | ◐ ImageResource 可作贴纸层 | ◐ 图片可作 RenderLayer | — 仅导出图片水印 |
| 关键帧动画 | ✅ Animation<T> 片段相对时间，预览导出一致 | ◐ KeyframeVideoConfiguration | ✅ Animatable+KeyframeAnimation | — |
| 画中画 / 多轨叠加 | ✅ 命名多轨+Track 并行块 | ◐ 时间区重叠需自管层级 | ✅ AE 式图层+预合成 | — |
| 编辑状态持久化 | ✅ kadr-persistence 内容寻址+完整性守卫 | — 需自行序列化 | — 需自行实现 | ✅ 核心卖点 |
| 现成 UI 组件 | ✅ kadr-ui 独立包 | — 纯逻辑 | — 纯逻辑 | ✅ 完整 SwiftUI 编辑器 |

矩阵的结论一目了然：**Kadr 是唯一在 13 个维度上全部「开箱即用」的框架**——尤其在变速（保调 + 曲线）、字幕（五种格式解析到动画烧录）、工程持久化这三个剪辑 App 的高门槛功能上，其余候选均存在明显缺口。Cabbage 与 VideoLab 的「◐」集中于同一原因：它们提供的是正确、干净的扩展协议，但协议背后的实现（滤镜、字幕渲染、贴纸交互）需要你自己填——这正是「基于它们开发」的真实成本所在。

---

## 6. 需求匹配评估

八个评估维度各按 1–5 打分，分数为本报告基于代码阅读与文档分析的判断。已按团队背景预置权重：Agent 亲和性与小团队适配均设为最高档（5），成熟度维持低位（2）——因为 side project 阶段「没人替你维护」比「没人用过」更危险。

| 维度（权重） | Kadr | Cabbage | VideoLab | VideoEditorKit |
|---|---|---|---|---|
| 架构设计（5） | 5 | 4 | 4.5 | 3.5 |
| 扩展性（4） | 4.5 | 4 | 4.5 | 3 |
| 维护活跃度（5） | 5 | 1.5 | 1 | 4 |
| 功能完备度（4） | 5 | 3 | 4 | 2.5 |
| 成熟度 / 社区（2） | 2 | 3.5 | 3 | 1.5 |
| 现代 Swift（3） | 5 | 2.5 | 3 | 5 |
| Agent 亲和性（5） | 5 | 3.5 | 3 | 3 |
| 小团队适配（5） | 4.5 | 2 | 1.5 | 3.5 |
| **加权总分** | **≈4.6** | **≈2.8** | **≈2.8** | **≈3.4** |

一个有意思的实验：把「Agent 亲和性」和「小团队适配」都拉到 0，再把「成熟度」拉到 5——Cabbage 会短暂反超。但这正是 side project 的陷阱：成熟度的分数来自历史，而你要维护的是未来。

---

## 7. 选型建议

综合功能覆盖、架构质量、维护现实与 Agent 化路径，给出三条可执行的落地路径。**默认推荐 A**。

### 路径 A：Kadr 全家桶直达（默认推荐）

适合：1-2 人 side project、需快速覆盖全功能、未来要 CLI/MCP 化、可接受 iOS 17+。

| 环节 | 选型 |
|---|---|
| 剪辑引擎 | kadr（DSL + 引擎，Apache-2.0，Agent 可直接生成） |
| 编辑 UI | kadr-ui（TimelineView / VideoPreview / TransitionPicker / ClipSplitter / KeyframeEditor） |
| 字幕 | kadr-captions（SRT / VTT / iTT / ASS / SSA → 动画烧录） |
| 音频 | kadr-audio（LUFS 响度、配音录制、ducking） |
| 草稿 / Agent 指令 | kadr-persistence（内容寻址 + 完整性守卫，天然是序列化格式） |
| 素材导入 | kadr-photos 或 YPImagePicker |
| 拍摄（可选） | NextLevel |
| CLI/MCP 化 | 基于 kadr-persistence 的 EditPlan JSON → DSL 映射，参考 mcp-video 的 26 工具抽象 |

对 1-2 人团队，这是唯一「不自养任何依赖」的方案。Agent 化路径最短：LLM 生成 JSON EditPlan → 反序列化为 Kadr DSL → headless 导出。第一天就 fork 内部镜像，锁定 `from: "1.0.0"`。

### 路径 B：Cabbage 内核 + MetalPetal/Raster 滤镜

适合：要求代码完全自主可控、团队有能力长期自养依赖、需兼容 iOS 9-16 老设备。

| 环节 | 选型 |
|---|---|
| 剪辑内核 | Cabbage（fork 后自维护，iOS 9+） |
| 滤镜/渲染 | MetalPetal 1.26 兼容线，或 Raster 2.x（MTI* API 不变） |
| 转场 | Cabbage videoTransition + MetalPetal MTTransitions |
| 裁剪 UI | PryntTrimmerView（UIKit）或自研 SwiftUI 组件 |
| 字幕/贴纸 | 基于 Cabbage ImageResource / CALayer 自建 |
| 拍摄（可选） | NextLevel |
| CLI/MCP 化 | 需自建「意图 → TrackItem 配置」翻译层，工作量约等于半个框架 |

真实成本：你接手的是两个停更项目（Cabbage 2023-11、MetalPetal 2024-04）。对 1-2 人团队，47 个 open issue 和缺失的变速/字幕/贴纸实现，会吃掉本应用于产品差异化的时间。

### 路径 C：以 VideoLab 为蓝本自研引擎

适合：追求极致特效性能（Metal shader 级）、有专职音视频工程师、周期充裕。

| 环节 | 选型 |
|---|---|
| 架构蓝本 | VideoLab 的 RenderLayer / KeyframeAnimation / 预合成模型 |
| 机制教材 | Cabbage Wiki《iOS 视频编辑核心架构》+ VideoLab《框架设计与实现》 |
| 合成器 | 自定义 AVVideoCompositing + Metal（参考 VideoLab 实现） |
| 滤镜 | Raster（HDR/广色域正确性是其重点） |
| CLI/MCP 化 | 自研引擎的最大优势：可以把 DSL 设计成 Agent-first 的声明式格式 |

成本最高但天花板也最高。对 side project，建议先用方案 A 验证产品，特效性能成为瓶颈时再演进到此方案——那时已经有真实用户，可以支撑自研。

---

## 8. 风险登记册

| 风险 | 说明 | 缓解措施 | 等级 |
|---|---|---|---|
| 单作者依赖 | Kadr / VideoEditorKit 均为单作者项目 | fork 预案 + API 契约审查 + 关键路径封装隔离；Kadr 的 semver 冻结承诺降低升级风险 | 中 |
| HDR / 广色域 | 多数开源框架对 10-bit HDR 剪辑管线支持不完整；Raster 把 HDR 正确性列为重点但视频非其优先级 | 立项即测 HDR 素材端到端（预览+导出）链路 | 中 |
| 编解码专利 | H.264/HEVC 触及专利池 | 优先选 Apache-2.0（含专利授权条款）的项目；商用前做合规确认 | 低 |
| Swift 6 迁移 | Cabbage / VideoLab 为严格并发前的代码 | 若选方案 B，先做并发审计再接入 | 中 |
| 模拟器渲染 | Metal 系滤镜在 Simulator 上部分不可用（如 MPS 滤镜） | 真机测试纳入 CI | 低 |
| Agent 指令漂移 | LLM 生成的剪辑 JSON 可能超出 DSL 表达能力或包含非法时间区间 | EditPlan schema 校验 + 非法指令的降级策略（如忽略/截断） | 中 |
| side project 时间 | 1-2 人团队同时维护 App + Agent 接入层，易过载 | 严格遵循方案 A 的「零自养」原则；UI 用 kadr-ui 原型，差异化功能后置 | 中 |

---

## 9. 淘汰名单

以下项目在检索中出现频率较高，但经核实不满足「纯开源 + 持续维护」前提，记录在此以免重复评估。

| 项目 | 淘汰原因 |
|---|---|
| [PixelSDK](https://github.com/GottaYotta/PixelSDK) | 官方宣布 2025-02-03 停服；且导出需商业 API key（无 key 带水印），本就不满足纯开源前提 |
| [BBMetalImage](https://github.com/Silence-GitHub/BBMetalImage) | 2022-10 后停更，80+ 滤镜资产尚可但无人维护，不如 MetalPetal/Raster 一脉 |
| [SCRecorder](https://github.com/rFlex/SCRecorder) | Objective-C 时代产物，2021 年后停更，分段拍摄需求由 NextLevel 接替 |
| [MetalVideoProcess](https://github.com/metal-by-example/MetalVideoProcess) | 2020 年停更的 GPUImage3 衍生实验项目，仅具考古价值 |
| [FFmpegKit](https://github.com/arthenica/ffmpeg-kit) | 2025-01 官方退役；且其非 AVFoundation 技术路线，与本项目前提不符 |
| YiVideoEditor 等玩具级库 | 2021 年前后停更，只覆盖旋转/水印等零散功能，无时间线抽象 |

---

## 10. 调研方法与数据说明

调研范围限定为「基于 AVFoundation 的纯开源框架」，商业 SDK（Banuba、img.ly VE.SDK、美摄、BytePlus 等）按用户要求仅作背景参照、未纳入评估。候选发现渠道：GitHub topic 检索（avfoundation / video-editing / video-editor 等）、中文社区选型文章、awesome-ios 清单交叉验证。

仓库指标（star / 最后提交 / License / 语言）为 2026-09-28 通过 GitHub API 实时查询；功能覆盖判断基于各仓库 README、Wiki 与官方文档原文。功能矩阵中的「部分支持」意味着框架提供了正确的扩展协议但无开箱实现；评估打分为分析性判断，已尽量标注依据，建议结合自身 POC 验证。

**下一步建议**：正式立项前，用 Kadr 跑一个覆盖「多段拼接 + 转场 + 变速 + 字幕 + headless 导出」的最小 POC，重点验证：① LLM 生成 EditPlan JSON → DSL 的端到端稳定性；② iOS 17 底线对目标用户群的覆盖率；③ 4K HDR 素材的预览与导出表现。

---

*本报告仅供技术选型参考，不构成法律意见；License 合规请在商用前复核。*
