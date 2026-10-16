# 时间线多轨设计 spec

日期：2026-10-15
状态：已确认（brainstorm 收口）
范围：时间线专项 ①——多轨模型 + 时间线 UI 一起打通。音乐 / 贴纸 / 特效轨本期不做，只在模型上留扩展缝（音频维持「整体后置」决策）。

## 背景

现状：`EditPlan` 是扁平 `clips`（隐式单视频轨）+ `captions`（整片 SRT 文件引用）；`TimelineView` 是占位实现——固定宽度、点击弹 confirmationDialog、`toggleTrim` 硬编码切 `0...3`。

Kadr 侧的能力比预想多，本期大量直接复用：

| 能力 | 出处 | 本期的用法 |
|---|---|---|
| `Track(at:name:)` 并行视频轨 | `CompositionBuilder.buildMultiTrack` → 真多轨 `AVMutableCompositionTrack` + 多输入 videoComposition | 叠加视频轨（画中画 / 分屏） |
| `makePlayerItem()` 用同一份 videoComposition | `Video.swift` | **画中画能进预览**，不违反公约 §6.1 所见即所得 |
| `ImageClip.color(.black, duration:)` | `ImageClip+Color.swift` | gap → 黑段（1×1 源图拉伸，内存零成本） |
| `VideoClip.transform(_:)` / `.opacity(_:)` | `VideoClip.swift` | 画中画定位 |
| `Caption(text:timeRange:)` | `Caption.swift` | 字幕 cue 从 plan 构造，不再从文件读 |
| `Video.thumbnailGenerator()` / `thumbnails(at:)` | `ThumbnailGenerator.swift` | 胶片流抽帧（compose 一次、generator 复用） |

## 决策汇总（brainstorm 已拍板）

1. **范围** = 时间线 UI + 多视频轨一起打通。音乐 / 贴纸 / 特效不做，模型留缝。
2. **可扩展性 = 特性注册表**，核心不认识具体轨类型。代价是 Manifest 加 1 行（Swift 无插件机制，注册清单必须有），收益是**核心代码零条件分支**——加轨时不存在「漏改一处 switch」的复发风险。
3. **轨道头 = 无独立头**。图标与轨道编号直接压在轨道条内容上（无独立 chip、无实色底，仅靠阴影保证可读），横向钉在视口左缘、纵向跟着自己那条轨道走，轨道滚出屏幕时一起被裁掉。
4. **布局 = 可拖拽分界 + 三档吸附**。默认预览 ~150pt / 时间线 ~230pt，中间横杠可上下拖，吸附到「预览最小高 / 时间线半屏 / 时间线近全屏」三档。
5. **播放头 = 固定居中，滚动即擦洗**。单指左右拖既是滚动也是擦洗，是同一个手势。
6. **删除语义 = lift 而非 ripple**。删除主轨元素 = 内容消失、时长保留（原地留黑），其他轨一个字节不动。这是桌面 NLE（Premiere / FCP / DaVinci / Avid）的默认行为，偏离手机端主流（剪映默认合上）。
7. **自动补 gap 归核心操作**，不是 UI 手势技巧。UI 与 Agent 两个消费方自动一致。
8. **字幕逐句化**：cue 进 plan，SRT 文件退化为导入源。
9. **成片时长恒等于主轨链长**，公约 §3.3 原公式一字不改。

## 分期

本期拆成两个实施阶段，各自独立验收：

- **① 模型 + 引擎**：EditPlan v4、特性注册表、`gap` 语义与两条不变式、`EngineBridge` 多轨映射、字幕逐句化、Agent 工具改造、v3 → v4 迁移、公约修订。验收 = L2 单测 + L3 e2e + CLI 冒烟。
- **② 时间线 UI**：L1 Interaction 层、布局与可拖分界、轨道头、标尺与播放头、缩放手势、缩略图、选中与 trim、长按拖动与轨道重排。验收 = App 构建 + 模拟器手动验证清单。

② 依赖 ① 的模型定型；① 完成前不写 UI 代码。

## 数据模型

