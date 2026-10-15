# 时间线多轨实施计划（阶段②：时间线 UI）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把占位版 `TimelineView`（固定宽度、点击弹框）换成真时间线 UI：可拖分界布局、注册表驱动的多轨车道与轨道头、固定居中播放头（滚动即擦洗）、双指缩放、源素材缩略图、选中 / trim / 长按移动 / 轨道重排；并把这一切的高频交互收进新建的 L1 Interaction 层（`JangyCore/Interaction`），拖动期间 EditPlan 一个字节不动。

**Architecture:** L0（`Jangy/`）只做呈现 + 手势采集 + 发意图；L1（`JangyCore/Interaction`，**整层新建**）持有高频视口状态、手势路由、拖拽会话、吸附，并把抬手落成一次原子编辑（`EditStore.apply`）；L2 补两个纯函数（缩略图源时间映射、吸附点收集）；L3 新增 `TimelineThumbnailer`（从源素材抽帧，并把违反公约 §1 的 L0 `ThumbnailLoader` 收口上来）。

**Tech Stack:** Swift 6 / SwiftUI（iOS 17）/ Observation / SwiftPM / XCTest / AVFoundation（仅 L3）

**Spec:** [2026-10-15-timeline-tracks-design.md](../specs/2026-10-15-timeline-tracks-design.md)（「分期」节 ② 部分）

**前置：** 阶段① 已收口——分支 `timeline-tracks-model-engine`，kadr 依赖 v1.2.2，295 测试全绿。本计划从该分支继续。

**范围边界：** 本计划只做阶段②（时间线 UI）+ 一条**分屏布局预设**（左右分屏，需给 `PlanClip` 加 transform 字段）。**明确不做**（见「范围外 / 待决」）：
- 多画面**自由拖拽定位**（拖拽框、手柄、吸附）——独立一块，留 backlog。
- 除「左右分屏」外的预设布局（画中画右下等）——只做左右分屏（用户拍板）。
- App 侧「新建轨道」入口（轨道由 Agent 创建；手动验证用 CLI 播种带叠加轨的 plan）。
- 字幕文本编辑 UI（键盘 / 焦点），走 Agent `set_caption_text`。

**执行顺序约束：**
1. **Task 0（真机验证）✅ 已完成**——叠加轨预览可见，结论已回填 spec（见 Task 0）。
2. **Task 1–6 全在 `JangyCore` 内新增，互不破坏，各自独立可编译可测可提交。**
3. **红色区间从 Task 7 开始**：Task 7 整体替换 `Jangy/TimelineView.swift`，会一次性删掉旧的固定宽度实现。Task 7–10 每步都必须以 `xcodebuild` 通过收尾（每步一个绿色提交）；中途 App 不编译的窗口不要拉长。
4. Task 11（文档同步）必须在全部 UI 任务之后。

---

## 关键设计决策（写代码前先读，这几条决定了整个形状）

### D1. L1 是纯 Swift 层，手势识别留在 L0

L1 `JangyCore/Interaction/` 只 `import Foundation / CoreGraphics / Observation`——**不 import SwiftUI**。SwiftUI 的手势识别器（`DragGesture` / `MagnifyGesture` / `LongPressGesture`）属 L0，L0 把**原始事件**（位移、锚点、命中结果）喂进 L1；L1 用纯值类型 / 纯函数把它翻译成意图。

理由：这样 L1 的数学与状态机**全部可单元测试**（spec 的验收虽是模拟器手动清单，但吸附、缩放锚点、拖拽解析这些逻辑没有理由不测）；也符合公约 §1 对 L2 纯 Swift 的同款精神。手势的接线本身是 SwiftUI 专属，天然在 L0。

### D2. 时间线的水平位置**由偏移量驱动，不用横向 ScrollView**

车道与标尺整体 `.offset(x: -viewport.scrollOffset)`，位移来自 `TimelineViewportState`；**纵向**轨道列表仍用普通 `ScrollView`。

理由：①「滚动即擦洗」需要每帧拿到实时偏移，而 iOS 17（本包平台下限）没有 `onScrollGeometryChange`（iOS 18 才有），读 ScrollView 实时偏移要靠 `GeometryReader`+`PreferenceKey` 这种别扭写法；②双指缩放的锚点换算需要精确控制偏移，ScrollView 给不了；③偏移量本就是 L1 的既有状态（spec 明列「滚动偏移」为高频量），直接驱动 `.offset` 是零额外机制的。

这与 spec「轨道头钉在 ScrollView 的 sticky 层」的**字面**措辞不同，但满足其**意图**（轨道头横向钉在视口左缘、纵向跟轨走、不是 overlay chip）——轨道头是偏移层之外的兄弟视图，天然钉住。**Task 11 回填 spec 这处措辞。**

### D3. 播放头的归属与擦洗语义

- `TimelineViewportState.playheadTime` 是时间线播放头的**唯一事实源**（不是 `PlayerController.currentTime`）。
- **播放头恒在视口水平中央**：内容带「半个视口宽」的左右留白，于是 `scrollOffset == playheadTime × pointsPerSecond`（推导见 `TimelineViewportState` 注释）。「滚动」与「擦洗」因此是同一件事。
- **擦洗**（单指横向拖）→ 改 `playheadTime` → `player.seek(to:)`（节流）+ `player.pause()`（剪映同款：擦洗暂停播放，避免播放推进与拖拽打架）。
- **播放推进** → 时间线订阅 `player.currentTime`，非擦洗态时把 `playheadTime` 同步过去（内容自动滚，播放头视觉居中）。

**这修订了公约 §2.2**（原文「时间线 UI 不订阅播放头」）：时间线 UI 现在**订阅的是 L1 的 `TimelineViewportState`**，高频隔离在时间线子树内，仍不进 `EditStore`、不由 `PlayerController` 全局广播。Task 11 回填。

### D4. 高频 / 低频分界（公约 §6.5 的落地）

- 拖动期间（60fps）**只动两样东西**：`TimelineViewportState`（视口量）与 L0 里 `@State` 持有的 `DragSession` 值（拖拽瞬态）。**`EditPlan` 一个字节不变**，故预览不重建、撤销栈不动。
- **抬手才落一个原子编辑**：`DragSession.resolve(...)` 产出 `TimelineEdit` → `TimelineEdit.apply(to: store)` 跑一次 `EditStore.apply`（校验 + reactor + 不变式同步跑完）→ 撤销栈只 +1。
- `resolve` 返回 `nil`（净变化为零）时不落栈。

### D5. L0 车道呈现走注册表，不 switch 具体轨类型

公约硬约束：`TrackLaneView` 不得 `switch kind`。做法是在 **App target** 建一个与 L2 `Manifest.swift` 同款的 L0 注册表（`TrackLaneRegistry` + `TrackLaneProvider` 协议），`Jangy/Features/Video/VideoLane.swift` 与 `Jangy/Features/Caption/CaptionLane.swift` 各注册一片。L0 注册表在 App 装配（headless 无 L0 消费方，无需静态装配）。

**注意物理落位**：spec 的 `Features/` 树把三片画在一个目录里，那是**概念分组**——L2/L3 片在 `Packages/JangyCore/Sources/JangyCore/Features/`，L0 片在 `Jangy/Features/`（SwiftUI 不能进 JangyCore，CLI 要 headless 编译它）。`Jangy/` 是 Xcode 的 `PBXFileSystemSynchronizedRootGroup`，新增子目录/文件**无需改 pbxproj**。

### D6. 缩略图从**源素材**抽帧，档位离散，只渲可见区

- 缓存键 = `assetID + 档位 + 时间桶`；同一素材多处复用率高，且不为每次 plan 变更重建 composition。
- 档位离散（80 / 160 / 320 px 高），不随缩放连续变。
- 只请求可见时间区间；滚动时取消离屏请求。
- 抽帧时间点 = `range.lowerBound + 输出偏移 × rate`（L2 纯函数算，Task 1）。
- 缩放手势期间不重算请求，用当前档位拉伸顶替，手势结束（debounce）才重算。

### D7. L1 引用 `PlanClip` / `PlanClipSource` 不算「认识特性模块」

L1 的 trim / move 解析要读 `PlanClip` 的 `source`（区间 / 时长），即引用了 `PlanClipSource`。这不违反公约 §1 的「L1 不得认识具体特性模块（字幕/转场）」：

- `PlanClip` / `PlanClipSource` 定义在核心文件 `EditPlan.swift`（**不是** `Features/Video/` 目录下的特性片），是核心内容模型；
- 公约 §0.3 明确把 **trim / move 列进「稳定内核操作集」**（不可插拔），对它们做语义翻译本就是核心职责；
- 已有先例：L1 的 headless 消费方 `JangyAgent`（`AgentToolSet`）本就大量直接操作 `PlanClip` / `PlanClipSource`。

真正的「不认识特性」体现在：L1 **不 switch `TrackKind`**、不出现 `CaptionCuePayload` / `Transition` 专属分支——`resolve` 只按 `placement`（结构）与通用时长分派。将来若出现一类「需要 trim 但 payload 形状不同」的新轨，把 trim 的下沉点从 `TimelineEdit` 挪到特性片（registry hook）即可，届时再说。

### D8. L1 里的 clamp 是「归一化输入」，不是「合法性校验」

`resolveTrim` 里的 `min(assetDuration)` / `max(minElementDuration)` / `≥0` 是把拖拽结果收敛成一个**可提交的候选**（更好的手感），不是拒绝式校验。最终合法性仍由 `EditStore.apply` → `EditPlanValidator` 判定（L1 不返回 `ValidationIssue`、不写业务规则），符合公约 §1 对 L1「不得写合法性校验」的约束。

### D9. 分屏布局：`PlanClip.transform` + 「左右分屏」预设

用户拍板：本期做**一条**分屏预设——左右分屏。

- **模型**：`PlanClip` 加 `var transform: ClipTransform?`（`nil` = 全屏）。`ClipTransform` 是 L2 纯值类型（`centerX/centerY` 归一化、`scale`、`opacity`），**不 import Kadr**——与 Kadr `Transform` 语义对齐但独立定义（L2 不能 import Kadr，公约 §1）。
- **引擎**：L3 把 `ClipTransform` 映射成 `Kadr.Transform(center:.normalized(x:y:), scale:)` + `.opacity(_)`。主轨（`EngineBridge` 内联）与叠加轨（`VideoEngine`）都要应用——左右分屏是**两条轨各占半边**，主轨也得带 transform。
- **预设**：`ClipTransform.leftHalf` / `.rightHalf`（`scale 0.5`、`center` 在 0.25 / 0.75）。UI 在选中元素的操作条给「全屏 / 左半屏 / 右半屏」三选。**左右分屏 = 主轨元素设左半屏 + 叠加轨元素设右半屏**（两次点选，不做一步到位的魔法动作）。
- **Kadr 的 `scale` 是均匀缩放**（`Double`，非 CGSize）——所以「半屏」= 整体缩到 0.5（宽高各半、垂直居中），呈现为「两块半尺寸画面左右并排 + 上下黑边」，不是边到边的裁切式分屏。**这是 Kadr 能力边界内的合理实现**，写进 Task 11 的 spec 回填。
- **schema**：加的是**可选字段**（`decodeIfPresent`），旧 v4 JSON 解出 `transform = nil`，向后兼容，**不需要版本号 bump**。
- **预览**：`.transform` 是轨道内的 layer instruction（不是多轨层序问题），`makePlayerItem` 用同一份 videoComposition，**理论上预览可见**——列入 Task 11 的手动清单确认。

### D10. 范围外的两条 spec 项

---

## 文件结构

**新建（JangyCore）：**

| 文件 | 层 | 职责 |
|---|---|---|
| `Packages/JangyCore/Sources/JangyCore/TimelineMapping.swift` | L2 | 纯函数：输出时间 → 源时间；轨道元素输出起点 |
| `Packages/JangyCore/Sources/JangyCore/Interaction/TimelineViewportState.swift` | L1 | 高频视口状态（播放头 / px-per-sec / 滚动偏移）+ 数学 |
| `Packages/JangyCore/Sources/JangyCore/Interaction/SnapEngine.swift` | L1 | 吸附点收集 + 吸附（纯） |
| `Packages/JangyCore/Sources/JangyCore/Interaction/DragSession.swift` | L1 | 拖拽会话（值语义）+ 解析成原子编辑（纯） |
| `Packages/JangyCore/Sources/JangyCore/Interaction/GestureRouter.swift` | L1 | 命中 → 会话路由（纯） |
| `Packages/JangyCore/Sources/JangyCore/Interaction/TimelineEdit.swift` | L1 | 原子编辑意图 + `apply(to: EditStore)` 翻译 |
| `Packages/JangyCore/Sources/JangyCore/TimelineThumbnailer.swift` | L3 | 源素材抽帧（档位 / 缓存 / 可见区）+ 通用素材缩略图 |
| `Packages/JangyCore/Sources/JangyCore/Plan/ClipTransform.swift` | L2 | 元素布局变换（归一化中心 / 均匀缩放 / 不透明度）+ 左右分屏预设 |

**新建（App，`Jangy/`）：**

