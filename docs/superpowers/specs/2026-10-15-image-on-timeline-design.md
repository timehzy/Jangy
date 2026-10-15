# 图片上轨设计 spec

日期：2026-10-15
状态：已确认（brainstorm 收口）
范围：Spec ②（承 Spec ①「多项目+素材库」）。仅图片上轨——音频维持「整体后置」决策，不在本期。

## 背景

Spec ① 落地后，素材库已能入库图片，但两处入口刻意关着（素材库图片 tab 无 ＋、图片预览页无添加按钮），时间线只接受视频。本 spec 让图片素材上轨，与视频混排，参与转场/变速/字幕/导出全链路。图片的剪辑模型是「无源区间素材」（公约 §3.4）：clip 无 source range，只有 duration。

## 决策汇总（brainstorm 已拍板）

1. **引擎路线 = 原生 ImageClip，不物化**：Kadr 原生支持 `ImageClip(PlatformImage, duration:)`，`CompositionBuilder.insertImageClip` 内部已把图片按 preset 分辨率+帧率编码成临时 mp4、插入后即删。我们层零物化、零缓存、零素材库登记表扩展。公约 §5.1 两处措辞随之更新：「写帧能力可移植自 AssetSynthesizer」在 Kadr 1.x 已内建（过时）；「变速 = 改 duration」精化为「变速 = 改输出时长（经倍率，见决策 4）」。
2. **画幅 = Core 预合成 letterbox**：Kadr 的 `ImageEncoder` 把图片拉伸铺满 preset 画幅、不保宽高比（已实测：100×100 方图导出 1080×1920 整帧填充）。在 `EngineBridge` 交给 Kadr 前，先把图片等比 aspect-fit 居中贴到 preset 画幅黑底画布上，消除变形。
3. **模型 = `PlanClip.source` 枚举**：`.video(ClosedRange<TimeInterval>)` / `.still(duration: TimeInterval)`，tagged JSON。替换现有 `range` 字段，不用魔法值。
4. **图片变速 = 存倍率**：`.still(duration)` 存基准时长，`speed` 存倍率，`outputDuration = 基准 / rate`。`set_speed` 幂等、UI 能显示当前档位、与视频同构。
5. **schema 版本 2 → 3**：clip 编码变更后，旧代码读到新 plan 走 §3.5 版本守卫优雅拒载，而非因缺 `range` 解码报错。
6. **全显式 `source:`**：不保留 `range:` 便捷构造，所有调用点（含 12 个测试文件）改为显式 `source:`。

## 引擎路线

- `EngineBridge.makeComposition`：`.video` → 现状 `Kadr.VideoClip(url:).trimmed(to:)`（+speed）；`.still` → `Kadr.ImageClip(uiImage, duration: 基准 / rate)`。
- 混排、转场、预览（`makePlayerItem`）、导出、`FrameSnapshotter` 全部经此单一出口，自动打通——`VideoBuilder` 产 `[any Clip]`，`CompositionBuilder` 按类型分派。
- preset 需在构建 elements 前算出（letterbox 画布尺寸 = `preset.resolution`）。

### StillImagePreparer（新增 L3 小类型）

- 职责：图片文件 → 可直接喂 Kadr 的 `PlatformImage`。
- 步骤：ImageIO 降采样加载（`kCGImageSourceThumbnailMaxPixelSize` = 画布长边，避免全尺寸像素进内存）→ 算 aspect-fit 居中矩形 → 画到画布尺寸（= preset 分辨率）黑底 `CGContext` → 包成 `PlatformImage`。
- 平台：`PlatformImage` iOS=UIImage / macOS=NSImage，用 `#if canImport(UIKit)` 分支；CoreGraphics 部分跨平台共用。
- 变形消除后，Kadr 编码为恒等缩放。

## 模型

```swift
public enum PlanClipSource: Codable, Equatable, Sendable {
    case video(ClosedRange<TimeInterval>)
    case still(duration: TimeInterval)
    // JSON：{"type":"video","range":[0,3]} / {"type":"still","duration":3}
}

public struct PlanClip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var assetID: UUID
    public var source: PlanClipSource   // 替换原 range
    public var speed: SpeedPlan
    public var transitionAfter: PlanTransition?
}
```

- **编码**：`source` tagged（仿 `SpeedPlan`/`PlanTransition`）。
- **解码（向后兼容）**：有 `source` → 用之；无 `source` 但有旧 `range` → `.video(range)`。
- **版本**：`EditPlan.version` 默认值 + `ProjectStore.currentSchemaVersion` 2 → 3。旧 v2 plan 仍可解（2 ≤ 3）。
- **outputDuration**（`TimelineDuration.swift`）：