```swift
public struct EditPlan: Codable, Equatable, Sendable {
    public var version: Int              // 4
    public var assets: [AssetItem]
    public var tracks: [PlanTrack]
    public var primaryTrackID: UUID
    public var preset: OutputPreset
}

/// 开放类型：核心不 switch 它，只当字符串带。
public struct TrackKind: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String
    public static let video = TrackKind(rawValue: "video")
    public static let caption = TrackKind(rawValue: "caption")
}

/// 结构属性，核心认识。
public enum TrackPlacement: String, Codable, Sendable {
    case chained     // 位置由顺序推出（主轨）
    case absolute    // 每个元素自带 at
}

public struct PlanTrack: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: TrackKind
    public var name: String?
    public var placement: TrackPlacement
    public var isMuted: Bool
    public var isHidden: Bool
    public var isLocked: Bool
    public var settings: TrackPayload?   // 轨级参数，特性模块解释（如字幕样式）
    public var elements: [PlanElement]
}

public struct PlanElement: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var at: TimeInterval?         // 仅 .absolute 轨；.chained 轨为 nil
    public var content: ElementContent
}

public enum ElementContent: Codable, Equatable, Sendable {
    case content(TrackPayload)           // 有内容，时长由 payload 决定
    case gap(duration: TimeInterval)     // 占位无内容，时长自带
}
```

**为什么 `at` 可选**：主轨是链式，位置由顺序唯一决定；叠加轨绝对锚定。若一律显式存 `at`，顺序和 `at` 就成了两个事实源，删一段要重算后面一串——违反公约的「单点收敛」。

**为什么 `placement` 和 `gap` 归核心**：它们是**结构**不是**类型**。核心能表达「这条轨是链式的」「这里空着」，但表达不了「这条轨是音乐」「空的是音乐」。

**时长各自单一事实源**：有内容的元素时长由 payload 推出；gap 的时长自带。不存在两个地方都能改时长。

### TrackPayload（type-erased box）

```swift
public struct TrackPayload: Codable, Equatable, Sendable {
    // JSON 形如 {"type":"clip","assetID":...}；核心只读 type 字段查表分发。
}
```

- payload 自己的 JSON 里带 `type` 判别字段（与 `SpeedPlan` / `PlanTransition` / `PlanClipSource` 的既有风格一致），核心按 `type` 查注册表交给对应特性模块编解码。
- 核心不知道任何具体 `type` 的存在。
- 未知 `type` → 解码报错（不静默丢弃），并指向具体的 payload 类型名。

## 特性注册表（可扩展性机制）

一类轨 = 一个目录，**按层切三片**：

```
Features/
├── Manifest.swift          ← 唯一清单：每类轨 1 行
├── Video/
│   ├── VideoFeature.swift  L2 · payload 模型 + 编解码 + 校验规则
│   ├── VideoEngine.swift   L3 · → Kadr VideoClip / Transition / Transform
│   └── VideoLane.swift     L0 · 缩略图条呈现器
└── Caption/
    ├── CaptionFeature.swift
    ├── CaptionEngine.swift
    └── CaptionLane.swift
```

**必须切三片的原因**：公约 §1 规定 L2 是纯 Swift（禁 `import AVFoundation` / `Kadr`），L0 才允许 SwiftUI。一个「什么都知道」的特性对象跨不了层，所以是**同一个 kind 在每层各注册一片**，不是一个大对象。

**注册表在 JangyCore 内部静态装配**，不依赖 App 装配。理由：`jangy-cli agent` 是 headless 跑的，若 payload 编解码器由 App 启动时注册，CLI 解码带新轨类型的 plan 会直接失败。

**可插拔性验收**（照抄公约 §4.6 的写法）：写一个测试，现场加一个第四类轨（「贴纸轨」空壳），断言核心代码的 switch / if 条件分支零改动——diff 只应触及 Manifest 一行与新增的特性目录。

## 主轨不变式与删除语义

### 两条不变式

1. **主轨从 0 起连续覆盖 `[0, renderedDuration]`，无隐式空洞。**
2. **任何轨的元素不得超出主轨末端。**

不变式由**核心操作自己维持**，校验器只做兜底断言（公约 §2.1 的形状）。

### 核心操作如何维持

| 编辑 | 结果 |
|---|---|
| 删主轨中间元素 | 出现隐式空洞 → 原地换成等长 gap（内容消失、时长保留） |
| 删主轨末尾元素 | 主轨变短；若其他轨有更靠后的元素 → 尾部自动补 gap |
| 把元素往右拖出主轨末端 | 主轨尾部自动补 gap，成片变长 |
| 把主轨第一段往右拖 | 首端自动插 gap（没有这条规则，链式主轨根本没法把第一段往后拖） |
| 把主轨末段往左拖 | 尾部自动补 gap |
| 删除一个 gap 元素 | 后面的元素前移——这才是「合上」 |