| 文件 | 层 | 职责 |
|---|---|---|
| `Jangy/TimelineView.swift` | L0 | 时间线容器（**整体重写**）：可拖分界 + 标尺 + 播放头 + 轨道列表 |
| `Jangy/RulerView.swift` | L0 | 时间刻度尺 |
| `Jangy/PlayheadOverlay.swift` | L0 | 固定居中的播放头竖线 + 时间气泡 |
| `Jangy/TrackLaneView.swift` | L0 | 注册表驱动的车道容器 |
| `Jangy/TrackCap.swift` | L0 | 轨道头（图标 + 轨号 + 静音/隐藏），钉视口左缘、无实色底 |
| `Jangy/TrackLaneRegistry.swift` | L0 | 车道呈现器注册表（与 L2 `Manifest.swift` 同款形状） |
| `Jangy/Features/Video/VideoLane.swift` | L0 | 视频车道呈现器（缩略图条） |
| `Jangy/Features/Caption/CaptionLane.swift` | L0 | 字幕车道呈现器（cue 条 + 文本） |
| `Jangy/ZoomBadge.swift` | L0 | 缩放档位角标 |

**删除：** `Jangy/ThumbnailLoader.swift`（收口进 L3 `TimelineThumbnailer`）。

**修改：** `Jangy/EditorView.swift`（分界布局 + 选中态操作条 + 布局预设菜单）、`Jangy/AppModel.swift`（持有 `TimelineViewportState`、同步 contentDuration、擦洗 seek）、`Jangy/LibraryView.swift`（缩略图改调 L3）、`Packages/JangyCore/Sources/JangyCore/EditPlan.swift`（`PlanClip` 加 `transform` 字段 + 编解码）、`Packages/JangyCore/Sources/JangyCore/Features/Video/VideoFeature.swift`（transform 校验）、`Packages/JangyCore/Sources/JangyCore/Features/Video/VideoEngine.swift` 与 `EngineBridge.swift`（应用 transform）。

---

## Task 0: 叠加轨预览真机验证（✅ 已完成 2026-10-15）

**为什么最先做：** spec「待验证」节记着「叠加轨在预览中的实机表现：`Track` 走多输入 videoComposition，理论上预览可见，需真机确认」。这决定叠加轨能否进 v1（公约 §6.1「无法在预览实时呈现的效果不入 v1」）。

**结论：✅ 真机确认叠加轨在预览中可见**——叠加区间内叠加轨内容出现、结束后回到主轨（末帧未被保持），预览与导出一致。已回填 spec「待验证」节。**无需登记降级项**，叠加轨正常进 v1，后续 UI 按可见继续。

> 执行步骤保留如下，供将来回归（如换 iOS 版本 / 改多轨构建路径时重验）。

- [x] **Step 1: 造一个带叠加轨的 plan**

在 App 内用 Agent 建轨（顺带验了「Agent 建轨 → 预览」）：开 Agent sheet，让它「新建一条视频轨（绝对定位），在 0.5 秒处放另一段素材 2 秒」。Agent 的 `add_track` / `add_clip`（带 `trackID` + `at`）会产出带叠加轨的 plan。

CLI 路线（备选）：`sample` 输出作底，手加一条 `kind=video` / `placement=absolute` 轨（元素 `at=0.5` 引另一段素材），`swift run jangy-cli validate /tmp/overlay.json --assets /tmp/jangy-assets` 期望 `{"valid":true}`，再按 AGENTS.md 播种进 App 沙盒。

- [x] **Step 2: 真机观察（关键一步）**

在**真机**上（模拟器有已知直通像素格式怪癖，结论不可信）：
1. 播放头在叠加区间**之前**（如 0.2s）——画面是主轨素材。
2. 区间**之内**（如 1.0s）——**叠加轨素材出现**（无 transform 时是整幅覆盖，盖住主轨）。
3. 区间**之后**（如 3.0s）——回到主轨素材（末帧未被保持）。

三处都对 → 叠加轨进预览可用。**实测三处均对。**

- [x] **Step 3: 交叉核对导出**

App 内导出该工程（或 CLI `export`），1.0s 抽帧与预览一致。**实测一致。**

- [x] **Step 4: 记录结论**

✅ 叠加可见 → 已回填 spec「待验证」条目（`docs/superpowers/specs/2026-10-15-timeline-tracks-design.md`）。

---

## Task 1: L2 纯函数——缩略图源时间映射 + 输出起点

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/TimelineMapping.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/TimelineMappingTests.swift`

**设计要点：** 缩略图要「从源素材抽帧」，就需要把**成片输出时间**换算回**素材源时间**。这是纯算术，放 L2（纯 Swift、可测），L3 的 `TimelineThumbnailer` 调它。

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import JangyCore

final class TimelineMappingTests: XCTestCase {

    func testSourceTimeMapsOutputOffsetThroughSpeed() {
        // 源 [10,14]（长 4s），倍速 2 → 输出长 2s；输出偏移 0.5s → 源 10 + 0.5*2 = 11s
        let clip = PlanClip(assetID: UUID(), source: .video(10...14), speed: .flat(2.0))
        XCTAssertEqual(clip.sourceTime(forOutputOffset: 0), 10, accuracy: 0.001)
        XCTAssertEqual(clip.sourceTime(forOutputOffset: 0.5), 11, accuracy: 0.001)
        XCTAssertEqual(clip.sourceTime(forOutputOffset: 2.0), 14, accuracy: 0.001)
    }

    func testSourceTimeIsNilForStill() {
        // still 没有源区间，无从抽帧
        XCTAssertNil(PlanClip(assetID: UUID(), source: .still(duration: 3)).sourceTime(forOutputOffset: 1))
    }

    func testChainedTrackOutputStartsArePrefixSumsMinusOverlap() {
        // 3s@1x + 3s@0.5x(输出 6s，但这里用 1x 简化) —— 用带转场的算，验证扣重叠
        let a = PlanClip(assetID: UUID(), source: .video(0...3), transitionAfter: .dissolve(duration: 0.5))
        let b = PlanClip(assetID: UUID(), source: .video(0...3))
        let track = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(a))),
            PlanElement(content: .content(TrackPayload(b))),
        ])
        // a 占 [0,3)，dissolve 与 b 全额重叠 0.5 → b 起点 = 3 - 0.5 = 2.5
        XCTAssertEqual(track.elementOutputStarts(), [0, 2.5])
    }

    func testAbsoluteTrackOutputStartsComeFromAt() {
        let track = PlanTrack(kind: .video, placement: .absolute, elements: [
            PlanElement(at: 1, content: .content(TrackPayload(PlanClip(assetID: UUID(), source: .video(0...2))))),
            PlanElement(at: 4, content: .content(TrackPayload(PlanClip(assetID: UUID(), source: .video(0...2))))),
        ])
        XCTAssertEqual(track.elementOutputStarts(), [1, 4])
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/JangyCore && swift test --filter TimelineMappingTests`
Expected: 编译失败 —— `value of type 'PlanClip' has no member 'sourceTime'`

- [ ] **Step 3: 实现**

```swift
import Foundation

extension PlanClip {
    /// 元素内某「输出偏移」对应的**源素材时间**：源区间起点 + 输出偏移 × 倍速。
    /// 缩略图从源素材抽帧时用（输出时间轴 → 源时间轴）。
    /// 纯算术、可测；`.still` 无源区间，返回 nil（图片缩略图不走抽帧路径）。
    public func sourceTime(forOutputOffset offset: TimeInterval) -> TimeInterval? {
        guard case .video(let range) = source else { return nil }
        return range.lowerBound + offset * speed.rate
    }
}

extension PlanTrack {
    /// 每个元素在成片时间轴上的**输出起点**。
    /// - 链式轨：前缀和，逐段扣掉该段尾部转场的重叠量（与 `EditPlan.renderedDuration` 同口径）
    /// - 绝对轨：元素的 `at`
    /// 供缩略图把「可见输出区间」映射到各元素的输出偏移。
    public func elementOutputStarts() -> [TimeInterval] {
        switch placement {
        case .absolute:
            return elements.map { $0.at ?? 0 }
        case .chained:
            var starts: [TimeInterval] = []
            var cursor: TimeInterval = 0
            for element in elements {
                starts.append(cursor)
                cursor += element.duration
                if case .content(let payload) = element.content,
                   let clip = payload.value as? PlanClip,
                   let transition = clip.transitionAfter {
                    cursor -= transition.overlapDuration
                }
            }
            return starts
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd Packages/JangyCore && swift test --filter TimelineMappingTests`
Expected: PASS（4 个用例）

- [ ] **Step 5: 全量回归 + 提交**

Run: `cd Packages/JangyCore && swift test` → 295 + 4 = 299 全绿

```bash
git add Packages/JangyCore/Sources/JangyCore/TimelineMapping.swift \
        Packages/JangyCore/Tests/JangyCoreTests/TimelineMappingTests.swift
git commit -m "Core: 缩略图源时间映射与轨道输出起点（L2 纯函数）"
```

---

## Task 2: L1 `TimelineViewportState`

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/Interaction/TimelineViewportState.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/TimelineViewportStateTests.swift`

**设计要点：** 三个高频量的唯一归宿，**不进 `EditStore`**（公约 §2.2）。`playheadTime` + `pointsPerSecond` 是状态，`scrollOffset` 推出。播放头恒居中 → `scrollOffset = playheadTime × pointsPerSecond`（推导见注释）。

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import JangyCore

@MainActor
final class TimelineViewportStateTests: XCTestCase {

    private func makeState(width: CGFloat = 400, duration: TimeInterval = 100) -> TimelineViewportState {
        let s = TimelineViewportState(pointsPerSecond: 10)   // 100s 内容 = 1000pt
        s.viewportWidth = width
        s.contentDuration = duration
        return s
    }

    func testScrollOffsetIsPlayheadTimeTimesScale() {
        let s = makeState()
        s.setPlayhead(3)
        XCTAssertEqual(s.scrollOffset, 30, accuracy: 0.001)
    }

    func testTimeAtViewportCenterIsPlayheadTime() {
        let s = makeState()
        s.setPlayhead(7)
        XCTAssertEqual(s.time(atX: 200), 7, accuracy: 0.001, "视口中央恒等于播放头时间")
    }

    func testPlayheadClampsToContentDuration() {
        let s = makeState()
        s.setPlayhead(-5); XCTAssertEqual(s.playheadTime, 0)
        s.setPlayhead(999); XCTAssertEqual(s.playheadTime, 100)
    }

    func testScrubRightMovesPlayheadEarlier() {
        // 内容往右拖（dx>0）= 看更早的内容 = 播放头时间减小
        let s = makeState()
        s.setPlayhead(5)
        s.scrub(by: 20)   // 20pt / 10pps = 2s
        XCTAssertEqual(s.playheadTime, 3, accuracy: 0.001)
    }

    func testZoomKeepsTimeUnderAnchorFixed() {
        let s = makeState(width: 400, duration: 100)
        s.setPlayhead(50)
        let anchorX: CGFloat = 300            // 锚点在视口右侧
        let timeBefore = s.time(atX: anchorX) // = 50 + (300-200)/10 = 60
        XCTAssertEqual(timeBefore, 60, accuracy: 0.001)

        s.zoom(by: 2, anchorX: anchorX)       // pps 10 → 20
        XCTAssertEqual(s.pointsPerSecond, 20, accuracy: 0.001)
        XCTAssertEqual(s.time(atX: anchorX), 60, accuracy: 0.01, "锚点下的时间不动")
    }

    func testZoomClampsToScaleBounds() {
        let s = makeState()
        s.zoom(by: 0.0001, anchorX: 200)
        XCTAssertEqual(s.pointsPerSecond, TimelineViewportState.minPointsPerSecond, accuracy: 0.001)
        s.zoom(by: 1e9, anchorX: 200)
        XCTAssertEqual(s.pointsPerSecond, TimelineViewportState.maxPointsPerSecond, accuracy: 0.001)
    }

    func testVisibleTimeRangeSpansViewport() {
        let s = makeState(width: 400, duration: 100)
        s.setPlayhead(50)
        let r = s.visibleTimeRange
        XCTAssertEqual(r.lowerBound, 30, accuracy: 0.001)
        XCTAssertEqual(r.upperBound, 70, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/JangyCore && swift test --filter TimelineViewportStateTests`
Expected: 编译失败 —— `cannot find 'TimelineViewportState' in scope`

- [ ] **Step 3: 实现**

