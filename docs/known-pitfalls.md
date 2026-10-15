# 已知坑（运行时 / 行为类）

> 排障事实知识库：记录症状的根因与背景，按主题分组。**约束条款不在这里**——凡已被立规的条目，规则以 [架构公约](architecture-covenant.md) 为准，本文只留成因事实并指向公约章节。构建/编译期高频坑在 [AGENTS.md](../AGENTS.md)。

## LLM 接入（AnyLanguageModel）

- **Anthropic provider 一次 respond = 一次 HTTP 请求，不内部续轮**（2026-10-13 wire 报文实证）：模型返回 tool_use 后，provider 执行工具、把 toolCalls + toolOutput 入 transcript 就返回了，**不会**自动发第二个请求让模型消化结果——续轮是调用方职责，`EditAgentSession` 的 outer loop 就是 agent loop 本体（「本轮有工具调用 → 必须续轮」是硬规则，否则会像初版一样工具调完就静默收工）。README 说的「自动 tool loop」只适用于 MLX/llama.cpp 等本地 provider
- **`max_tokens` 缺省 1024**（`GenerationOptions.maximumResponseTokens ?? 1024`）：思维链模型（K2.8 thinking-only、Claude extended thinking）思考先烧预算，1024 极易在思考中途截断 → 返回空 content + 无 tool call → 表现为「模型静默收工」。必须显式放大（`AgentRunConfiguration.maxResponseTokens` 默认 32768）
- **String 工具输出会被收进 structure 段**：`String` 是 `ConvertibleToGeneratedContent`，`Tool.makeOutputSegments` 优先走 structure 分支而非 text——宿主侧解析 `Transcript.ToolOutput` 要兼顾 `.structure`（还原方式：`try? String(content)`），只看 `.text` 会拿到空串
- **Kimi coding 端点（api.kimi.com/coding/）实测**（2026-10-13）：Anthropic 兼容，`x-api-key` 与 `Bearer` 均接受；`GET /v1/models` 可用；图片输入（base64 image block）正常，snapshot 视觉自检回喂链路已验证（模型能准确描述烧录字幕与画面内容）

### 剪辑 Agent：store 串行性前提

- **DirectStoreScheduler 不强制串行**：`AgentRunContext.withStore` 的串行性建立在「provider 顺序执行工具调用（逐个 await Tool.call）」这一事实上——框架契约本身**允许并发触发** `Tool.call`，调度器内无锁保护，并发调用方触碰共享 EditStore 即数据竞争。Anthropic provider 实测顺序执行，但 **AnyLanguageModel 升级或换 provider 时必须复核这一点**；一旦存在并发触发可能，Direct 调度器须换成带串行化保护的实现（MainActorStoreScheduler 天然串行）

## 引擎行为