**净效果：删除主轨元素不改变成片时长**，用户想缩短要显式「合上」。

### 风险与缓解

拖元素时手抖拖出末端 → 成片静悄悄变长。缓解：**「主轨末端」是一个吸附点**，元素边缘会吸上去，要真延长得明确拖过去；且 gap 是可见的黑段（不是隐形的），用户看得见自己造出了什么，也能一键合上或撤销。

### 已知行为偏离

桌面 NLE 默认 lift、手机端主流（剪映）默认 ripple。本期跟桌面走，理由是**轨与轨解耦**：ripple 会让「删一段视频」变成会改变其他轨时间处境的操作。风险是手机用户带着剪映习惯来，删一段发现后面没动、以为没删掉——**记入真机试用观察项**。

## 分层与组件

| 层 | 新增 |
|---|---|
| L0 `Jangy/` | `TimelineView`（容器 + 可拖分界）、`RulerView`、`TrackLaneView`、`TrackCap`、`PlayheadOverlay`、`ZoomBadge`；`TrackLaneView` 是注册表驱动的——它不认识「视频轨」「字幕轨」，只按 kind 去问注册表要呈现器 |
| L1 `JangyCore/Interaction`（已建；纯 Swift，无 SwiftUI） | `TimelineViewportState`（播放头位置 / px-per-sec / 滚动偏移——高频，**不进 EditStore**）、`SnapEngine`、`DragSession`、`GestureRouter`、`TimelineEdit` |
| L2 `JangyCore/Plan` | `EditPlan` v4、`PlanTrack`、`PlanElement`、`ElementContent`、`TrackPayload`、`TrackFeatureRegistry`、SRT 迁移解析器；`EditPlanValidator` 扩轨校验；`ValidationIssue` 加 `elementID` |
| L3 `JangyCore/Engine` | `EngineBridge` 扩轨映射；**`TimelineThumbnailer`**——从 App 层的 `ThumbnailLoader` 收口上来（它现在在 L0 却 `import AVFoundation`，已违反公约 §1） |

### 高频 / 低频分界

拖动期间（60fps）**只动 SwiftUI 局部**——元素偏移量、播放头位置、缩放值全是内存临时态，**EditPlan 一个字节都不变**，所以预览不重建、SwiftUI 不重算整棵树。**抬手才落一个原子意图**，`EditStore.apply` 跑一次、校验 + reactor 同步跑完，撤销栈只 +1（公约 §6.5）。

播放头位置、缩放值、滚动偏移三个高频量全部关在 `TimelineViewportState` 里，与公约 §2.2 对播放头的处理同款。

## 时间线 UI

### 轨道头

图标 + 轨道编号 + 静音 / 隐藏按钮，作为轨道条自身的一段左帽渲染，横向钉在视口左缘（钉在偏移层**之外**的兄弟视图，不是 `ScrollView` sticky、也不是 overlay chip），纵向跟随自己的轨道、滚出屏幕时一起被裁掉。无实色底，靠文字阴影保证在任意素材上的可读性。

### 手势地图

| 手势 | 结果 |
|---|---|
| 单指左右拖（轨道内容） | 滚动 = 擦洗（同一件事） |
| 单指上下拖 | 纵向滚轨道列表 |
| 双指捏合 / 张开 | 缩放 px/s，锚点 = 双指中心。锚点补偿会改播放头，故与擦洗同路径（接管即暂停播放、节流 seek） |
| 点元素 | 选中（出 trim 手柄） |
| 长按元素 | 选中；位移越过起手阈值（8pt）才浮起跟手 |
| 长按元素 + 拖 | 移动元素（改位置 / 换轨） |
| 拖元素左右边缘手柄 | trim |
| 长按轨道左帽 + 上下拖 | 轨道重排（换层） |
| 拖分界横杠 | 调预览 / 时间线高度 |
| 横向甩动后松手 | 惯性继续滚动（`TimelineFling` 指数衰减，走播放头所以预览跟着滚） |

短拖一律归滚动，长按才「拾起」——避免与滚动误触。

**浮起要过起手阈值**：长按成功只进会话（+ 选中），位移越过 8pt 才浮起并跟手。阈值取 0 会把「按住不动」当成拖动，手指的自然抖动就让元素弹起来并跟着抖。