```swift
import CoreGraphics
import Foundation
import Observation

/// 时间线视口状态：三个高频量（播放头时间 / 缩放 px-per-sec / 滚动偏移）的唯一归宿。
/// **不进 EditStore**（公约 §2.2）——它每帧都变，进 plan 会让整棵 SwiftUI 树重算并污染撤销栈。
///
/// 单一事实源：`playheadTime` + `pointsPerSecond` 是状态，`scrollOffset` 由二者推出。
/// 播放头恒在视口水平中央（内容带半个视口宽的左右留白，故 t=0 / 片尾也能居中）。
/// 于是「滚动」与「擦洗」是同一件事：内容相对播放头平移 = 播放头下的时间改变。
///
/// 推导：内容坐标里，时间 t 的 x = 留白 + t·pps = W/2 + t·pps。
/// 让「t = playheadTime」落在视口中央（视口坐标 x = W/2）所需的内容偏移 =
/// (W/2 + playheadTime·pps) − W/2 = playheadTime·pps。
@MainActor
@Observable
public final class TimelineViewportState {
    /// 播放头时间（秒）= 视口中央那一点对应的时间。范围 [0, contentDuration]。
    public private(set) var playheadTime: TimeInterval = 0
    /// 缩放：每秒占多少点。夹在 [minPointsPerSecond, maxPointsPerSecond]。
    public private(set) var pointsPerSecond: CGFloat = 60
    /// 内容总时长（= `plan.renderedDuration`）。plan 变化后由 App 同步进来。
    public var contentDuration: TimeInterval = 0
    /// 视口宽度（点）。由 L0 的 GeometryReader 回填，缩放锚点换算要用。
    public var viewportWidth: CGFloat = 0

    public static let minPointsPerSecond: CGFloat = 8
    public static let maxPointsPerSecond: CGFloat = 480

    /// 初始缩放可指定（夹在档位边界内）；运行时缩放一律走 `zoom(by:anchorX:)`。
    public init(pointsPerSecond: CGFloat = 60) {
        self.pointsPerSecond = min(max(Self.minPointsPerSecond, pointsPerSecond),
                                   Self.maxPointsPerSecond)
    }

    /// 内容相对视口左缘的偏移（点）。= 播放头时间 × px/s（见类注释推导）。
    public var scrollOffset: CGFloat { CGFloat(playheadTime) * pointsPerSecond }

    /// 视口内某点（点，相对视口左缘）对应的时间。
    public func time(atX x: CGFloat) -> TimeInterval {
        playheadTime + TimeInterval((x - viewportWidth / 2) / pointsPerSecond)
    }

    /// 内容坐标：时间 t 相对内容左缘的 x（含半视口留白）。
    public func x(forTime t: TimeInterval) -> CGFloat {
        viewportWidth / 2 + CGFloat(t) * pointsPerSecond
    }

    /// 单指横向拖拽 = 滚动 = 擦洗。dx 为位移（点，右正）。
    public func scrub(by dx: CGFloat) {
        setPlayhead(playheadTime - TimeInterval(dx / pointsPerSecond))
    }

    /// 直接落播放头（播放推进 / 点选定位）。夹在 [0, contentDuration]。
    public func setPlayhead(_ t: TimeInterval) {
        playheadTime = min(max(0, t), max(0, contentDuration))
    }

    /// 双指捏合：以视口内 anchorX 为锚点缩放 px/s（锚点下的时间保持不动）。
    public func zoom(by factor: CGFloat, anchorX: CGFloat) {
        let anchorTime = time(atX: anchorX)
        let next = min(max(Self.minPointsPerSecond, pointsPerSecond * factor),
                       Self.maxPointsPerSecond)
        guard next != pointsPerSecond else { return }
        pointsPerSecond = next
        // 让 anchorTime 重新落在 anchorX 下：playheadTime = anchorTime − (anchorX − W/2)/pps
        setPlayhead(anchorTime - TimeInterval((anchorX - viewportWidth / 2) / pointsPerSecond))
    }

    /// 当前视口覆盖的时间区间（缩略图只渲可见区用）。
    public var visibleTimeRange: ClosedRange<TimeInterval> {
        let lo = time(atX: 0), hi = time(atX: viewportWidth)
        return min(lo, hi)...max(lo, hi)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd Packages/JangyCore && swift test --filter TimelineViewportStateTests`
Expected: PASS（7 个用例）

- [ ] **Step 5: 提交**

```bash
git add Packages/JangyCore/Sources/JangyCore/Interaction/TimelineViewportState.swift \
        Packages/JangyCore/Tests/JangyCoreTests/TimelineViewportStateTests.swift
git commit -m "Core: L1 TimelineViewportState（高频视口状态，播放头居中=滚动即擦洗）"
```

---

## Task 3: L1 `SnapEngine`

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/Interaction/SnapEngine.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/SnapEngineTests.swift`

**设计要点：** 纯函数。吸附点 = 0、成片时长、所有轨的元素边界。「主轨末端是吸附点」（spec「风险与缓解」）由此天然满足。

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import JangyCore

final class SnapEngineTests: XCTestCase {

    func testSnapPointsIncludeZeroEndAndAllBoundaries() {
        let a = PlanClip(assetID: UUID(), source: .video(0...3))
        let b = PlanClip(assetID: UUID(), source: .video(0...2))
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(a))),
            PlanElement(content: .content(TrackPayload(b))),
        ])
        let overlay = PlanTrack(kind: .video, placement: .absolute, elements: [
            PlanElement(at: 4, content: .content(TrackPayload(PlanClip(assetID: UUID(), source: .video(0...1))))),
        ])
        let plan = EditPlan(tracks: [primary, overlay], primaryTrackID: primary.id)

        let points = SnapEngine.snapPoints(in: plan)
        // 主轨边界 0,3,5；成片时长 5；叠加轨 4,5
        XCTAssertEqual(points, [0, 3, 4, 5])
    }

    func testSnapPicksNearestWithinTolerance() {
        XCTAssertEqual(SnapEngine.snap(3.05, to: [0, 3, 5], within: 0.1), 3, accuracy: 0.0001)
    }

    func testSnapReturnsCandidateWhenNothingInRange() {
        XCTAssertEqual(SnapEngine.snap(4.0, to: [0, 3, 5], within: 0.1), 4.0, accuracy: 0.0001)
    }

    func testSnapPicksCloserOfTwoCandidates() {
        XCTAssertEqual(SnapEngine.snap(2.9, to: [3, 2], within: 1.0), 3, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/JangyCore && swift test --filter SnapEngineTests`
Expected: 编译失败 —— `cannot find 'SnapEngine' in scope`

- [ ] **Step 3: 实现**

```swift
import Foundation

/// 吸附：把候选时间吸到阈值内最近的吸附点。纯函数、无状态。
public enum SnapEngine {

    /// 收集吸附点：0、成片时长、以及所有轨的元素边界（起点 / 终点）。
    /// 链式轨的起点按前缀和（扣转场重叠）算，与输出时间轴一致。
    public static func snapPoints(in plan: EditPlan) -> [TimeInterval] {
        var points: Set<TimeInterval> = [0, plan.renderedDuration]
        for track in plan.tracks {
            var cursor: TimeInterval = 0
            for element in track.elements {
                let start = element.at ?? cursor
                let end = start + element.duration
                points.insert(start)
                points.insert(end)
                cursor = end
                if case .content(let payload) = element.content,
                   let clip = payload.value as? PlanClip,
                   let transition = clip.transitionAfter {
                    cursor -= transition.overlapDuration
                }
            }
        }
        return points.sorted()
    }

    /// 把 candidate 吸到 tolerance 内最近的点；无命中则原样返回。
    public static func snap(_ candidate: TimeInterval, to points: [TimeInterval],
                            within tolerance: TimeInterval) -> TimeInterval {
        var best: TimeInterval?
        var bestDistance = tolerance
        for point in points {
            let distance = abs(point - candidate)
            if distance <= bestDistance {
                bestDistance = distance
                best = point
            }
        }
        return best ?? candidate
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd Packages/JangyCore && swift test --filter SnapEngineTests`
Expected: PASS（4 个用例）

- [ ] **Step 5: 提交**

```bash
git add Packages/JangyCore/Sources/JangyCore/Interaction/SnapEngine.swift \
        Packages/JangyCore/Tests/JangyCoreTests/SnapEngineTests.swift
git commit -m "Core: L1 SnapEngine（吸附点收集 + 阈值吸附，纯函数）"
```

---

## Task 4: L1 `DragSession` + `GestureRouter` + `TimelineEdit`

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/Interaction/DragSession.swift`
- Create: `Packages/JangyCore/Sources/JangyCore/Interaction/GestureRouter.swift`
- Create: `Packages/JangyCore/Sources/JangyCore/Interaction/TimelineEdit.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/DragSessionTests.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/TimelineEditTests.swift`

**设计要点：**
- `DragSession` 是**值类型**：L0 用 `@State` 持有它，每帧 `.onChanged` 只改这个局部值 → EditPlan 不动（公约 §6.5）。
- `resolve(...)` 是纯函数：拖拽瞬态 + 视口 + 吸附点 → `TimelineEdit?`（`nil` = 净变化为零，不落栈）。这是本任务的核心可测逻辑。
- `TimelineEdit.apply(to:)` 是 L1 的翻译职责（公约 §2.3）：把语义意图落成一次 `EditStore.apply`。
- **L1 不认识具体轨类型**（公约 §1）：`resolve` 只按 `placement`（结构）与 payload 的通用时长分派，不 `switch kind`。

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import JangyCore

final class DragSessionTests: XCTestCase {

    private func mainPlan(_ clips: [PlanClip], assets: [AssetItem] = []) -> EditPlan {
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: clips.map { PlanElement(content: .content(TrackPayload($0))) })
        return EditPlan(assets: assets, tracks: [primary], primaryTrackID: primary.id)
    }

    private func context(_ plan: EditPlan, pps: CGFloat = 100,
                         rowHeight: CGFloat = 64) -> DragContext {
        DragContext(plan: plan, pointsPerSecond: pps,
                    snapPoints: SnapEngine.snapPoints(in: plan), snapTolerance: 0.05,
                    trackRowHeight: rowHeight, minElementDuration: 0.2)
    }

    // MARK: trim

    func testTrimTrailingEdgeShortensSourceRange() {
        let plan = mainPlan([PlanClip(assetID: UUID(), source: .video(0...4))])
        let id = plan.primaryTrack!.elements[0].id
        let session = DragSession(kind: .trim(elementID: id, edge: .trailing))
            .translated(to: CGSize(width: -100, height: 0))   // -100pt / 100pps = -1s

        let edit = session.resolve(in: context(plan))
        guard case .trimSource(_, .video(let range))? = edit else { return XCTFail("期望 trimSource") }
        XCTAssertEqual(range.lowerBound, 0, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 3, accuracy: 0.001)
    }

    func testTrimLeadingEdgeClampsAtZero() {
        let plan = mainPlan([PlanClip(assetID: UUID(), source: .video(0...4))])
        let id = plan.primaryTrack!.elements[0].id
        let session = DragSession(kind: .trim(elementID: id, edge: .leading))
            .translated(to: CGSize(width: 500, height: 0))    // 想推到 +5s，超过区间长
        let edit = session.resolve(in: context(plan))
        guard case .trimSource(_, .video(let range))? = edit else { return XCTFail("期望 trimSource") }
        XCTAssertLessThan(range.upperBound - range.lowerBound, 4, "必须留下正长度")
        XCTAssertGreaterThanOrEqual(range.lowerBound, 0)
    }

    func testTrimNoOpReturnsNil() {
        let plan = mainPlan([PlanClip(assetID: UUID(), source: .video(0...4))])
        let id = plan.primaryTrack!.elements[0].id
        let session = DragSession(kind: .trim(elementID: id, edge: .trailing))
            .translated(to: .zero)
        XCTAssertNil(session.resolve(in: context(plan)), "零位移不落栈")
    }

    func testTrimSnapsToNearbyBoundary() {
        // 三段：边界 0/5/7/9。把第一段右缘从 5 拖到 6.97s，应吸到下一段起点 7。
        // （必须注册素材，否则 assetDuration 回落成原区间上界，扩不出原区间）
        let asset = AssetItem(kind: .video, fileName: "v.mp4", duration: 20)
        let plan = mainPlan([
            PlanClip(assetID: asset.id, source: .video(0...5)),
            PlanClip(assetID: asset.id, source: .video(0...2)),
            PlanClip(assetID: asset.id, source: .video(0...2)),
        ], assets: [asset])
        let id = plan.primaryTrack!.elements[0].id
        let session = DragSession(kind: .trim(elementID: id, edge: .trailing))
            .translated(to: CGSize(width: 197, height: 0))   // 5 → 6.97s
        let edit = session.resolve(in: context(plan))
        guard case .trimSource(_, .video(let range))? = edit else { return XCTFail("期望 trimSource") }
        XCTAssertEqual(range.upperBound, 7, accuracy: 0.001, "吸附到相邻边界")
    }

    // MARK: move（绝对轨）

    func testMoveAbsoluteElementSetsSnappedAt() {
        let overlay = PlanTrack(kind: .video, placement: .absolute, elements: [
            PlanElement(at: 2, content: .content(TrackPayload(PlanClip(assetID: UUID(), source: .video(0...2))))),
        ])
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: [PlanElement(content: .gap(duration: 10))])
        let plan = EditPlan(tracks: [primary, overlay], primaryTrackID: primary.id)
        let id = overlay.elements[0].id

        let session = DragSession(kind: .moveElement(elementID: id, fromTrackID: overlay.id))
            .translated(to: CGSize(width: 100, height: 0))    // +1s
        let edit = session.resolve(in: context(plan))
        guard case .moveElement(_, _, .some(let at))? = edit else { return XCTFail("期望 moveElement 带 at") }
        XCTAssertEqual(at, 3, accuracy: 0.001)
    }

    // MARK: 换轨

    func testMoveToOtherTrackByVerticalTranslation() {
        let overlay = PlanTrack(kind: .video, placement: .absolute, elements: [
            PlanElement(at: 1, content: .content(TrackPayload(PlanClip(assetID: UUID(), source: .video(0...2))))),
        ])
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: [PlanElement(content: .gap(duration: 10))])
        let plan = EditPlan(tracks: [primary, overlay], primaryTrackID: primary.id)
        let id = overlay.elements[0].id

        // 向上拖一行（rowHeight 64）→ 目标轨 = primary
        let session = DragSession(kind: .moveElement(elementID: id, fromTrackID: overlay.id))
            .translated(to: CGSize(width: 0, height: -64))
        let edit = session.resolve(in: context(plan, rowHeight: 64))
        guard case .moveElement(_, .some(let trackID), _)? = edit else { return XCTFail("期望换轨") }
        XCTAssertEqual(trackID, primary.id)
    }

    // MARK: 轨道重排

    func testReorderTrackByVerticalTranslation() {
        let a = PlanTrack(kind: .video, placement: .chained,
                          elements: [PlanElement(content: .gap(duration: 5))])
        let b = PlanTrack(kind: .video, placement: .absolute)
        let plan = EditPlan(tracks: [a, b], primaryTrackID: a.id)

        let session = DragSession(kind: .reorderTrack(trackID: b.id))
            .translated(to: CGSize(width: 0, height: -64))   // 上移一行
        let edit = session.resolve(in: context(plan, rowHeight: 64))
        XCTAssertEqual(edit, .reorderTrack(trackID: b.id, toIndex: 0))
    }

    func testReorderFirstTrackUpIsNoOp() {
        let a = PlanTrack(kind: .video, placement: .chained,
                          elements: [PlanElement(content: .gap(duration: 5))])
        let plan = EditPlan(tracks: [a], primaryTrackID: a.id)
        let session = DragSession(kind: .reorderTrack(trackID: a.id))
            .translated(to: CGSize(width: 0, height: -64))
        XCTAssertNil(session.resolve(in: context(plan)), "已在顶部，上移无净变化")
    }
}

final class GestureRouterTests: XCTestCase {
    func testTrimHandleHitMakesTrimSession() {
        let id = UUID()
        let s = GestureRouter.trimSession(for: .trimHandle(elementID: id, edge: .leading))
        XCTAssertEqual(s?.kind, .trim(elementID: id, edge: .leading))
    }

    func testLiftOnElementMakesMoveSession() {
        let element = PlanElement(content: .gap(duration: 2))
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [element])
        let plan = EditPlan(tracks: [primary], primaryTrackID: primary.id)
        let s = GestureRouter.liftSession(for: .element(id: element.id), plan: plan)
        XCTAssertEqual(s?.kind, .moveElement(elementID: element.id, fromTrackID: primary.id))
    }

    func testLiftOnEmptyMakesNoSession() {
        let primary = PlanTrack(kind: .video, placement: .chained)
        let plan = EditPlan(tracks: [primary], primaryTrackID: primary.id)
        XCTAssertNil(GestureRouter.liftSession(for: .empty, plan: plan))
    }

    func testLiftOnTrackCapMakesReorderSession() {
        let primary = PlanTrack(kind: .video, placement: .chained)
        let plan = EditPlan(tracks: [primary], primaryTrackID: primary.id)
        XCTAssertEqual(GestureRouter.liftSession(for: .trackCap(trackID: primary.id), plan: plan)?.kind,
                       .reorderTrack(trackID: primary.id))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/JangyCore && swift test --filter DragSessionTests`
