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
- **预览播放器生命周期 → 两个播放实例**：`AVPlayer` 不在 SwiftUI 视图树里，旧实例回收依赖 dealloc（时机不受控）——「界面无播放器却有声音」只能靠显式 `pause()` 杜绝。实测踩过三次，同一病根（播放意图散落多处 + 重建有 async 窗口）：(1) `rebuild()` 换实例不停旧的；(2) 剪辑页被 push 覆盖（进素材库）时 AVPlayer 不自动停，页面须显式停/续；(3) 剪辑页在播 → 进素材库加素材（`rebuild()` 已把旧实例停掉，入口快照 = 暂停态）→ await 期间返回，续播把**即将被替换的旧实例**播起来 → await 结束装上不播的新实例、旧实例无人停 → **有声音但画面不动**，再点播放器播放键即成**两路音频**。结构对策见架构公约 §6.3（`player` 单点安装 + 意图单点收敛 + `isPageActive` 初始 false）。
- **AVAssetWriter 产物字节不确定**：mp4 容器嵌入写入时间戳，同参数两次合成得到不同字节——内容寻址（SHA-256 去重）相关测试不能用「两次合成」冒充「同内容」，要合成一次再拷贝副本（AssetLibraryTests 实测踩过）
- **转场预览直通怪癖（iOS 26 模拟器实测）**：转场路径（双视频轨 composition）中素材分辨率恰等于 preset renderSize 时，显示管线把解码 buffer 直通 CA image queue，像素格式被拒（-11800 / 底层 -19230）→ `AVPlayerItemFailedToPlayToEndTime`，播到转场即停；identity transform 微扰无效（判定基于尺寸相等），`PreviewBridge.breakRenderSizeEquality` 给 renderSize 加 0.5pt 规避。注意 `AVPlayerItem.videoComposition` setter 是 copy 语义，改完要 mutableCopy 赋回。真机已验证无此问题（2026-10-12），微扰为模拟器保留；正式版发布前再移除或按模拟器条件编译（见 roadmap backlog；降级登记见架构公约 §6.4）
- **Kadr ImageClip 拉伸图片到 preset 画幅（不保宽高比）**（2026-10-15 实测：100×100 方图导出 1080×1920 整帧填充）：`ImageEncoder.createPixelBuffer` 把 CGImage 直接 `draw(in: 全画幅 rect)`，非匹配宽高比的图片被压扁/拉长。规避：`EngineBridge` 交给 Kadr 前先用 `StillImagePreparer` 把图片等比 aspect-fit 居中贴到 preset 画幅黑底画布（`preset.resolution`），之后 Kadr 的拉伸变为恒等缩放。`ImageClip.background(_:)` 不能替代——`insertImageClip` 调 `ImageEncoder.encode` 时未传 backgroundColor，该修饰符在此路径不生效
- **Kadr ImageClip 内部物化**：`CompositionBuilder.insertImageClip` 每次构建 composition 都把图片按 preset 分辨率+帧率编码成临时 mp4、插入后即删。我们层无需物化/缓存/登记表扩展；代价是图片工程每次 rebuild 都有一次编码开销（当前可接受）
- **`naturalSize` / ImageIO 像素尺寸都是「未应用方向」的原始尺寸**（2026-10-16 定位）：竖拍视频的 `AVAssetTrack.naturalSize` 是 1920×1080 加一个 90° `preferredTransform`，图片的 `kCGImagePropertyPixelWidth/Height` 同样不含 EXIF orientation——而抽帧器（`appliesPreferredTrackTransform` / `kCGImageSourceCreateThumbnailWithTransform`）产出的是**已摆正**的图。两边口径不一致时，按元数据算出来的「宽高比」会把竖屏当横屏：时间线帧格宽按横屏算 → 画面被 `aspectRatio(.fill)` 裁成一条横带；`ClipTransform.halfScreen` 的 scale 同理算错。规避：探测时先摆正（见架构公约 §3.8），且时间线格宽**以已抽到的那张图为准**、元数据只作首帧兜底
- **Kadr `Transform` 作用于 aspect-fill 之后、裁切之前**（2026-10-16 实测）：`VideoClip`/`ImageClip` 先按「铺满画布」（`max(resW/natW, resH/natH)`）落到画布，再叠加 `Transform`。故「半屏」不能写成恒定的 `scale 0.5`——横屏素材填充后远宽于画布，缩 0.5 仍是整幅宽色带。要得到「占画布一半宽」的块，scale = `0.5 × 画布宽 / 填充后内容宽`（见 `ClipTransform.halfScreen`）
- **精确 seek（无容差）在合成器上每次全量重渲**（2026-10-16 定位）：`AVPlayer.seek(to:)` 单参重载等价于 `toleranceBefore/After = .zero`，多段 composition + videoComposition 下每次都要把合成器渲到目标帧。时间线擦洗是每 ~50ms 一次的高频 seek，精确 seek 直接打满播放管线——**这是擦洗手感卡顿的主因**。规避：擦洗用 0.1s 容差 seek、松手补一次精确 seek（降级登记见架构公约 §6.4）