**轴锁定**：横向 / 纵向在**起手那一下**定轴，全程不再改。锁成横向时纵向 ScrollView 一并关掉（否则横拖仍会被带着上下跑）；锁成纵向时擦洗完全不参与。四向解锁会让一次拖拽中途从滚动变成擦洗（或反之），手感很飘。

**纵向滚动按需**：轨道总高（含行距）不超过「视口高 − 标尺」时**关掉纵向 ScrollView**。纵向 ScrollView 即使内容不溢出也会吸走纵向手势，让「拖上去没反应、也擦洗不了」；关掉之后，纵向为主的拖拽就是「什么都不做」（定轴照常按起手方向判，不特殊处理）。

### 缩略图

- **从源素材抽帧，不从 composition 抽**。缓存键 = assetID + 抽帧像素高 + 时间桶，同一素材在时间线上多处出现时复用率高；且不需要为每次 plan 变更重建 composition。缩略图的作用是「识别素材」，不需要反映变速 / 转场。
- **帧格胶片条**：格宽 = 车道高 × 素材宽高比（屏幕上恒定，画面不裁切），夹在 `[32, 120]` pt——与剪映 / CapCut / iMovie 一致。缩放进出的只是「每格代表多少秒」。抽帧像素高按档量化（64 的倍数）。
- **视频与图片同一条路径**：图片没有源区间，任一格都是同一张图（`TimelineThumbnailer` 按同一键返回同一实例），故不单开分支、也不会被 aspect-fill 裁成一条横带。
- **只建与（量化）裁剪窗相交的格**：窗是存储属性、只在跨「一屏」时写，故滚动 / 播放期间不重建、已抽好的帧不重取。
- **抽帧范围比渲染范围更宽**（前后各多半屏）：帧在被看见之前就抽好。仍未抽好时，**两个格宽以内**用最近已抽好的帧顶替，超出则留灰底（宁可灰底也不闪无关内容）——否则滚动时能看到「空白 → 缩略图」的跳变。
- **重建时先铺缓存**：元素被裁剪窗移出时呈现视图连同其帧表一起销毁，滚回来重建时先做一次「只查缓存、不抽帧」的取帧（`TimelineThumbnailer.cachedFrames`），把空白期压到一帧内——否则回到刚看过的区域会整条先空白一下再出现。铺完之后正常那一遍只请求真正缺的帧，不重复抽。
- **捏合缩放期间不逐帧重取**：格映射随时间间距连续变，靠 `.task(id:)` 重启 + 60ms debounce 把中间态合并成一次。
- 格身份 = 元素 id + 全局格索引（与可见区 / 播放头无关）；**帧缓存按帧身份（素材 + 像素档 + 源时间）做键**，不按格索引——索引 → 源时间的映射随 pps 与 clip 源区间变，按索引会在缩放 / trim 后错位。
- 抽帧时间点 = 输出时间 × rate + range.lowerBound，这个映射在 L2 算（纯 Swift、可测）。
- 时间桶（0.01s）决定「相邻格会不会显示同一帧」，必须小于相邻格的**源时间**间距（最小格时长 × 最小倍速），有测试钉住该不变式。

## 引擎映射（L3）

- 主轨（`placement == .chained`）→ Kadr 顶层线性链（不带 `startTime` 的 clip），转场照旧。
- 叠加视频轨 → `Kadr.Track(at:name:) { ... }`；元素定位用 `VideoClip.transform(Transform(center:rotation:scale:anchor:))` + `.opacity(_)`。
- `gap` → `Kadr.ImageClip.color(.black, duration:)`。主轨仍是连续链，转场路径不受影响。
- 字幕轨 → `Kadr.Caption(text:timeRange:)` 从 plan 的 cue 构造，`.captions(_:)` 软字幕 + 逐 cue `ImageOverlay` 烧录（沿用现有 `captionOverlay`）。

### 多画面定位范围

本期叠加轨元素带 `transform`（位置 / 缩放 / 不透明度）参数，引擎完整映射。**左右分屏已落地**：`PlanClip.transform`（`ClipTransform`）+ UI 预设（全屏 / 左半屏 / 右半屏）。分屏 **aspect-aware**——Kadr 的 `scale` 是均匀缩放、作用于 aspect-fill 之后的内容，故 `scale = 0.5 × 画布宽 / 填充后内容宽`（非恒定 0.5，见 `ClipTransform.halfScreen`）。自由拖拽定位仍留 backlog——需要一整套画布交互（拖拽框、手柄、吸附），是独立的一块，多轨的结构价值不依赖它。

## Agent 契约