Expected: 编译失败 —— `cannot find 'DragSession' in scope`

- [ ] **Step 3: 实现 `DragSession.swift`**

```swift
import CoreGraphics
import Foundation

/// 拖拽解析所需的上下文（纯数据，无 UI 依赖）。
public struct DragContext: Sendable {
    public let plan: EditPlan
    public let pointsPerSecond: CGFloat
    public let snapPoints: [TimeInterval]
    public let snapTolerance: TimeInterval
    /// 轨道行高（点），轨道重排按它换算位移 → 目标下标。
    public let trackRowHeight: CGFloat
    /// 元素最短时长（秒），trim 不许短于它。
    public let minElementDuration: TimeInterval

    public init(plan: EditPlan, pointsPerSecond: CGFloat, snapPoints: [TimeInterval],
                snapTolerance: TimeInterval, trackRowHeight: CGFloat,
                minElementDuration: TimeInterval) {
        self.plan = plan
        self.pointsPerSecond = pointsPerSecond
        self.snapPoints = snapPoints
        self.snapTolerance = snapTolerance
        self.trackRowHeight = trackRowHeight
        self.minElementDuration = minElementDuration
    }
}

/// 一次「按下 → 拖 → 抬手」的全过程状态。**值语义**——L0 用 @State 持有，
/// 每帧更新只改这个局部值，EditPlan 一个字节不动（公约 §6.5 高频分界）。
public struct DragSession: Equatable, Sendable {
    public enum Edge: Equatable, Sendable { case leading, trailing }

    public enum Kind: Equatable, Sendable {
        /// 拖元素左右边缘手柄 = trim。
        case trim(elementID: UUID, edge: Edge)
        /// 长按元素浮起后拖 = 移动（改位置 / 换轨）。
        case moveElement(elementID: UUID, fromTrackID: UUID)
        /// 长按轨道头上下拖 = 轨道重排。
        case reorderTrack(trackID: UUID)
    }

    public let kind: Kind
    /// 累计位移（点，右正 / 下正）。
    public var translation: CGSize = .zero

    public init(kind: Kind) { self.kind = kind }

    public func translated(to translation: CGSize) -> DragSession {
        var copy = self
        copy.translation = translation
        return copy
    }

    /// 由拖拽瞬态解析出抬手要落的原子编辑；nil = 净变化为零（不落栈）。
    public func resolve(in context: DragContext) -> TimelineEdit? {
        switch kind {
        case .trim(let elementID, let edge):
            return resolveTrim(elementID: elementID, edge: edge, context: context)
        case .moveElement(let elementID, let fromTrackID):
            return resolveMove(elementID: elementID, fromTrackID: fromTrackID, context: context)
        case .reorderTrack(let trackID):
            return resolveReorder(trackID: trackID, context: context)
        }
    }

    // MARK: trim

    private func resolveTrim(elementID: UUID, edge: Edge, context: DragContext) -> TimelineEdit? {
        guard let (element, clip) = findClip(elementID, in: context.plan) else { return nil }
        let deltaSeconds = TimeInterval(translation.width / context.pointsPerSecond)
        guard deltaSeconds != 0 else { return nil }

        let snapTolerance = context.snapTolerance
        switch clip.source {
        case .video(let range):
            let assetDuration = context.plan.asset(withID: clip.assetID)?.duration ?? range.upperBound
            var lower = range.lowerBound, upper = range.upperBound
            switch edge {
            case .leading:
                lower = SnapEngine.snap(range.lowerBound + deltaSeconds, to: context.snapPoints, within: snapTolerance)
                lower = min(max(0, lower), upper - context.minElementDuration)
            case .trailing:
                upper = SnapEngine.snap(range.upperBound + deltaSeconds, to: context.snapPoints, within: snapTolerance)
                upper = min(max(lower + context.minElementDuration, upper), assetDuration)
            }
            if lower == range.lowerBound, upper == range.upperBound { return nil }
            return .trimSource(elementID: elementID, source: .video(lower...upper))

        case .still(let duration):
            var newDuration = duration
            switch edge {
            case .leading, .trailing:   // still 只有时长，两端等效
                newDuration = duration + (edge == .leading ? -deltaSeconds : deltaSeconds)
                newDuration = max(context.minElementDuration, newDuration)
            }
            if newDuration == duration { return nil }
            return .trimSource(elementID: elementID, source: .still(duration: newDuration))
        }
    }

    // MARK: move

    private func resolveMove(elementID: UUID, fromTrackID: UUID, context: DragContext) -> TimelineEdit? {
        let plan = context.plan
        guard let fromTrack = plan.tracks.first(where: { $0.id == fromTrackID }),
              let element = fromTrack.elements.first(where: { $0.id == elementID }) else { return nil }

        // 纵向换轨：按行高把位移换算成轨道下标偏移
        var targetTrackID = fromTrackID
        if context.trackRowHeight > 0, translation.height != 0 {
            let rowDelta = Int((translation.height / context.trackRowHeight).rounded())
            if rowDelta != 0, let fromIndex = plan.tracks.firstIndex(where: { $0.id == fromTrackID }) {
                let target = min(max(0, fromIndex + rowDelta), plan.tracks.count - 1)
                targetTrackID = plan.tracks[target].id
            }
        }

        // 目标轨是绝对定位：横向位移 → at（吸附）
        if let targetTrack = plan.tracks.first(where: { $0.id == targetTrackID }),
           targetTrack.placement == .absolute {
            let deltaSeconds = TimeInterval(translation.width / context.pointsPerSecond)
            let originalAt = element.at ?? 0
            var at = SnapEngine.snap(originalAt + deltaSeconds, to: context.snapPoints,
                                     within: context.snapTolerance)
            at = max(0, at)
            if targetTrackID == fromTrackID, at == originalAt { return nil }
            return .moveElement(elementID: elementID, toTrackID: targetTrackID, at: at, toIndex: nil)
        }

        // 目标轨是链式：横向位移 → 目标下标（相对定位）
        if targetTrackID != fromTrackID {
            // 换到链式轨 = 追加到末尾（下标交给 apply 里按目标轨长度决定）
            return .moveElement(elementID: elementID, toTrackID: targetTrackID, at: nil, toIndex: nil)
        }
        return resolveReorderWithinChained(elementID: elementID, track: fromTrack, context: context)
    }

    /// 链式轨内横向拖动 = 重排：按拖动后元素中心与其余元素区间的相对位置算目标下标。
    private func resolveReorderWithinChained(elementID: UUID, track: PlanTrack,
                                              context: DragContext) -> TimelineEdit? {
        guard let currentIndex = track.elements.firstIndex(where: { $0.id == elementID }) else { return nil }
        let starts = track.elementOutputStarts()
        let element = track.elements[currentIndex]
        let deltaSeconds = TimeInterval(translation.width / context.pointsPerSecond)
        let draggedCenter = starts[currentIndex] + element.duration / 2 + deltaSeconds

        // 目标下标 = 拖后中心落在哪个间隙
        var targetIndex = track.elements.count - 1
        for (i, start) in starts.enumerated() where i != currentIndex {
            if draggedCenter < start + track.elements[i].duration / 2 {
                targetIndex = i
                break
            }
        }
        // 归一：移除自身后插入到 targetIndex 之前
        var insertion = targetIndex
        if targetIndex > currentIndex { insertion -= 1 }
        if insertion == currentIndex { return nil }
        return .moveElement(elementID: elementID, toTrackID: track.id, at: nil, toIndex: insertion)
    }

    // MARK: reorder track

    private func resolveReorder(trackID: UUID, context: DragContext) -> TimelineEdit? {
        guard context.trackRowHeight > 0,
              let fromIndex = context.plan.tracks.firstIndex(where: { $0.id == trackID }) else { return nil }
        let rowDelta = Int((translation.height / context.trackRowHeight).rounded())
        let target = min(max(0, fromIndex + rowDelta), context.plan.tracks.count - 1)
        guard target != fromIndex else { return nil }
        return .reorderTrack(trackID: trackID, toIndex: target)
    }

    // MARK: helpers

    private func findClip(_ elementID: UUID, in plan: EditPlan) -> (PlanElement, PlanClip)? {
        for track in plan.tracks {
            for element in track.elements where element.id == elementID {
                guard case .content(let payload) = element.content,
                      let clip = payload.value as? PlanClip else { return nil }
                return (element, clip)
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: 实现 `GestureRouter.swift`**

```swift
import Foundation

/// 手势 → 会话的路由：按下时按命中对象决定开哪种 `DragSession`。
/// 纯函数——**几何命中由 L0 做**（它才有布局），这里只把「命中了什么」翻成会话。
/// 不认识具体轨类型（公约 §1）：只按「元素 / 手柄 / 轨道头」这类结构信息路由。
public enum GestureRouter {

    /// 命中对象（L0 的几何命中结果）。
    public enum Hit: Equatable, Sendable {
        case trimHandle(elementID: UUID, edge: DragSession.Edge)
        case element(id: UUID)
        case trackCap(trackID: UUID)
        case empty
    }

    /// 长按拾起后的会话：元素 → 移动，轨道头 → 重排，空处 → nil（那是滚动，不是编辑）。
    public static func liftSession(for hit: Hit, plan: EditPlan) -> DragSession? {
        switch hit {
        case .element(let id):
            guard let track = plan.tracks.first(where: { $0.elements.contains { $0.id == id } })
            else { return nil }
            return DragSession(kind: .moveElement(elementID: id, fromTrackID: track.id))
        case .trackCap(let trackID):
            return DragSession(kind: .reorderTrack(trackID: trackID))
        case .trimHandle, .empty:
            return nil
        }
    }