## SwiftUI 状态观察

- **`@Observable` 的 setter 不做相等判断，同值写也通知依赖者**（2026-10-16 定位）：`currentTime` / `playheadTime` 这类高频量若无条件回写，暂停期间值不变也会按轮询频率持续通知，让时间线白重算（实测暂停时仍 10Hz 重建）。凡「每帧 / 每拍回写」的 stored 属性都要加同值 guard
- **依赖按 body 作用域内读到的 stored 属性注册**（2026-10-16 定位）：计算属性（`scrollOffset` / `visibleTimeRange` / `contentX(forTime:)`）只是转调 stored getter，照常注册依赖；手势闭包里的读取不注册。故容器 body 一旦读高频量就会每帧重建整棵树，而父视图 body 重算**不会**无条件强制子视图 body 重算（SwiftUI 对子视图值做 diff，相等即跳过）——每个读了该对象的视图是**各自独立失效**的，修法是「把高频读取收进最小叶子」，不是「让父别重算」（约束见架构公约 §6.6）
- **`@ViewBuilder` 的 if/else 换分支 = 子树重建、`@State` 清空**（2026-10-16 定位）：两个分支在视图结构里是**两个不同位置**（哪怕包的是同一个视图值），条件翻转时 SwiftUI 拆旧建新，里面的 `@State` 全部重来。浮起修饰器原写成 `if isLifted { content.offset()… } else { content }`，于是长按浮起 / 落下各清空一次胶片条的帧缓存——表现为**点选（按下）时缩略图闪一下灰底**。对策：修饰链恒定，非浮起态各参数取中性值（`scaleEffect(1)` / `shadow(opacity: 0, radius: 0)`）
- **播放跟随与手势会抢同一个 `playheadTime`**（2026-10-16 定位）：`PlaybackFollow` 在播放态每拍（100ms）按播放器时间重定播放头（带 0.12s 线性动画），而捏合缩放的锚点补偿**每帧**直接写播放头——两者同时写时，内容在「播放器时间」与「锚点要求的位置」之间来回跳，即**播放态捏合的高频抖动**（暂停态不出现，因为那时 `isPlaying` guard 已让位）。对策：会改播放头的手势一律走擦洗那条路径（`scrubTo` / `scrubEnded`），播放跟随自然让位（规则见架构公约 §6.6）

## SwiftUI 渲染与手势