Agent 是 L1 的另一个 headless 消费方，其工具签名与 plan JSON 是对外契约。

### 四条硬约束

1. **注册表在 JangyCore 内部静态装配**（见上），CLI headless 可用。
2. **寻址一律走 ID，废除下标寻址**。`PlanElement.id` 是唯一寻址单元（原 `PlanClip.id` 挪到这一层，Agent 的 `clipID` 语义不变）。现有 `move_clip(clipID, toIndex)` 的全局扁平下标在多轨下立刻歧义，且 LLM 不擅长下标算术 → 改成纯 ID 相对定位。
3. **`ValidationIssue` 增加 `elementID`**。现有 path（如 `clips[1].speed`）在 v4 变成 `tracks[0].elements[1].speed`，更长且**下标会随 plan 变动漂移**（Agent 拿到报错、改了一处、下标就变了）。带 ID 后 Agent 拿位置无关的标识，UI 侧也能直接高亮出错元素。
4. **「叠加轨的绝对时间放置」是新的编辑原语**，不是给现有工具加参数。主轨是线性链（顺序有意义、有转场），叠加轨是绝对时间锚定（每个元素带 `at`）。工具层与 prompt 都要显式区分。

### 工具变更

| 工具 | 变更 |
|---|---|
| `get_plan` | payload 增加扁平紧凑视图（`{elementID, trackID, kind, ...}`），原始 plan JSON 另开字段 |
| `add_clip` | 加 `trackID`（缺省主轨）与 `at`（叠加轨必填） |
| `move_clip` | → `move_element(elementID, toTrackID?, at? / beforeElementID?)`，纯 ID |
| `split_clip` / `trim_clip` / `remove_clip` / `set_speed` / `set_transition` | 签名不变（ID 寻址），内部按 elementID 查找 |
| 新增 | `add_track(kind, placement?)` / `remove_track(trackID)` / `move_track(trackID, toIndex)` / `set_track_flags(trackID, muted/hidden/locked)` |
| `set_captions` | → `set_caption_track(fileName, ...)`（导入 SRT 并展开为 cue 元素） |
| 新增 | `set_caption_text(elementID, text)` |

`remove_clip` 在链式轨上的语义 = 「内容消失、时长保留」（产生 gap）；要缩短需再删掉 gap 元素。

## 字幕逐句化

- 字幕轨的 `elements` = cue 列表，payload = `{text}`（逐句样式 v1 不做，样式是轨级，放 `PlanTrack.settings`）。
- 轨 `settings` 保留 `sourceAssetID`（指向登记表里的 SRT）与样式参数——维持素材引用保护，并为将来「重新展开」留位。
- **SRT 文件退化为导入源**：导入即展开，展开后 plan 是唯一事实源，不回写文件。与「导入视频后源文件只是素材、剪辑不改源文件」同理。
- 预览侧反而更简单：少一层 SRT 解析，直接读 plan 的 cue。
- **本期只做拖 / trim / 增删，改字走 Agent 工具**（`set_caption_text`）；文本编辑 UI（键盘、焦点、实时预览）留 backlog。
- 字幕不随视频片段联动：分割 / 删除视频片段不触碰字幕轨。公约 §4 已知联动清单里的「分割点横跨字幕 → 字幕裂为两条」随之作废。

## v3 → v4 迁移

- `clips` → 一条 `kind = video` / `placement = .chained` 的轨，`primaryTrackID` 指向它；元素继承原 `clip.id`。
- `captions` → 一条 `kind = caption` / `placement = .absolute` 的轨；`settings` 取原 `assetID` / `isEnabled` / `style`；`elements` 由**读取 SRT 展开**得到。
- 迁移发生在 `ProjectStore` 读工程时（L2 基础设施；`FileManager` 与纯文本解析不违反 L2 的 `AVFoundation` / `Kadr` 禁令，故在 L2 写一个极简纯 Swift SRT 解析器，不用 `Kadr.Caption.load(srt:)`）。
- **SRT 文件缺失时**：caption 轨仍建立但 `elements` 为空，工程完整性报告显式上报（沿用现有 `verify` 机制），不静默丢。
- 编码只写 v4；解码 v3 走迁移；过新版本走既有版本守卫拒绝加载。

## 公约修订清单