    /// 直接拖 trim 手柄的会话。
    public static func trimSession(for hit: Hit) -> DragSession? {
        guard case .trimHandle(let elementID, let edge) = hit else { return nil }
        return DragSession(kind: .trim(elementID: elementID, edge: edge))
    }
}
```

- [ ] **Step 5: 实现 `TimelineEdit.swift`**

```swift
import Foundation

/// L1 产出的**原子编辑意图**。L0 抬手时把它交给 `apply(to:)`——
/// 这是 L1 的职责：把一次用户操作翻译成对 EditPlan 的原子修改（公约 §2.3）。
/// 校验 / 不变式 / 归一化一律由 `EditStore.apply` 兜（L1 不写合法性校验，公约 §1）。
public enum TimelineEdit: Equatable, Sendable {
    /// trim：结果直接是新的 source（video 区间 / still 时长）。
    case trimSource(elementID: UUID, source: PlanClipSource)
    /// 移动：换到 toTrackID（nil = 不换轨）；绝对轨用 at 定位，链式轨用 toIndex 定位。
    case moveElement(elementID: UUID, toTrackID: UUID?, at: TimeInterval?, toIndex: Int?)
    /// 轨道重排：把 trackID 移到 toIndex。
    case reorderTrack(trackID: UUID, toIndex: Int)

    @discardableResult
    public func apply(to store: EditStore) -> Result<EditPlan, ValidationFailure> {
        store.apply { plan in
            switch self {
            case .trimSource(let elementID, let source):
                guard let location = Self.locate(elementID, in: plan),
                      case .content(let payload) = plan.tracks[location.track].elements[location.element].content,
                      var clip = payload.value as? PlanClip else { return }
                clip.source = source
                plan.tracks[location.track].elements[location.element].content = .content(TrackPayload(clip))

            case .moveElement(let elementID, let toTrackID, let at, let toIndex):
                guard let location = Self.locate(elementID, in: plan) else { return }
                var element = plan.tracks[location.track].elements.remove(at: location.element)
                let destination = toTrackID.flatMap { id in
                    plan.tracks.firstIndex { $0.id == id }
                } ?? location.track
                if let at { element.at = at }
                // 换到链式轨时清掉 at（链式轨位置由顺序推出，留着就是第二个事实源）
                else if plan.tracks[destination].placement == .chained { element.at = nil }
                if let toIndex {
                    let clamped = min(max(0, toIndex), plan.tracks[destination].elements.count)
                    plan.tracks[destination].elements.insert(element, at: clamped)
                } else {
                    plan.tracks[destination].elements.append(element)
                }

            case .reorderTrack(let trackID, let toIndex):
                guard let from = plan.tracks.firstIndex(where: { $0.id == trackID }) else { return }
                let clamped = min(max(0, toIndex), plan.tracks.count - 1)
                let moved = plan.tracks.remove(at: from)
                plan.tracks.insert(moved, at: clamped)
            }
        }
    }

    private static func locate(_ elementID: UUID, in plan: EditPlan) -> (track: Int, element: Int)? {
        for (ti, track) in plan.tracks.enumerated() {
            if let ei = track.elements.firstIndex(where: { $0.id == elementID }) { return (ti, ei) }
        }
        return nil
    }
}
```

- [ ] **Step 6: 运行确认通过**

Run: `cd Packages/JangyCore && swift test --filter DragSessionTests && swift test --filter GestureRouterTests`
Expected: PASS（DragSession 8 + GestureRouter 4）

- [ ] **Step 7: 补 `TimelineEditTests`（翻译路径对着真 store 测）**

```swift
import XCTest
@testable import JangyCore

@MainActor
final class TimelineEditTests: XCTestCase {

    private func store(clips: [PlanClip]) -> EditStore {
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: clips.map { PlanElement(content: .content(TrackPayload($0))) })
        return EditStore(initial: EditPlan(tracks: [primary], primaryTrackID: primary.id))
    }

    func testTrimSourceAppliesAndPushesOneUndoStep() {
        let s = store(clips: [PlanClip(assetID: UUID(), source: .video(0...4))])
        let id = s.plan.primaryTrack!.elements[0].id
        let before = s.historyCount

        let result = TimelineEdit.trimSource(elementID: id, source: .video(1...3)).apply(to: s)
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(s.historyCount, before + 1, "一次编辑只 +1 撤销步")
        XCTAssertEqual(s.plan.renderedDuration, 2, accuracy: 0.001)
    }

    func testMoveToChainedTrackAppendsAndKeepsInvariants() {
        let overlay = PlanTrack(kind: .video, placement: .absolute, elements: [
            PlanElement(at: 1, content: .content(TrackPayload(PlanClip(assetID: UUID(), source: .video(0...2))))),
        ])
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: [PlanElement(content: .content(TrackPayload(PlanClip(assetID: UUID(), source: .video(0...3)))) )])
        let s = EditStore(initial: EditPlan(tracks: [primary, overlay], primaryTrackID: primary.id))
        let id = overlay.elements[0].id

        _ = TimelineEdit.moveElement(elementID: id, toTrackID: primary.id, at: nil, toIndex: nil).apply(to: s)
        XCTAssertEqual(s.plan.primaryTrack!.elements.count, 2, "元素进主轨")
        XCTAssertTrue(s.plan.tracks[1].elements.isEmpty, "叠加轨清空")
    }

    func testReorderTrackMovesRow() {
        let a = PlanTrack(kind: .video, placement: .chained,
                          elements: [PlanElement(content: .gap(duration: 3))])
        let b = PlanTrack(kind: .video, placement: .absolute)
        let s = EditStore(initial: EditPlan(tracks: [a, b], primaryTrackID: a.id))

        _ = TimelineEdit.reorderTrack(trackID: b.id, toIndex: 0).apply(to: s)
        XCTAssertEqual(s.plan.tracks[0].id, b.id)
        XCTAssertEqual(s.plan.tracks[1].id, a.id)
    }
}
```

- [ ] **Step 8: 运行确认通过**

Run: `cd Packages/JangyCore && swift test --filter TimelineEditTests`
Expected: PASS（3 个用例）

- [ ] **Step 9: 全量回归 + 提交**

Run: `cd Packages/JangyCore && swift test` → 310 + 15 = 325 全绿

```bash
git add Packages/JangyCore/Sources/JangyCore/Interaction/DragSession.swift \
        Packages/JangyCore/Sources/JangyCore/Interaction/GestureRouter.swift \
        Packages/JangyCore/Sources/JangyCore/Interaction/TimelineEdit.swift \
        Packages/JangyCore/Tests/JangyCoreTests/DragSessionTests.swift \
        Packages/JangyCore/Tests/JangyCoreTests/TimelineEditTests.swift
git commit -m "Core: L1 DragSession/GestureRouter/TimelineEdit（拖拽解析 + 原子意图翻译）"
```

---

## Task 5: L3 `TimelineThumbnailer`（含 `ThumbnailLoader` 从 L0 收口）

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/TimelineThumbnailer.swift`
- Delete: `Jangy/ThumbnailLoader.swift`
- Modify: `Jangy/LibraryView.swift`（缩略图改调 L3）
- Test: `Packages/JangyCore/Tests/JangyCoreTests/TimelineThumbnailerTests.swift`

**设计要点：**
- 从**源素材**抽帧（不是 composition）：缓存键 = `assetID + 档位 + 时间桶`，同一素材多处复用。
- 档位离散（80 / 160 / 320 px 高）。
- 返回 `CGImage`（**不返回 UIImage**——`swift test` 在 macOS 上构建，JangyCore 不能 import UIKit，见 `CoverGenerator` 注释）。L0 用 `Image(decorative: cgImage, scale:)` 包。
- `actor`：缓存 + 生成串行化，避免 Swift 6 严格并发下的静态可变状态告警。
- 顺带把 `ThumbnailLoader.load`（素材库用的单帧缩略图）也搬进来，`LibraryView` 改调。

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
import CoreGraphics
@testable import JangyCore
@testable import JangyTestSupport

final class TimelineThumbnailerTests: XCTestCase {
    private var dir: URL!
    private var resolver: AssetResolver!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        resolver = try AssetSynthesizer.synthesize(into: dir)
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func videoAsset(_ name: String) -> AssetItem {
        AssetItem(kind: .video, fileName: name, origin: .synthesized,
                  duration: 4.0, pixelWidth: 1280, pixelHeight: 720, hasAudio: false)
    }

    func testFramesAreProducedAtRequestedOutputOffsets() async throws {
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let asset = videoAsset("clip1.mp4")
        let clip = PlanClip(assetID: asset.id, source: .video(0...4), speed: .flat(1.0))

        let frames = await thumbnailer.frames(asset: asset, clip: clip, level: .medium,
                                              outputOffsets: [0, 1, 2])
        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(frames.allSatisfy { $0 != nil }, "纯色素材每桶都应抽到帧")
    }

    func testFramesMapThroughSpeed() async throws {
        // 倍速 2：输出偏移 1s → 源 2s，仍应落在源区间 [0,4] 内抽出帧
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let asset = videoAsset("clip1.mp4")
        let clip = PlanClip(assetID: asset.id, source: .video(0...4), speed: .flat(2.0))
        let frames = await thumbnailer.frames(asset: asset, clip: clip, level: .small,
                                              outputOffsets: [0.5, 1.0])
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames.allSatisfy { $0 != nil })
    }

    func testStillAssetFramesAreNil() async throws {
        // 图片没有源区间，抽帧路径返回 nil（L0 走降采样兜底）
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let asset = AssetItem(kind: .image, fileName: "clip1.mp4")   // 借用存在的文件即可
        let clip = PlanClip(assetID: asset.id, source: .still(duration: 3))
        let frames = await thumbnailer.frames(asset: asset, clip: clip, level: .medium,
                                              outputOffsets: [0, 1])
        XCTAssertEqual(frames, [nil, nil])
    }

    func testAssetThumbnailReturnsImageForVideo() async throws {
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let image = await thumbnailer.thumbnail(for: videoAsset("clip1.mp4"), maxPixel: 240)
        XCTAssertNotNil(image)
    }

    func testCacheReturnsSameInstanceForRepeatedRequest() async throws {
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let asset = videoAsset("clip1.mp4")
        let clip = PlanClip(assetID: asset.id, source: .video(0...4))
        let first = await thumbnailer.frames(asset: asset, clip: clip, level: .medium, outputOffsets: [1])
        let second = await thumbnailer.frames(asset: asset, clip: clip, level: .medium, outputOffsets: [1])
        XCTAssertTrue(first[0] === second[0], "同键应命中缓存、返回同一 CGImage 实例")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/JangyCore && swift test --filter TimelineThumbnailerTests`
Expected: 编译失败 —— `cannot find 'TimelineThumbnailer' in scope`

- [ ] **Step 3: 实现 `TimelineThumbnailer.swift`**

```swift
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// 缩略图档位：离散高度（点），不随缩放连续变（避免缓存爆炸）。
public enum ThumbnailLevel: Int, CaseIterable, Sendable {
    case small = 80
    case medium = 160
    case large = 320

    /// 由当前 px-per-sec 选一档（供 L0 在缩放稳定后选档）。
    public static func level(forPointsPerSecond pps: CGFloat) -> ThumbnailLevel {
        switch pps {
        case ..<24: return .small
        case ..<80: return .medium
        default: return .large
        }
    }
}

/// 时间线缩略图：**从源素材抽帧**（不是从 composition），带缓存。
/// 缓存键 = assetID + 档位 + 时间桶；同一素材在时间线上多处出现时复用。
/// 也提供素材库用的单帧缩略图（原 L0 `ThumbnailLoader` 收口到这里——它 import AVFoundation，
/// 违反公约 §1，L0 不该有）。
///
/// `actor`：缓存与生成串行化，避免 Swift 6 严格并发下的静态可变状态告警。
/// 返回 `CGImage` 而非 `UIImage`——JangyCore 在 macOS 上参与 `swift test`，不能 import UIKit。
public actor TimelineThumbnailer {
    private let resolver: AssetResolver
    private let cache = NSCache<NSString, CGImageBox>()
    /// 时间桶（秒）：同一桶内的抽帧请求复用一帧，避免相邻帧各抽一次。
    private let bucket: TimeInterval = 0.5

    public init(resolver: AssetResolver) {
        self.resolver = resolver
    }

    /// 为某素材元素在给定**输出偏移**处抽帧。`.still` / 越界 → nil。
    /// - Parameter outputOffsets: 元素内输出偏移（秒，相对元素起点）。
    public func frames(asset: AssetItem, clip: PlanClip, level: ThumbnailLevel,
                       outputOffsets: [TimeInterval]) async -> [CGImage?] {
        let url = resolver.resolve(asset)
        let generator = makeGenerator(url: url, level: level)
        var result: [CGImage?] = []
        for offset in outputOffsets {
            guard let sourceTime = clip.sourceTime(forOutputOffset: offset) else {
                result.append(nil); continue
            }
            let key = cacheKey(assetID: asset.id, level: level, time: sourceTime)
            if let hit = cache.object(forKey: key) { result.append(hit.image); continue }
            let image = try? await generator.image(at: CMTime(seconds: sourceTime, preferredTimescale: 600)).image
            if let image { cache.setObject(CGImageBox(image), forKey: key) }
            result.append(image)
        }
        return result
    }

    /// 素材库用的单帧缩略图（视频首帧 / 图片降采样）。
    public func thumbnail(for asset: AssetItem, maxPixel: Int) async -> CGImage? {
        let url = resolver.resolve(asset)
        switch asset.kind {
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            return try? await generator.image(at: .zero).image
        case .image:
            return ImageDownsampler.downsample(url: url, maxPixel: maxPixel)
        default:
            return nil
        }
    }

    private func makeGenerator(url: URL, level: ThumbnailLevel) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: CGFloat(level.rawValue) * 2, height: CGFloat(level.rawValue))
        generator.requestedTimeToleranceBefore = CMTime(seconds: bucket, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: bucket, preferredTimescale: 600)
        return generator
    }

    private func cacheKey(assetID: UUID, level: ThumbnailLevel, time: TimeInterval) -> NSString {
        let bucketIndex = Int((time / bucket).rounded())
        return "\(assetID.uuidString)-\(level.rawValue)-\(bucketIndex)" as NSString
    }

    /// CGImage 不是 class，NSCache 需要 class 值——薄包装。
    private final class CGImageBox { let image: CGImage; init(_ image: CGImage) { self.image = image } }
}
```

> **注意**：上面 `NSCache` 里放的是自定义 `CGImageBox`（class）。若 Swift 6 对 `NSCache<NSString, CGImageBox>` 的 Sendable 有意见，`CGImageBox` 标 `@unchecked Sendable`（它只读不写、不可变）。这是实现细节，编译报错时按提示收敛。

- [ ] **Step 4: 运行确认通过**

Run: `cd Packages/JangyCore && swift test --filter TimelineThumbnailerTests`
Expected: PASS（5 个用例）

- [ ] **Step 5: 删除 `Jangy/ThumbnailLoader.swift`，改 `LibraryView`**

`LibraryView.swift` 第 246 行 `ThumbnailLoader.load(item:resolver:)` 改为用 L3 的通用缩略图入口（`@State private var thumbnail: Image?` 里存 `Image(decorative: cgImage, scale: UIScreen.main.scale)`）：

```swift
.task {
    guard let cg = await TimelineThumbnailer(resolver: resolver).thumbnail(for: item, maxPixel: 240) else { return }
    thumbnail = Image(decorative: cg, scale: UIScreen.main.scale)
}
```

> 每次 `.task` 新建 `TimelineThumbnailer` 会丢缓存——**实现时把 thumbnailer 提到一个共享位置**（`LibraryModel` 持有一个 `let thumbnailer`，或 AppModel 持有并透传），LibraryView / 时间线共用同一实例。**不要每个 cell 新建一个。**

- [ ] **Step 6: App 构建通过**

Run:
```bash
xcodebuild -project Jangy.xcodeproj -scheme Jangy \
  -destination 'generic/platform=iOS Simulator' build -skipMacroValidation
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 7: 全量回归 + 提交**