```swift
extension PlanClip {
    public var sourceLength: TimeInterval {
        switch source {
        case .video(let r): return r.upperBound - r.lowerBound
        case .still(let d): return d
        }
    }
    public var outputDuration: TimeInterval { sourceLength / speed.rate }
}
```

`renderedDuration` 不变（Σ outputDuration − Σ 转场重叠）。

## 校验（EditPlanValidator）

- clips 允许 video / image 素材（现第 53–54 行硬拒非视频，放开）。
- **source 与素材 kind 一致**：`.video` ↔ 素材 kind `.video`、`.still` ↔ 素材 kind `.image`，不一致报 `clips[i].assetID`。
- 视频 range 校验（起点非负 / 区间非空 / 不超素材时长）path 为 `clips[i].source.range`。
- `.still`：`duration > 0`，path `clips[i].source.duration`（区间检查只对 `.video`）。
- 转场检查：**无改动**——已用 `clip.outputDuration`，对 still 自然成立。

## Agent 工具（改 3 个）

- `AddClipTool`：支持图片。`rangeStart`/`rangeEnd` 改可选（仅 video 必填）；新增可选 `duration`（图片用，缺省 3.0）。按文件名扩展名判类型；图片走 `probeImageMetadata` 登记 + 追加 `.still(duration)`。
- `SplitClipTool`：`.still` 分支——`at` 解释为片段内已过时间（0 < at < 基准时长），切成 `.still(at)` + `.still(基准 − at)`，倍率两段都保留。
- `TrimClipTool`：`.still` 分支——`rangeEnd − rangeStart` 作为新基准时长。
- `SetSpeedTool` / `SetTransitionTool` / `MoveClipTool` / `RemoveClipTool` / `ListAssetsTool` / `GetPlanTool` / `SnapshotTool`：**无改动**（倍率对 still 统一；快照/转场天然可用）。

## 封面

`CoverGenerator` 按首个 clip 素材的 kind 分支：`.video` 现状 `AVAssetImageGenerator`；`.image` → 解码 + 降采样 + JPEG（复用 ImageIO 降采样路径）。空时间线清旧封面不变。

## UI（打开 Spec ① 刻意关着的两处）

- `AssetPreviewView`：`canAdd` 放开图片（`attachedEditor != nil && item.kind == .image`）；图片显示**时长选择器**（2s / 3s 默认 / 5s / 自定义 0.5–30s 步进 0.5）；「添加到时间线」以该时长上轨。视频分支不变。
- `LibraryView`：图片 tab 素材格显示 ＋（`showQuickAdd` 放开 `tab == .image`）；quickAdd 以默认 3s 上轨。
- `TimelineView`：still 的「裁剪」分支改时长；「变速」沿用现有 1x→0.5x→2x 循环（存倍率后对 still 天然可用，`clip.speed.rate` 显示不变）。
- `AppModel`：`appendAssetToTimeline` 按素材 kind 分支（image → `.still(3s)`）；新增 `appendImageToTimeline(_ item:, duration:)`。

## 测试策略

核心层单测 + e2e（App 层真机手动验证）：

- `PlanClipSource`：tagged JSON 编解码往返；旧 `range` 兼容解码为 `.video`。
- `TimelineDuration`：`.still` 的 outputDuration = 基准 / rate。
- `EditPlanValidator`：still 合法；source 与素材 kind 不一致报错；`duration ≤ 0` 报错；still 挂转场合法。
- Agent 工具：add_clip 加图片；split/trim/set_speed 对 still 的语义。
- e2e 导出：纯图片工程（时长 + 抽帧含图 + letterbox 无变形）；视频+图片+转场混排；`snapshot` 落在 still 区间。
- `AssetSynthesizer` 增一张合成图（e2e + CLI `genassets` 用）。
- 底线：现有 152 测试全绿；CLI 无回归（plan 格式向后兼容）。

## 明确不做（本期）

- 音频上轨（维持「音频整体后置」决策）
- 图片的 Ken Burns / 平移缩放动画（Kadr 有 `Transform`+`Animation`，留后续）
- 图片 trim（裁剪画面区域）/ 滤镜 / 调色
- 静态图 → 视频片段的「冻结帧」反向操作
- 图片画幅的模糊填充（本期 letterbox 用纯黑边）