- **AVAssetImageGenerator 可渲 animationTool（2026-10-13 探针验证）**：挂导出式 videoComposition（含 `AVVideoCompositionCoreAnimationTool` 层树 + `CAKeyframeAnimation` 时间窗，beginTime=`AVCoreAnimationBeginTimeAtZero`）抽帧，overlay 按时间窗正确显隐——`Video.renderedFrame(at:)`（fork v1.2.0）即建于此。但**直接渲染帧 ≠ 导出解码帧**：无编码压缩痕迹，且与 HEVC 编码往返存在系统性色调偏移（样例红底帧实测全图 meanAbs≈12/255，diff>32 像素仅 0.025% 且集中在字幕抗锯齿边缘）——比对断言要按「结构一致」设阈（大差异占比），不能逐像素近似
- **字幕不进预览**：Kadr 官方明确 overlay 仅导出时烧录（`AVVideoCompositionCoreAnimationTool`），`makePlayerItem()` 预览无字幕；App 用 SwiftUI Text 叠加层按播放器时间近似显示（降级登记与约束见架构公约 §6.4）
- **转场重叠语义**：dissolve 与相邻片段全额重叠（扣 duration），fade 不重叠（各占相邻片段内 duration/2，总长不变）——渲染时长 ≠ `Video.duration` 求和值（样例工程实测 9.5s vs 10.5s，与 Kadr CompositionBuilder `overlap(during:)` 一致）；时长口径约束见架构公约 §3.3
- **预览 player 生命周期**：旧 player 的回收依赖 dealloc（时机不受控），`PlayerController.rebuild()` 不主动停旧实例会出现「界面无播放器却有声音」的孤儿播放；rebuild 的 await 期间可能又来一次 rebuild。生命周期约束见架构公约 §6.3
- **导航 push 不暂停 AVPlayer**：剪辑页被 push 覆盖（如进素材库）后预览音频继续播放，需 onDisappear 显式 `pause()`、onAppear `resumeIfNeeded()` 续播；续播意图标记若放在 `rebuild()` 里消费，覆盖页内的编辑（素材库 quick-add）触发 rebuild 会把音频重新放出——意图必须在页面层消费，rebuild 只认 `rate`。约束见架构公约 §6.3
- **AVAssetWriter 产物字节不确定**：mp4 容器嵌入写入时间戳，同参数两次合成得到不同字节——内容寻址（SHA-256 去重）相关测试不能用「两次合成」冒充「同内容」，要合成一次再拷贝副本（AssetLibraryTests 实测踩过）
- **转场预览直通怪癖（iOS 26 模拟器实测）**：转场路径（双视频轨 composition）中素材分辨率恰等于 preset renderSize 时，显示管线把解码 buffer 直通 CA image queue，像素格式被拒（-11800 / 底层 -19230）→ `AVPlayerItemFailedToPlayToEndTime`，播到转场即停；identity transform 微扰无效（判定基于尺寸相等），`PreviewBridge.breakRenderSizeEquality` 给 renderSize 加 0.5pt 规避。注意 `AVPlayerItem.videoComposition` setter 是 copy 语义，改完要 mutableCopy 赋回。真机已验证无此问题（2026-10-12），微扰为模拟器保留；正式版发布前再移除或按模拟器条件编译（见 roadmap backlog；降级登记见架构公约 §6.4）
- **Kadr ImageClip 拉伸图片到 preset 画幅（不保宽高比）**（2026-10-15 实测：100×100 方图导出 1080×1920 整帧填充）：`ImageEncoder.createPixelBuffer` 把 CGImage 直接 `draw(in: 全画幅 rect)`，非匹配宽高比的图片被压扁/拉长。规避：`EngineBridge` 交给 Kadr 前先用 `StillImagePreparer` 把图片等比 aspect-fit 居中贴到 preset 画幅黑底画布（`preset.resolution`），之后 Kadr 的拉伸变为恒等缩放。`ImageClip.background(_:)` 不能替代——`insertImageClip` 调 `ImageEncoder.encode` 时未传 backgroundColor，该修饰符在此路径不生效
- **Kadr ImageClip 内部物化**：`CompositionBuilder.insertImageClip` 每次构建 composition 都把图片按 preset 分辨率+帧率编码成临时 mp4、插入后即删。我们层无需物化/缓存/登记表扩展；代价是图片工程每次 rebuild 都有一次编码开销（当前可接受）

## 文件系统（Foundation）

- **macOS `/var` → `/private/var` firmlink**：`FileManager.temporaryDirectory` 返回 `/var/...`，而 `enumerator(at:)` 返回的 URL 带 `/private/var/...` 前缀（`resolvingSymlinksInPath()` 不解析 firmlink）——按字符串前缀裁剪相对路径会静默错位（ZipArchive 曾因此打出 0 条目的包）；要相对路径用 `enumerator(atPath:)`（天然返回相对路径）

## 相册集成（kadr-photos）

- **resolver 要授权**：`PhotosClipResolver` 要求 readWrite 授权（.authorized/.limited），即使 PHPicker 本身免授权——导入前必须先 `PhotosBridge.requestReadAccess()`；App 需 `NSPhotoLibraryUsageDescription`
- **默认 preset 降帧率**：`AVAssetExportPresetHighestQuality` 会把高帧率视频压到 30fps。`PhotosBridge` 优先 passthrough（保 HDR/高帧率且秒级完成），失败回退重编码——改这段逻辑时保留这个顺序