Run: `cd Packages/JangyCore && swift test` → 325 + 5 = 330 全绿

```bash
git add Packages/JangyCore/Sources/JangyCore/TimelineThumbnailer.swift \
        Packages/JangyCore/Tests/JangyCoreTests/TimelineThumbnailerTests.swift \
        Jangy/LibraryView.swift Jangy/LibraryModel.swift
git rm Jangy/ThumbnailLoader.swift
git commit -m "Core/App: L3 TimelineThumbnailer（源素材抽帧 + 缓存），ThumbnailLoader 从 L0 收口"
```

---

## Task 6: 分屏布局——`ClipTransform` 模型 + 引擎映射（左右分屏）

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/Plan/ClipTransform.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/EditPlan.swift`（`PlanClip` 加 `transform` 字段 + 编解码）
- Modify: `Packages/JangyCore/Sources/JangyCore/Features/Video/VideoFeature.swift`（transform 校验）
- Modify: `Packages/JangyCore/Sources/JangyCore/Features/Video/VideoEngine.swift`（叠加轨应用 transform）
- Modify: `Packages/JangyCore/Sources/JangyCore/EngineBridge.swift`（主轨应用 transform）
- Test: `Packages/JangyCore/Tests/JangyCoreTests/ClipTransformTests.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/MultiTrackExportEndToEndTests.swift`（加分屏 e2e）

**设计要点：** 见 D9。`ClipTransform` 是 L2 纯值类型（不 import Kadr）；`nil` = 全屏。Kadr 的 `scale` 是**均匀**缩放，所以「半屏」= 整体缩到 0.5。

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import JangyCore

final class ClipTransformTests: XCTestCase {

    func testFullScreenIsIdentityDefaults() {
        XCTAssertEqual(ClipTransform.fullScreen, ClipTransform())
        XCTAssertEqual(ClipTransform.fullScreen.scale, 1)
        XCTAssertEqual(ClipTransform.fullScreen.centerX, 0.5)
    }

    func testLeftRightHalfPresetsAreMirrored() {
        XCTAssertEqual(ClipTransform.leftHalf.scale, 0.5)
        XCTAssertEqual(ClipTransform.rightHalf.scale, 0.5)
        XCTAssertEqual(ClipTransform.leftHalf.centerX + ClipTransform.rightHalf.centerX, 1.0, accuracy: 0.0001)
        XCTAssertEqual(ClipTransform.leftHalf.centerY, ClipTransform.rightHalf.centerY)
    }

    func testClipRoundTripsWithTransform() throws {
        var clip = PlanClip(assetID: UUID(), source: .video(0...3))
        clip.transform = .rightHalf
        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(PlanClip.self, from: data)
        XCTAssertEqual(decoded.transform, .rightHalf)
    }

    func testClipWithoutTransformDecodesAsNil() throws {
        // 向后兼容：旧 v4 JSON 没有 transform 字段 → nil（全屏），不报错
        let json = #"{"assetID":"11111111-1111-1111-1111-111111111111","source":{"type":"video","range":[0,3]}}"#.data(using: .utf8)!
        let clip = try JSONDecoder().decode(PlanClip.self, from: json)
        XCTAssertNil(clip.transform)
    }

    func testValidateRejectsOutOfRangeTransform() {
        let asset = AssetItem(kind: .video, fileName: "v.mp4", duration: 10)
        var clip = PlanClip(assetID: asset.id, source: .video(0...3))
        clip.transform = ClipTransform(centerX: 1.5, centerY: 0.5, scale: 0, opacity: 2)
        let track = PlanTrack(kind: .video, placement: .chained,
                              elements: [PlanElement(content: .content(TrackPayload(clip)))])
        let issues = VideoFeature.validate(
            track: track,
            context: TrackValidationContext(assets: [asset], mainTrackEnd: 3, tracks: [track]))
        XCTAssertTrue(issues.contains { $0.message.contains("布局中心") })
        XCTAssertTrue(issues.contains { $0.message.contains("缩放必须为正") })
        XCTAssertTrue(issues.contains { $0.message.contains("不透明度") })
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/JangyCore && swift test --filter ClipTransformTests`
Expected: 编译失败 —— `cannot find 'ClipTransform' in scope`

- [ ] **Step 3: 实现 `Plan/ClipTransform.swift`**

```swift
import Foundation

/// 元素在成片画布上的布局变换（归一化坐标）。元素 `transform == nil` 表示全屏（恒等）。
/// 与 Kadr `Transform` 语义对齐但独立定义——L2 不能 import Kadr（公约 §1）。
///
/// **Kadr 的 `scale` 是均匀缩放**（`Double`，非 `CGSize`），故「半屏」= 整体缩到 0.5
/// （宽高各半、垂直居中）——呈现为「两块半尺寸画面左右并排 + 上下黑边」，
/// 不是边到边的裁切式分屏。旋转 / 锚点留 backlog（Kadr 支持，本期不用）。
public struct ClipTransform: Codable, Equatable, Sendable {
    /// 画布上的归一化中心（0...1，原点左上）。
    public var centerX: Double
    public var centerY: Double
    /// 均匀缩放（1 = 铺满画布）。
    public var scale: Double
    /// 不透明度（0...1）。
    public var opacity: Double

    public init(centerX: Double = 0.5, centerY: Double = 0.5,
                scale: Double = 1, opacity: Double = 1) {
        self.centerX = centerX
        self.centerY = centerY
        self.scale = scale
        self.opacity = opacity
    }

    public static let fullScreen = ClipTransform()
    /// 左半屏：缩到 0.5、中心在画布左侧 1/4。
    public static let leftHalf = ClipTransform(centerX: 0.25, centerY: 0.5, scale: 0.5)
    /// 右半屏。
    public static let rightHalf = ClipTransform(centerX: 0.75, centerY: 0.5, scale: 0.5)
}
```

- [ ] **Step 4: `PlanClip` 加字段**

`EditPlan.swift` 的 `PlanClip`：加 `public var transform: ClipTransform?`，`init` 加 `transform: ClipTransform? = nil`，`CodingKeys` 加 `transform`，`init(from:)` 加：

```swift
        transform = try container.decodeIfPresent(ClipTransform.self, forKey: .transform)
```

（`encode` 是合成的——`CodingKeys` 加了就自动写；`type` 判别字段仍由 `TrackPayload` box 注入，不在这里写。）

- [ ] **Step 5: `VideoFeature.validate` 加 transform 校验**

在 `guard case .content(let payload) = element.content, let clip = payload.value as? PlanClip else { continue }` 之后加：

```swift
            if let transform = clip.transform {
                if !(0...1).contains(transform.centerX) || !(0...1).contains(transform.centerY) {
                    issues.append(ValidationIssue(path: "\(path).transform", elementID: element.id,
                                                  message: "布局中心必须在 0–1 之间"))
                }
                if transform.scale <= 0 {
                    issues.append(ValidationIssue(path: "\(path).transform", elementID: element.id,
                                                  message: "布局缩放必须为正"))
                }
                if !(0...1).contains(transform.opacity) {
                    issues.append(ValidationIssue(path: "\(path).transform", elementID: element.id,
                                                  message: "布局不透明度必须在 0–1 之间"))
                }
            }
```

- [ ] **Step 6: L3 应用 transform**

在 `EngineBridge.swift` 加一个内部映射（L3，可 import Kadr）：

```swift
extension ClipTransform {
    /// → Kadr 变换。中心是归一化坐标（Kadr `Position.normalized`，原点左上），scale 均匀。
    var kadrTransform: Kadr.Transform {
        Kadr.Transform(center: .normalized(x: centerX, y: centerY), scale: scale)
    }
}
```

`VideoEngine.makeParallelTracks`：两个分支各自在 `.trimmed` / 速度之后应用（`any Kadr.Clip` 上不能调 `.transform`，要在具体类型上调）：

```swift
                case .still(let duration):
                    var imageClip = Kadr.ImageClip(image, duration: duration / planClip.speed.rate)
                    if let t = planClip.transform {
                        imageClip = imageClip.transform(t.kadrTransform).opacity(t.opacity)
                    }
                    clip = imageClip

                case .video(let range):
                    var videoClip = Kadr.VideoClip(url: url).trimmed(to: range)
                    if planClip.speed.rate != 1.0 { videoClip = videoClip.speed(.flat(planClip.speed.rate)) }
                    if let t = planClip.transform {
                        videoClip = videoClip.transform(t.kadrTransform).opacity(t.opacity)
                    }
                    clip = videoClip
```

`EngineBridge.makeComposition` 的主轨分支同样处理（`.video` / `.still` 两支，在 `.trimmed` / 速度之后、进 `elements` 之前应用 `clip.transform`）。**gap 分支不加**（gap 恒为全幅黑）。

- [ ] **Step 7: 加分屏 e2e**

`MultiTrackExportEndToEndTests` 加一条：主轨 clip1（红）设 `leftHalf`、叠加轨 clip2（绿）设 `rightHalf`，导出后抽帧断言**左半区偏红、右半区偏绿**（复用该文件已有的 `meanColor(asset:at:in:)`，左半矩形 `CGRect(x:0.05,y:0.4,width:0.4,height:0.2)`，右半 `x:0.55`）。

```swift
    func testLeftRightSplitRendersBothHalves() async throws {
        let a = videoAsset("clip1.mp4")   // 红
        let b = videoAsset("clip2.mp4")   // 绿
        var mainClip = PlanClip(assetID: a.id, source: .video(0...3))
        mainClip.transform = .leftHalf
        var overlayClip = PlanClip(assetID: b.id, source: .video(0...3))
        overlayClip.transform = .rightHalf
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(mainClip)))])
        let overlay = PlanTrack(kind: .video, placement: .absolute, elements: [
            PlanElement(at: 0, content: .content(TrackPayload(overlayClip)))])
        let plan = EditPlan(assets: [a, b], tracks: [primary, overlay], primaryTrackID: primary.id)

        let out = try await export(plan, to: "split.mp4")
        let asset = AVURLAsset(url: out)
        let left = try meanColor(asset, at: 1.0, in: CGRect(x: 0.05, y: 0.4, width: 0.4, height: 0.2))
        let right = try meanColor(asset, at: 1.0, in: CGRect(x: 0.55, y: 0.4, width: 0.4, height: 0.2))
        XCTAssertGreaterThan(left.red, left.green, "左半应是主轨的红")
        XCTAssertGreaterThan(right.green, right.red, "右半应是叠加轨的绿")
    }
```