1. **§3.3 时间口径**：公式不变，补两条不变式——主轨从 0 起连续覆盖 `[0, renderedDuration]`；任何轨的元素不得超出主轨末端。
2. **§3.2 素材引用**：字幕 cue 的文本进 plan、不再引用素材；SRT 文件退化为导入源（轨 settings 保留 `sourceAssetID` 以维持引用保护）。
3. **§1 现有代码落位表**：「待建 L1 Interaction 层」→ 已建；补记 L2 特性注册表、L3 轨道引擎映射、L0 轨道呈现注册点。reactor 注册表仍未建。
4. **§4 已知联动清单**：删除「分割点横跨字幕 → 字幕裂为两条」——字幕是独立绝对轨，不随视频片段联动。
5. **新增章节「轨道模型」**：kind / placement / `ElementContent(gap)` / 特性注册表三层切片 / Manifest。
6. **新增条目「删除语义 = lift 而非 ripple」**：删除主轨元素 = 内容消失、时长保留；缩短需显式合上。
7. **§6.4 降级登记表**：按实现情况补登（缩略图、拖动期间帧率等）。
8. **§3.8 素材分辨率报显示方向尺寸**：`pixelWidth/Height` 一律是应用方向之后的尺寸。

## 验收

- **L2 单测**：多轨模型编解码、`gap` 语义、两条不变式的维持与兜底、v3 → v4 迁移（含 SRT 缺失分支）、`ValidationIssue.elementID`。
- **可插拔性验收**：加第四类轨空壳，断言核心条件分支零改动。
- **L3 e2e**：多轨导出（主轨 + 叠加轨画中画）抽帧核对；gap 黑段导出；字幕逐句展开后导出与逐句改动后导出；均按现有 `TestArtifacts` 抽帧口径。
- **App**：模拟器构建通过 + 手动验证清单（双指缩放、擦洗、长按拖动、轨道重排、分界拖拽与吸附、缩略图滚动流畅度）。
- **CLI 冒烟**：`sample` / `validate` / `export` / `snapshot` / `agent` 无回归；`agent` 链路按新工具集跑通一次真实编辑。
- 测试基线 176 → 按新增用例上调。

## 待验证 / 未决

- **主轨结束后的画面行为** → **已实测**：主轨 gap 区间渲染为**黑场**（gap 映射成 `ImageClip.color(.black)`；成片时长仍等于 `EditPlan.renderedDuration`，不含 gap 之外的多余时长）。由 `MultiTrackExportEndToEndTests.testGapRendersAsBlackAndPreservesDuration` 锚定（5.0s 成片，2.0–3.0s gap 抽帧 RGB 求和 < 36）。
- **主轨为空时的边界**：成片时长为 0，其他轨不应有元素。「先导入字幕后导入视频」这类顺序问题怎么提示，实现时定。
- **叠加轨在预览中的实机表现** → **已真机确认（2026-10-15）**：`Track` 走多输入 videoComposition 路径（非 `AVVideoCompositionCoreAnimationTool`），**预览可见**——叠加区间内叠加轨内容出现、结束后回到主轨（末帧未被保持）。模拟器仍有已知的直通像素格式怪癖（见 `breakRenderSizeEquality`），结论以真机为准。
- **视频轨的 z 序** → **已修复（均为 Kadr 侧 bug）**：① 层序——AVFoundation 的 `layerInstructions[0]` 是**最上层**，而 Kadr `buildMultiTrack` 原先按 `videoTracks`（隐式主链在前）顺序构造数组 → 主轨恒在最上、叠加轨永远被盖住；② 末帧保持——任何早于合成末端结束的轨道，其末帧会被 AVFoundation 保持并盖住后续帧（默认路径与自定义 compositor 路径都有）。两者均已在 fork 分支 `fix/multitrack-layer-order-and-frame-hold` 修复（反转 `layerInstructions` + 每条轨在内容结束点补 `setOpacity(0, at:)`），由 `MultiTrackExportEndToEndTests.testOverlayTrackRendersOverMainTrack` 锚定（叠加时段抽帧见叠加轨绿、叠加结束后回到主轨红，末帧未被保持）。**另一条设计事实**：`Kadr.Track { }` **内部**元素的 `.at(time:)` 被忽略（Track 内部是 track-relative 隐式链，这是 Track 的有意设计，非 bug），Jangy 侧叠加轨定位须改用「每个叠加元素一个 `Track(at:)`」——已落地（`VideoEngine.makeParallelTracks`），由 `testMultiElementOverlayTrackPositionsElementsAbsolutely` 锚定（两个叠加元素各自落在自己的 `at` 上）。