- **`scaleEffect` 写在 `offset` 之外会把定位量一起缩放**（2026-10-16 定位）：`scaleEffect` 的锚点是**被修饰视图自身 frame 的中心**，而 `offset` 只是渲染位移、不改 frame——`content.offset(x: contentX).scaleEffect(1.06)` 的变换是「缩放 ∘ 平移」，平移量被乘了 1.06。时间线元素块原先把定位放在块内、浮起缩放放在块外，于是浮起瞬间整段横移 `0.06 × (contentX − 块宽/2)`：越靠后的片段偏得越多（实测可达几十点），而选中框 / 手柄不缩放 → 与内容错位。对策：**缩放与定位收在同一个修饰器里（`LiftTransformModifier`），缩放恒在 `offset` 之前**，容器层与车道内容共用这一条、内容块一律不自定位
- **`DragGesture(minimumDistance: 0)` 把「按住不动」也算成拖动**（2026-10-16 定位）：长按序列（`LongPressGesture.sequenced(before: DragGesture)`）里用 0 当阈值时，长按成功那一刻起手指的自然抖动就成了位移——元素立刻跟着抖（表现为「点一下就抖」）。对策：阈值取 8pt（与擦洗同口径）。**浮起不跟着位移走**（浮起由「按满时长」的独立计时给，见上一条）：跟手位移与浮起解耦后，阈值 0 的危害只剩「抖」，不再影响浮起时机
- **别拿系统长按手势的「成功」信号当拾起判据**（2026-10-16 定位）：本 SDK 上它有两处不可靠——① `LongPressGesture.sequenced(before: DragGesture)` 的取值在同层还有点选手势（`.onTapGesture` / `Button`）时，**点一下抬手（未按满时长）也会报成功**，于是点选跟着浮起 + 震动；② 单体 `LongPressGesture` 的 `.updating` / `.onChanged` 在 iOS 18+ **从不触发**（Apple DTS 已复现，FB14372706 / FB16449802），只剩 `.onEnded`，而官方替代 `onLongPressGesture` 又记录为不能与 `.simultaneousGesture` 合用。对策：**时长与判据都自己数**——从**触地那一下**（序列 `.onChanged` 的 `.first(false)`）起一个 0.5s 计时任务，到点即拾起；配一条兜底判据「已真的在跟手」（会话**位移非零**），计时那条若没走通则拾起即反馈（且它不会被点选误触：点选建的会话位移恒 0）。**计时必须从触地起算**——若改成长按成立（0.5s）才起算，按住就得等 1.0s 才浮起；**兜底要锁住拾起态**（写 `liftedTarget` 而非只响一声），否则计时随后到点会再响一次（同一个值写两次 `onChange` 不触发，正好去重）
- **撤那个计时别靠 `.onEnded`，要靠 `@GestureState`**（2026-10-16 定位）：`onEnded` **只在手势成功时调用**，长按失败（极快点选）时不调；而点选又没位移、没越过起手阈值，于是「按手势态撤计时」的三条路径全落空 → 计时成孤儿 → **抬手约 0.5s 后照样浮起 + 震动**（原始症状的延迟版，更难察觉）。对策：把「按压中」也放进 `@GestureState`（与 `drag` 同源，**结束与取消都自动复位**），计时起撤由它的 `.onChange` 单点驱动。一般规律：**凡是「手势期间开的计时/任务」，其撤销点必须落在「手势结束或取消都必然走到」的信号上**——`@GestureState` 复位是，`onEnded` 不是
- **擦洗的让位判据别用「起手点坐标」，用「会话是否活跃」**（2026-10-16 定位）：擦洗曾额外判「起手点是否落在选中元素的 trim 手柄区（元素边缘 ±8pt）」，而这条 X 带与手柄自身的 16pt 命中区逐点相同——手柄的会话本来就挡擦洗（`drag != nil`），判据纯属冗余；它唯一的独立价值是「不依赖 `drag` 的写入时序」。对策：删掉坐标判据，让位只认 `drag != nil`，时序那件事交给 trim 手柄取 `minimumDistance: 0`（触地即建会话，早于擦洗的 8pt 起手；触地与首次位移是两个独立事件）。**代价**：这是**事件顺序**保证，不是坐标判据那种结构性免疫——若某天触地与首帧位移被并进同一批事件，擦洗可能抢到手柄一帧。另注：短片段「滚不动」不是这条判据造成的，是手柄固定 16pt 在低缩放下盖满整条，压在手柄上归 trim

## 文件系统（Foundation）

- **macOS `/var` → `/private/var` firmlink**：`FileManager.temporaryDirectory` 返回 `/var/...`，而 `enumerator(at:)` 返回的 URL 带 `/private/var/...` 前缀（`resolvingSymlinksInPath()` 不解析 firmlink）——按字符串前缀裁剪相对路径会静默错位（ZipArchive 曾因此打出 0 条目的包）；要相对路径用 `enumerator(atPath:)`（天然返回相对路径）

## 相册集成（kadr-photos）

- **resolver 要授权**：`PhotosClipResolver` 要求 readWrite 授权（.authorized/.limited），即使 PHPicker 本身免授权——导入前必须先 `PhotosBridge.requestReadAccess()`；App 需 `NSPhotoLibraryUsageDescription`
- **默认 preset 降帧率**：`AVAssetExportPresetHighestQuality` 会把高帧率视频压到 30fps。`PhotosBridge` 优先 passthrough（保 HDR/高帧率且秒级完成），失败回退重编码——改这段逻辑时保留这个顺序