> 若「半屏」的几何与预期不符（如缩放锚点让画面跑偏），**先读 Kadr `Transform.resolved` 的注释核对 center/anchor 语义**，再调预设值——**不要改 Kadr**。若确为 fork 侧问题，记入 backlog 并登记降级（Task 11）。

- [ ] **Step 8: 运行确认通过**

Run: `cd Packages/JangyCore && swift test --filter ClipTransformTests && swift test --filter MultiTrackExportEndToEndTests`
Expected: PASS（ClipTransform 5 + 分屏 e2e 1）

- [ ] **Step 9: 全量回归 + 提交**

Run: `cd Packages/JangyCore && swift test` → 330 + 6 = 336 全绿

```bash
git add Packages/JangyCore/Sources/JangyCore/Plan/ClipTransform.swift \
        Packages/JangyCore/Sources/JangyCore/EditPlan.swift \
        Packages/JangyCore/Sources/JangyCore/Features/Video/VideoFeature.swift \
        Packages/JangyCore/Sources/JangyCore/Features/Video/VideoEngine.swift \
        Packages/JangyCore/Sources/JangyCore/EngineBridge.swift \
        Packages/JangyCore/Tests/JangyCoreTests/ClipTransformTests.swift \
        Packages/JangyCore/Tests/JangyCoreTests/MultiTrackExportEndToEndTests.swift
git commit -m "Core: 元素布局 transform（ClipTransform + 引擎映射 + 左右分屏预设）"
```

---

## Task 7: L0 时间线容器——可拖分界 + 标尺 + 播放头 + 偏移驱动滚动/擦洗

**Files:**
- Modify: `Jangy/EditorView.swift`（分界布局）
- Modify: `Jangy/AppModel.swift`（持有 `viewport`、同步 contentDuration、擦洗 seek）
- Rewrite: `Jangy/TimelineView.swift`
- Create: `Jangy/RulerView.swift`
- Create: `Jangy/PlayheadOverlay.swift`

> **本任务开始进入红色区间**：`TimelineView.swift` 被整体替换。**本步结束时必须 `xcodebuild` 通过。** 旧的固定宽度 / confirmationDialog 实现连同它的 变速 / 转场 / 删除 入口**在本步暂时移除**（Task 10 的选中操作条会以新形式恢复 变速 / 转场 / 删除）。

- [ ] **Step 1: `AppModel` 持有视口状态并接线**

```swift
    /// 时间线视口状态（高频，不进 EditStore）。App 侧唯一持有者。
    let viewport = TimelineViewportState()
```

`afterPlanMutation()` 里同步 `contentDuration`：

```swift
    private func afterPlanMutation() {
        lastIssues = nil
        viewport.contentDuration = store.plan.renderedDuration
        player.rebuild()
        scheduleAutosave()
    }
```

`init` 末尾也同步一次初值。新增擦洗入口（节流 + 暂停）：

```swift
    /// 时间线擦洗：落播放头 + seek 播放器（节流）+ 暂停（剪映同款：擦洗即暂停）。
    private var lastSeek = Date.distantPast
    func scrubTo(_ time: TimeInterval) {
        viewport.setPlayhead(time)
        player.pauseForScrub()
        guard Date().timeIntervalSince(lastSeek) > 0.05 else { return }
        lastSeek = Date()
        player.seek(to: time)
    }
```

`PlayerController` 补两个方法（`pauseForScrub()` = `wantsPlaying = false; applyDesired()`；`seek(to:)` = `player?.seek(to: CMTime(seconds:time, preferredTimescale:600))`，并把 `currentTime` 同步过去）。播放推进 → 视口播放头：在 `PlayerController` 的轮询里回调，或在 L0 用 `.onChange(of: model.player.currentTime)`（**仅非擦洗态同步**）。选后者，简单。

- [ ] **Step 2: `EditorView` 分界布局**

预览与时间线之间加可拖横杠 + 三档吸附（预览最小高 / 时间线半屏 / 时间线近全屏）。用一个 `@State private var timelineHeight: CGFloat`（或 fraction），横杠的 `DragGesture` 改它，抬手吸附到最近档：

```swift
    @State private var timelineHeight: CGFloat = 230
    private let snapHeights: (min: CGFloat, half: CGFloat, full: CGFloat) = (180, 360, 560)
    // 拖拽 onChanged 里 timelineHeight = clamp(base - translation.height, min, full)
    // onEnded 里吸附到最近的 snap 档
```

> 具体档位数值按设备屏幕高度比例算（预览最小高 = 屏幕高 − 时间线近全屏；半屏 = 0.5×屏幕高），**别写死像素**——用 `GeometryReader` 拿屏幕高换算。三档吸附抽成一个纯函数（`snapHeight(_:)`）便于日后测。

- [ ] **Step 3: 重写 `TimelineView.swift`（容器骨架）**

```swift
import SwiftUI
import JangyCore

/// 时间线：可拖分界下方的多轨视图。水平位置由 `viewport.scrollOffset` 驱动（非 ScrollView，
/// 见计划 D2）——单指横向拖 = 滚动 = 擦洗（同一手势）。
struct TimelineView: View {
    let model: AppModel
    var height: CGFloat
    var onAdd: () -> Void

    private var viewport: TimelineViewportState { model.viewport }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 内容层：整体按 -scrollOffset 平移（标尺 + 车道都在这里）
                VStack(spacing: 0) {
                    RulerView(viewport: viewport)
                        .frame(height: 24)
                    ScrollView(.vertical) {
                        VStack(spacing: 2) {
                            ForEach(model.store.plan.tracks) { track in
                                // Task 8 换成 TrackLaneView；本步先放占位
                                Color(.secondarySystemFill)
                                    .frame(width: contentWidth, height: 56)
                            }
                        }
                        .padding(.leading, geo.size.width / 2)   // 半视口留白，让 t=0 居中
                        .padding(.trailing, geo.size.width / 2)
                    }
                }
                .offset(x: -viewport.scrollOffset)

                // 播放头：固定居中
                PlayheadOverlay(time: viewport.playheadTime)
                    .frame(width: 2)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: geo.size.width))
            .onAppear { viewport.viewportWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, w in viewport.viewportWidth = w }
        }
    }

    private var contentWidth: CGFloat {
        CGFloat(viewport.contentDuration) * viewport.pointsPerSecond
    }

    /// 单指横向拖 = 滚动 = 擦洗。位移增量喂给 viewport，再 seek 播放器。
    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let dx = value.translation.width - lastTranslation
                lastTranslation = value.translation.width
                viewport.scrub(by: dx)
                model.scrubTo(viewport.playheadTime)
            }
            .onEnded { _ in lastTranslation = 0 }
    }
    @State private var lastTranslation: CGFloat = 0
}
```

`RulerView`：按 px/s 选刻度间隔（如 1s / 2s / 5s / 10s），画竖线 + 时间标签；内容坐标与车道一致（`viewport.x(forTime:)`）。

`PlayheadOverlay`：2pt 竖线 + 顶部时间气泡（`Text(格式化时间)`），**固定视口中央**（不随 offset 动）。

- [ ] **Step 4: App 构建通过**

Run:
```bash
xcodebuild -project Jangy.xcodeproj -scheme Jangy \
  -destination 'generic/platform=iOS Simulator' build -skipMacroValidation
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: 模拟器手动验证（滚动 = 擦洗）**

Run 起来，往时间线里放几段素材，单指左右拖：内容平移、播放头恒居中、预览跟着 seek；松手不弹回。**记录通过。**

- [ ] **Step 6: 提交**

```bash
git add Jangy/EditorView.swift Jangy/AppModel.swift Jangy/TimelineView.swift \
        Jangy/RulerView.swift Jangy/PlayheadOverlay.swift
git commit -m "App: 时间线容器——可拖分界 + 标尺 + 固定居中播放头 + 偏移驱动滚动擦洗"
```

---

## Task 8: L0 轨道车道 + 注册表 + 轨道头 + 缩略图

**Files:**
- Create: `Jangy/TrackLaneRegistry.swift`
- Create: `Jangy/TrackLaneView.swift`
- Create: `Jangy/TrackCap.swift`
- Create: `Jangy/Features/Video/VideoLane.swift`
- Create: `Jangy/Features/Caption/CaptionLane.swift`
- Modify: `Jangy/TimelineView.swift`（占位车道 → `TrackLaneView`）

- [ ] **Step 1: 建 L0 注册表（不 switch kind）**

```swift
import SwiftUI
import JangyCore

/// 车道呈现上下文：呈现器只读这里的东西（plan / 视口 / 解析器 / 缩略图器）。
struct LaneContext {
    let plan: EditPlan
    let viewport: TimelineViewportState
    let resolver: AssetResolver
    let thumbnailer: TimelineThumbnailer
}

/// 一类轨的 L0 呈现片（与 L2 `Features/<Name>/<Name>Feature.swift`、L3 `<Name>Engine.swift` 同 kind 的三片之一）。
protocol TrackLaneProvider {
    static var kind: TrackKind { get }
    @MainActor static func makeLane(track: PlanTrack, context: LaneContext) -> AnyView
}

/// 车道呈现器注册表 —— L0 侧唯一注册点。加一类轨 = 这里加一行 + 新增 `Features/<Name>/<Name>Lane.swift`。
/// **TrackLaneView 不得 switch 具体轨类型**（公约 §1）；不认识 kind 时回落通用车道。
enum TrackLaneRegistry {
    static let providers: [any TrackLaneProvider.Type] = [
        VideoLaneProvider.self,
        CaptionLaneProvider.self,
    ]

    static func provider(for kind: TrackKind) -> (any TrackLaneProvider.Type)? {
        providers.first { $0.kind == kind }
    }
}
```

`TrackLaneView`：

```swift
struct TrackLaneView: View {
    let track: PlanTrack
    let context: LaneContext

    var body: some View {
        if let provider = TrackLaneRegistry.provider(for: track.kind) {
            provider.makeLane(track: track, context: context)
        } else {
            GenericLane(track: track)   // 未知 kind：只按时长画灰条，不崩、不 switch
        }
    }
}
```

- [ ] **Step 2: `VideoLane`（缩略图条）**

每个元素按其输出时长 × pps 定宽，铺缩略图。**只渲可见区**：用 `context.viewport.visibleTimeRange` 与元素输出区间求交，只对相交部分请求帧；`level = ThumbnailLevel.level(forPointsPerSecond:)`；`.task(id:)` 里请求（id 用「元素 id + 档位 + 可见桶范围」，缩放变化时不重算——用 `.task(id: level)` 让档位变才重取）。

```swift
enum VideoLaneProvider: TrackLaneProvider {
    static let kind = TrackKind.video

    @MainActor static func makeLane(track: PlanTrack, context: LaneContext) -> AnyView {
        AnyView(VideoLane(track: track, context: context))
    }
}

struct VideoLane: View {
    let track: PlanTrack
    let context: LaneContext
    @State private var frames: [UUID: [Image?]] = [:]   // elementID → 帧

    var body: some View {
        // 元素按输出起点 / 时长排布；gap 画黑条；content 铺缩略图
        // 宽度 = duration * pps；x = x(forTime: outputStart)
    }
}
```

> 缩略图请求的**具体参数**（每元素抽几帧 = 元素宽 / 档位宽）与可见区裁剪逻辑，实现时按 `visibleTimeRange` 与元素输出区间（`track.elementOutputStarts()`）求交后展开。**缩放期间不重算**：用 `.task(id: level)` 只在档位变化时重取，手势期间用旧帧拉伸顶替。

- [ ] **Step 3: `CaptionLane`（cue 条 + 文本）**

cue 元素按 `at` + duration 定位，画圆角条 + 文本（`CaptionCuePayload.text`）。

- [ ] **Step 4: `TrackCap`（轨道头）**

图标（按 kind 给图标——**这里允许按 kind 取图标吗？** 允许：图标是纯呈现映射，不是「认识特性模块的业务」；但仍建议走注册表——把图标放进 `TrackLaneProvider` 的一个静态属性 `static var icon: String`，彻底不 switch）+ 轨号 + 静音/隐藏按钮。

- 横向钉在视口左缘：它是偏移层**之外**的兄弟视图（在 `TimelineView` 里画在 `ZStack` 最上层、不参与 `-scrollOffset` 平移）。
- 纵向跟轨走：与车道同一 `VStack` 行高对齐——最简做法是每行 `ZStack(alignment: .leading) { TrackLaneView; TrackCap }`，cap 不随行内 offset 动。
- 无实色底，文字带阴影。

- [ ] **Step 5: 接进 `TimelineView`**

把 Task 7 的占位 `Color(.secondarySystemFill)` 换成 `TrackLaneView` + `TrackCap` 的行。

- [ ] **Step 6: App 构建通过 + 手动验证**

Run: `xcodebuild ... -skipMacroValidation` → `BUILD SUCCEEDED`。
手动：主轨显示缩略图条；字幕轨显示 cue；轨道头钉在左缘、纵向跟着轨道；滚动时缩略图跟着走；缩略图只渲可见区（滚到远处不卡）。

- [ ] **Step 7: 提交**

```bash
git add Jangy/TrackLaneRegistry.swift Jangy/TrackLaneView.swift Jangy/TrackCap.swift \
        Jangy/Features Jangy/TimelineView.swift
git commit -m "App: 轨道车道注册表 + 轨道头（钉左无底）+ 视频缩略图条 / 字幕 cue 条"
```

---

## Task 9: L0 双指缩放 + ZoomBadge

**Files:**
- Create: `Jangy/ZoomBadge.swift`
- Modify: `Jangy/TimelineView.swift`（加 `MagnifyGesture`）

- [ ] **Step 1: 加缩放手势**

```swift
    .gesture(
        MagnifyGesture()
            .onChanged { value in
                let factor = value.magnification / lastMagnification
                lastMagnification = value.magnification
                viewport.zoom(by: factor, anchorX: value.startAnchor.point.x)
            }
            .onEnded { _ in lastMagnification = 1 }
    )
    @State private var lastMagnification: CGFloat = 1
```

> `MagnifyGesture.Value.startAnchor` 给的是 `UnitPoint`——乘视口宽得 `anchorX`。若 API 形状不符，用 `value.startLocation` 兜底。**锚点 = 双指中心**（spec）。

- [ ] **Step 2: `ZoomBadge`**

右下角显示当前档位（如 `"1.0x"` / `"\(Int(pps)) px/s"`），缩放时淡入、停止 1s 后淡出。

- [ ] **Step 3: App 构建通过 + 手动验证**

双指捏合/张开：以双指中心为锚缩放；播放头下的时间基本不动；档位角标出现。

- [ ] **Step 4: 提交**

```bash
git add Jangy/ZoomBadge.swift Jangy/TimelineView.swift
git commit -m "App: 双指缩放（锚点=双指中心）+ 缩放档位角标"
```

---

## Task 10: L0 选中 + trim + 长按移动 + 轨道重排 + 布局预设

**Files:**
- Modify: `Jangy/TimelineView.swift`
- Modify: `Jangy/EditorView.swift`（选中态操作条：恢复 变速 / 转场 / 删除）

- [ ] **Step 1: 选中态**

`@State private var selection: UUID?`（选中元素 id）。点元素 → 选中（出 trim 手柄 + 选中边框）；点空白 → 取消。**选中是纯 L0 局部态，不进 plan。**

- [ ] **Step 2: trim（拖元素左右边缘手柄）**

手柄的 `DragGesture.onChanged` 里构造 / 更新 `DragSession(kind: .trim(elementID:edge:))` 的值（只改 `@State`），**元素的视觉宽度用 `session.translation` 临时伸缩**（局部 SwiftUI，plan 不动）；`.onEnded` 里 `session.resolve(in: DragContext(...))` → `edit?.apply(to: model.store)` → `model.afterPlanMutation()`（或包一个 `model.applyTimelineEdit(_:)`）。

```swift
    @State private var drag: DragSession?
    // onChanged: drag = (drag ?? .init(kind: .trim(...))).translated(to: value.translation)
    // onEnded: if let edit = drag?.resolve(in: dragContext) { model.applyTimelineEdit(edit) }; drag = nil
```

`dragContext` 由 `model.store.plan` + `viewport` + `SnapEngine.snapPoints` + 行高构造。

- [ ] **Step 3: 长按移动**

元素上 `.onLongPressGesture` 成功 → 开 `GestureRouter.liftSession(for: .element(id:), plan:)`；浮起（放大 + 阴影），随后 `DragGesture` 更新 `translation`；抬手 `resolve` → `apply`。**拖动期间 plan 不动**，元素跟随手指（局部 offset）。

- [ ] **Step 4: 轨道重排**

`TrackCap` 上长按 → `GestureRouter.liftSession(for: .trackCap(...))` → 上下拖 → 抬手 `resolve` → `apply`。

- [ ] **Step 5: 选中态操作条（恢复 变速 / 转场 / 删除）**

`EditorView` 顶部操作条在 `selection != nil` 时显示「变速 / 转场 / 删除」三个按钮，动作走 `TimelineEdit` 或直接 `model.edit { plan.updatePrimaryClip(...) }`。删除走 `TrackOperations.removeElement`（**保持「删除 = 留 gap」语义**，公约「删除语义」节）。

- [ ] **Step 6: 布局预设菜单（全屏 / 左半屏 / 右半屏）**

选中元素的操作条再加一个布局菜单，三个选项把元素的 `transform` 设为 `nil`（全屏）/ `.leftHalf` / `.rightHalf`（Task 6 的类型）。走一次 `model.edit`：

```swift
    private func setLayout(_ preset: ClipTransform?) {
        guard let id = selection else { return }
        model.edit { plan in
            for ti in plan.tracks.indices {
                guard let ei = plan.tracks[ti].elements.firstIndex(where: { $0.id == id }),
                      case .content(let payload) = plan.tracks[ti].elements[ei].content,
                      var clip = payload.value as? PlanClip else { continue }
                clip.transform = preset
                plan.tracks[ti].elements[ei].content = .content(TrackPayload(clip))
                return
            }
        }
    }
```

**「左右分屏」= 主轨元素设「左半屏」+ 叠加轨元素设「右半屏」**（两次点选；不做一步到位的魔法动作）。做分屏需要工程里已有叠加轨——用 Agent 建一条，或 CLI 播种。

- [ ] **Step 7: App 构建通过 + 手动验证（完整手势地图 + 分屏）**

逐条过 spec 的「手势地图」表：单指横拖=擦洗、单指竖拖=滚轨、双指缩放、点选、长按拖动移动/换轨、拖手柄 trim、长按轨道头重排。**并验证高频分界**：拖动期间预览不重建、松手后撤销栈只 +1（连点撤销一次回到拖动前）。**再验分屏**：主轨设左半屏 + 叠加轨设右半屏 → **预览**里应看到左右两块（若预览不显示 transform，登记降级，见 Task 11）。

- [ ] **Step 8: 提交**

```bash
git add Jangy/TimelineView.swift Jangy/EditorView.swift
git commit -m "App: 选中 + trim + 长按移动 / 换轨 + 轨道重排 + 布局预设（左右分屏）"
```

---

## Task 11: 公约修订 + 文档同步 + 模拟器手动验证清单

**Files:**
- Modify: `docs/architecture-covenant.md`
- Modify: `docs/superpowers/specs/2026-10-15-timeline-tracks-design.md`
- Modify: `docs/roadmap-path-a.md`
- Modify: `AGENTS.md`
- Create: `docs/archive/timeline-ui-manual-checklist.md`（手动验证清单）

- [ ] **Step 1: 公约修订（逐条）**

1. **§2.2 播放状态隔离**：改为——时间线 UI 的播放头由 **L1 `TimelineViewportState`** 驱动（高频隔离在时间线子树内），仍不进 `EditStore`、不由 `PlayerController` 全局广播；字幕预览叠加层仍单独订阅 `PlayerController.currentTime`。（原文「时间线 UI 不订阅播放头」被本期取代。）
2. **§1 现有代码落位表**：`待建 L1 Interaction 层` → 已建（`JangyCore/Interaction`：`TimelineViewportState` / `SnapEngine` / `DragSession` / `GestureRouter` / `TimelineEdit`）；L3 补 `TimelineThumbnailer`（`ThumbnailLoader` 从 L0 收口）；L0 补轨道车道注册点（`Jangy/TrackLaneRegistry.swift` + `Features/<Name>/<Name>Lane.swift`）。**说明 L1 是纯 Swift（不 import SwiftUI）**。
3. **§3.1 片段级属性内禀化**：补 `PlanClip.transform`（`ClipTransform`）作为「跟着片段走」的布局属性一例（与变速同款内禀化，分割/移动随节点拷贝）。
4. **§6.4 降级登记表**：补两行——①「拖动期间缩略图：用当前档位拉伸顶替、不重算（手势结束才重算）/ 导出不受影响 / 交互流畅优先」；②「时间线缩略图：从源素材抽帧、档位离散，不反映变速 / 转场 / 叠加 / 字幕 / 删除留下的 gap 内实际画面 / 仅用于识别素材」。**若 Step 7 实测发现预览不显示 `transform`**，再加一行「元素布局变换：预览不显示 / 导出正常」。
5. **§6.1 / §6.5**：无需改（本计划正是它们的落地）；如 §6.5 里「拖动类手势」措辞需补「时间线拖动」，一并补。

- [ ] **Step 2: 回填 spec**

- 「分层与组件」节：`L1 JangyCore/Interaction` 的组件名与本计划对齐（`DragSession` / `GestureRouter` / `SnapEngine` / `TimelineViewportState`）。
- 「轨道头」措辞：把「ScrollView 的 sticky 层」改成「偏移层之外的钉左兄弟视图」（对齐实现，见 D2）。
- 「引擎映射 → 多画面定位范围」：本期落地**左右分屏**（`PlanClip.transform` + UI 预设），自由拖拽定位仍留 backlog；说明「半屏」是均匀缩放 0.5（Kadr 能力边界，非边到边裁切）。
- 「待验证」节：叠加轨预览结论（Task 0 已完成回填，此处只核对）。

- [ ] **Step 3: roadmap**

「已完成」加一条（阶段②），「待办」删掉阶段②条目。格式照阶段①那条。

- [ ] **Step 4: 手动验证清单**

`docs/archive/timeline-ui-manual-checklist.md`：逐条列出 spec「验收」节的模拟器手动项——双指缩放、擦洗、长按拖动、轨道重排、分界拖拽与吸附、缩略图滚动流畅度、**左右分屏（预览里左右两块）**——每条带「步骤 / 期望 / 结果」空位，供人工勾选。

- [ ] **Step 5: 同步 AGENTS.md 测试数**

```bash
cd Packages/JangyCore && swift test 2>&1 | tail -5
```
取实际数更新 AGENTS.md 的「295 个」。同时把 AGENTS.md 的常用命令里 `xcodebuild` 补 `-skipMacroValidation`（若尚未补）。

- [ ] **Step 6: 全量验证**

```bash
cd Packages/JangyCore && swift test
xcodebuild -project Jangy.xcodeproj -scheme Jangy -destination 'generic/platform=iOS Simulator' build -skipMacroValidation
```
Expected: 测试全绿；`BUILD SUCCEEDED`

- [ ] **Step 7: 提交**

```bash
git add docs AGENTS.md
git commit -m "docs: 时间线多轨阶段②收口——公约修订、spec 回填、手动验证清单、测试数同步"
```

---

## 自审记录

**Spec 覆盖检查：**

| Spec 条目 | 对应任务 |
|---|---|
| L1 Interaction 层（TimelineViewportState / GestureRouter / DragSession / SnapEngine） | Task 2, 3, 4 |
| 布局：可拖分界 + 三档吸附 | Task 7 |
| 轨道头（钉左无底图标 + 静音/隐藏） | Task 8 |
| 标尺与播放头（固定居中，滚动即擦洗） | Task 7 |
| 双指捏合缩放（锚点=双指中心） | Task 9 |
| 缩略图（TimelineThumbnailer 从源素材抽帧、档位离散、只渲可见区） | Task 1, 5, 8 |
| ThumbnailLoader 从 L0 收口 | Task 5 |
| 选中与 trim、长按拖动（移动/换轨）、长按轨道头重排 | Task 4, 10 |
| 多画面定位（本期只做左右分屏预设） | Task 6, 10 |
| TrackLaneView 注册表驱动（不 switch 具体轨类型） | Task 8 |
| 高频/低频分界（拖动期间 plan 不动、抬手一次 apply、撤销 +1） | Task 4, 10（验收 Step） |
| 待验证：叠加轨预览实机表现 | Task 0（✅ 已确认可见） |
| 公约修订清单（§2.2 / §1 / §3.1 / §6.4） | Task 11 |
| 验收：App 构建 + 模拟器手动验证清单 | 各 UI 任务的验收 Step + Task 11 |

**范围外（有意排除，见「范围边界」）：** 多画面**自由拖拽定位**（拖拽框/手柄/吸附，独立一块）、除左右分屏外的预设布局（画中画右下等）、App 侧新建轨道入口、字幕文本编辑 UI。

**待决 / 需人决策：**
1. **左右分屏的几何**：Kadr `scale` 是均匀缩放，故「半屏」= 整体缩到 0.5（两块半尺寸画面并排 + 上下黑边），不是边到边裁切。若产品上要「边到边」的分屏，需要 Kadr 侧支持非均匀缩放或裁切——单开一个 fork 改动 + 上游 issue。
2. **擦洗是否暂停播放**：本计划取剪映同款「擦洗即暂停」（D3）。若要求「边播边擦洗」，需要处理播放推进与拖拽的双向同步。

**执行流程约定：** 每个任务执行时走「实现 → spec 审查 → 代码质量审查」，两轮审查各派一个 subagent（见 memory `task-workflow-implement-two-reviews`）。审查重点：L1 的 `resolve` 边界（零位移 / 越界 / 吸附）、L0 是否在拖动期间碰了 plan（高频分界）、`TrackLaneView` 是否偷 switch 了 kind。

**验证基线：** 起点 295 测试全绿；本计划新增 Task 1（4）+ Task 2（7）+ Task 3（4）+ Task 4（15）+ Task 5（5）+ Task 6（6）= 41 个用例 → 预期 336。
