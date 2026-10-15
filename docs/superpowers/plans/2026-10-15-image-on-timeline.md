# 图片上轨实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让图片素材能上时间线，与视频片段混排，参与转场/变速/字幕/导出全链路。

**Architecture:** 模型层按公约 §3.4 把 `PlanClip.range` 换成 `PlanClip.source` 枚举（`.video(range)` / `.still(duration)`，schema v2→v3）。引擎层不改物化逻辑——Kadr 原生 `ImageClip` 内部已把图片编码成临时视频；我们只在交给 Kadr 前把图片预合成到 preset 画幅（消除 Kadr 的拉伸变形）。图片「变速」= 存倍率、输出时长 = 基准/rate，与视频同构。

**Tech Stack:** Swift 6 / SwiftPM、AVFoundation、CoreGraphics + ImageIO、Kadr 1.x、XCTest。

**Spec:** [2026-10-15-image-on-timeline-design.md](../specs/2026-10-15-image-on-timeline-design.md)

**通用命令：**
- 全量测试：`cd Packages/JangyCore && swift test`（现有 152 个为底线，全绿才算过）
- 单测过滤：`cd Packages/JangyCore && swift test --filter <类名>`
- App 构建：`xcodebuild -project Jangy.xcodeproj -scheme Jangy -destination 'generic/platform=iOS Simulator' build -skipMacroValidation`

---

### Task 1: StillImagePreparer（图片预合成到 preset 画幅）

Kadr 的 `ImageEncoder` 把图片**直接拉伸**铺满 preset 画幅、不保宽高比（实测：100×100 方图导出 1080×1920 整帧填充）。本任务新增一个 L3 小类型，把图片等比 aspect-fit 居中贴到 preset 画幅黑底画布上，交 Kadr 前的编码即为恒等缩放，变形消失。此类型不依赖模型变更，可独立测试。

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/StillImagePreparer.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/StillImagePreparerTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `Packages/JangyCore/Tests/JangyCoreTests/StillImagePreparerTests.swift`：

```swift
import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import JangyCore

/// 图片预合成：等比 aspect-fit 居中贴到画布黑底，消除 Kadr 的拉伸变形。
final class StillImagePreparerTests: XCTestCase {

    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    /// 造一张纯色 PNG（w×h 像素），返回文件 URL。
    private func makePNG(width: Int, height: Int, color: CGColor) throws -> URL {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = ctx.makeImage()!
        let url = workDir.appendingPathComponent("\(UUID().uuidString).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// 读 CGImage 上单点像素（RGBA，8bit）。
    private func pixel(_ cg: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let w = cg.width, h = cg.height
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
        defer { buf.deallocate() }
        let ctx = CGContext(data: buf, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let o = (y * w + x) * 4
        return (buf[o], buf[o + 1], buf[o + 2])
    }

    func testLetterboxesWideImageWithBlackBars() throws {
        // 200×100（2:1）纯红图 → 画布 1080×1920（9:16）。
        // aspect-fit：贴满宽 → 高 = 1080/2 = 540，居中于 y∈[690,1230]，上下为黑边。
        let url = try makePNG(width: 200, height: 100, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let cg = try XCTUnwrap(StillImagePreparer.prepareCGImage(url: url, canvas: CGSize(width: 1080, height: 1920)))
        XCTAssertEqual(cg.width, 1080)
        XCTAssertEqual(cg.height, 1920)

        let center = pixel(cg, x: 540, y: 960)
        XCTAssertGreaterThan(center.r, 200)
        XCTAssertLessThan(center.g, 60)
        XCTAssertLessThan(center.b, 60)
        // 顶部/底部黑边
        let top = pixel(cg, x: 540, y: 100)
        XCTAssertLessThan(top.r, 30)
        XCTAssertLessThan(top.g, 30)
        XCTAssertLessThan(top.b, 30)
        let bottom = pixel(cg, x: 540, y: 1820)
        XCTAssertLessThan(bottom.r, 30)
    }

    func testCanvasSizedImageFillsEntireFrame() throws {
        // 输入恰好等于画布宽高比：不留黑边（整帧红）。
        let url = try makePNG(width: 108, height: 192, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let cg = try XCTUnwrap(StillImagePreparer.prepareCGImage(url: url, canvas: CGSize(width: 1080, height: 1920)))
        let top = pixel(cg, x: 540, y: 20)
        XCTAssertGreaterThan(top.r, 200)
        XCTAssertLessThan(top.g, 60)
    }

    func testUndecodableFileReturnsNil() throws {
        let bogus = workDir.appendingPathComponent("not-an-image.txt")
        try Data("hello".utf8).write(to: bogus)
        XCTAssertNil(StillImagePreparer.prepareCGImage(url: bogus, canvas: CGSize(width: 1080, height: 1920)))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd Packages/JangyCore && swift test --filter StillImagePreparerTests`
Expected: FAIL — 编译错误，`StillImagePreparer` 不存在

- [ ] **Step 3: 实现**

创建 `Packages/JangyCore/Sources/JangyCore/StillImagePreparer.swift`：

```swift
import CoreGraphics
import Foundation
import ImageIO
import Kadr

/// 把图片文件准备成可直接喂 Kadr 的 `PlatformImage`。
///
/// 动机：Kadr 的 `ImageEncoder.createPixelBuffer` 把图片**直接拉伸**铺满 preset 画幅
/// （`context.draw(cgImage, in: 全画幅 rect)`），不保宽高比——实测 100×100 方图导出
/// 1080×1920 整帧填充。本类型先把图片等比 aspect-fit 居中贴到同画幅黑底画布上，
/// 之后 Kadr 的拉伸变为恒等缩放，变形消失。
///
/// 仅引擎适配层使用（L3）；画布尺寸 = `preset.resolution`。
enum StillImagePreparer {

    /// 图片文件 → 画布尺寸的 `PlatformImage`；不可解码返回 nil。
    static func prepare(url: URL, canvas: CGSize) -> PlatformImage? {
        prepareCGImage(url: url, canvas: canvas).map(platformImage(from:))
    }

    /// 跨平台核心：等比 aspect-fit 居中贴到画布黑底，返回画布尺寸 CGImage。
    /// 测试直接驱动此入口（避开 PlatformImage 的 UIKit/AppKit 分叉）。
    static func prepareCGImage(url: URL, canvas: CGSize) -> CGImage? {
        let width = Int(canvas.width), height = Int(canvas.height)
        guard width > 0, height > 0,
              let cgImage = downsample(url: url, maxPixel: max(width, height)),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            return nil
        }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let imageAspect = CGFloat(cgImage.width) / CGFloat(cgImage.height)
        let canvasAspect = canvas.width / canvas.height
        let drawRect: CGRect
        if imageAspect > canvasAspect {
            let h = canvas.width / imageAspect           // 图更宽：贴满宽，上下留黑
            drawRect = CGRect(x: 0, y: (canvas.height - h) / 2, width: canvas.width, height: h)
        } else {
            let w = canvas.height * imageAspect          // 图更高：贴满高，左右留黑
            drawRect = CGRect(x: (canvas.width - w) / 2, y: 0, width: w, height: canvas.height)
        }
        ctx.draw(cgImage, in: drawRect)
        return ctx.makeImage()
    }

    /// ImageIO 降采样：不加载全尺寸像素进内存（大图也不爆）。
    private static func downsample(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 应用 EXIF 方向
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func platformImage(from cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd Packages/JangyCore && swift test --filter StillImagePreparerTests`
Expected: PASS（3 个测试）

- [ ] **Step 5: Commit**

```bash
git add Packages/JangyCore/Sources/JangyCore/StillImagePreparer.swift Packages/JangyCore/Tests/JangyCoreTests/StillImagePreparerTests.swift
git commit -m "Core: StillImagePreparer——图片预合成到 preset 画幅（aspect-fit 居中 + 黑底），消除 Kadr ImageClip 拉伸变形

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: 模型迁移到 `PlanClip.source` + 引擎/校验/Agent 的 still 支持

本任务把 `PlanClip.range` 换成 `PlanClip.source` 枚举，并同步更新所有消费方（引擎、校验器、Agent 工具、App）。因是类型变更，模型与全部消费方必须在同一次提交里一起改，否则包不编译。still 的语义在本任务一次性落地：引擎预合成、校验器放开图片、Agent split/trim 的图片分支。

**Files:**
- Modify: `Packages/JangyCore/Sources/JangyCore/EditPlan.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/TimelineDuration.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/ProjectStore.swift`（`currentSchemaVersion` 2→3）
- Modify: `Packages/JangyCore/Sources/JangyCore/EngineBridge.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/EditPlanValidator.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/ProjectPackage.swift`
- Modify: `Packages/JangyCore/Sources/JangyAgent/AgentTools.swift`
- Modify: `Packages/JangyCore/Sources/JangyTestSupport/SamplePlan.swift`
- Modify: `Jangy/AppModel.swift`
- Modify: `Jangy/TimelineView.swift`
- Modify（测试，机械替换）: `EditPlanTests` / `TimelineDurationTests` / `EditPlanValidatorTests` / `EditStoreTests` / `EditStoreGroupingTests` / `UndoStackTests` / `EngineBridgeTests` / `PreviewPlaybackTests` / `ProjectPackageTests` / `AssetImporterTests` / `ExportEndToEndTests` / `AgentToolsTests`
- Modify: `Packages/JangyCore/Tests/JangyCoreTests/Fixtures/SamplePlan.golden.json`

- [ ] **Step 1: 加 `PlanClipSource` 枚举，改 `PlanClip`**

在 `Packages/JangyCore/Sources/JangyCore/EditPlan.swift` 中，替换整个 `PlanClip` 结构体（原第 42–74 行）为下述内容，并在其前插入 `PlanClipSource`：

```swift
/// 时间线片段的来源。视频取源区间（range），图片等静态素材无源区间、只有时长
/// （公约 §3.4 无源区间素材，不用魔法值表达）。
/// JSON tagged 格式：{"type":"video","range":[0,3]} / {"type":"still","duration":3}。
public enum PlanClipSource: Codable, Equatable, Sendable {
    case video(ClosedRange<TimeInterval>)
    case still(duration: TimeInterval)

    /// 源区间长度：video 为 range 长，still 为其基准时长。outputDuration 由此除以倍速。
    public var length: TimeInterval {
        switch self {
        case .video(let range): return range.upperBound - range.lowerBound
        case .still(let duration): return duration
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, range, duration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "video":
            self = .video(try container.decode(ClosedRange<TimeInterval>.self, forKey: .range))
        case "still":
            self = .still(duration: try container.decode(TimeInterval.self, forKey: .duration))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "未知的 PlanClipSource 类型 '\(type)'；支持的类型：video, still")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .video(let range):
            try container.encode("video", forKey: .type)
            try container.encode(range, forKey: .range)
        case .still(let duration):
            try container.encode("still", forKey: .type)
            try container.encode(duration, forKey: .duration)
        }
    }
}

/// 时间线片段。转场挂在片段尾部（`transitionAfter`），与 Kadr DSL 中
/// Transition 作为时间线一等元素的位置一一对应。
public struct PlanClip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// 素材引用：指向 EditPlan.assets 中的条目（v2 起替代文件名直引）。
    public var assetID: UUID
    /// 片段来源：视频源区间 / 静态素材时长。
    public var source: PlanClipSource
    public var speed: SpeedPlan
    public var transitionAfter: PlanTransition?

    public init(id: UUID = UUID(), assetID: UUID, source: PlanClipSource,
                speed: SpeedPlan = .flat(1.0), transitionAfter: PlanTransition? = nil) {
        self.id = id
        self.assetID = assetID
        self.source = source
        self.speed = speed
        self.transitionAfter = transitionAfter
    }

    private enum CodingKeys: String, CodingKey {
        case id, assetID, source, speed, transitionAfter
    }

    /// v2 旧字段：向后兼容解码（无 source 时回落到 .video(range)）。
    private enum LegacyKeys: String, CodingKey {
        case range
    }

    /// Agent 友好的宽容解码：`id` 缺省随机生成；`source` 缺省时回落 v2 旧 `range`。
    /// 编码走合成实现（只写 source，不写 range）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        assetID = try container.decode(UUID.self, forKey: .assetID)
        if let source = try container.decodeIfPresent(PlanClipSource.self, forKey: .source) {
            self.source = source
        } else if let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            .decodeIfPresent(ClosedRange<TimeInterval>.self, forKey: .range) {
            self.source = .video(legacy)
        } else {
            throw DecodingError.keyNotFound(CodingKeys.source, DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "clip 缺 source，且无 v2 旧 range 可回落"))
        }
        speed = try container.decodeIfPresent(SpeedPlan.self, forKey: .speed) ?? .flat(1.0)
        transitionAfter = try container.decodeIfPresent(PlanTransition.self, forKey: .transitionAfter)
    }
}
```

同时把 `EditPlan` 的 `version` 默认值从 2 改为 3（init 与宽容解码两处）：

```swift
    public init(version: Int = 3, assets: [AssetItem] = [], clips: [PlanClip], captions: CaptionTrack? = nil, preset: OutputPreset = .reelsAndShorts) {
```
```swift
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 3
```

- [ ] **Step 2: `TimelineDuration` 改用 source**

替换 `Packages/JangyCore/Sources/JangyCore/TimelineDuration.swift` 中 `PlanClip` 的扩展（原第 10–15 行）：

```swift
extension PlanClip {
    /// 片段在输出时间线上的时长 = 源区间长度 / 倍速。
    /// 视频：源区间长 / 倍速；图片：基准时长 / 倍速（图片「变速」即改输出时长）。
    public var outputDuration: TimeInterval {
        source.length / speed.rate
    }
}
```

- [ ] **Step 3: schema 版本守卫提到 3**

`Packages/JangyCore/Sources/JangyCore/ProjectStore.swift` 中：

```swift
    /// 当前支持的 EditPlan schema 版本（与 EditPlan.version 默认值一致）
    public static let currentSchemaVersion = 3
```

- [ ] **Step 4: `EngineBridge` 支持 still（图片预合成 + ImageClip）**

替换 `Packages/JangyCore/Sources/JangyCore/EngineBridge.swift` 的 `makeComposition` 函数体（原第 29–79 行）为下述内容——注意 **preset 提到循环之前**（still 需要 `preset.resolution` 作画布尺寸）：

```swift
    /// 图片素材无法解码（损坏/非图片）。正常路径已被 EditPlanValidator 拦截。
    public struct ImageDecodeError: Error, CustomStringConvertible {
        public let assetID: UUID
        public var description: String { "图片素材无法解码: \(assetID)" }
    }

    /// - Parameter options: 导出配置（仅导出链路关心 SDR 降级；预览走默认 HDR 直通）。
    public static func makeComposition(from plan: EditPlan, resolver: AssetResolver,
                                       options: ExportOptions = .default) async throws -> Kadr.Video {
        // 显式映射而非静默丢弃：新增 OutputPreset case 时此处必须编译报错。
        let preset: Kadr.Preset
        switch plan.preset {
        case .reelsAndShorts:
            preset = options.hdrPassthrough
                ? .reelsAndShorts
                // SDR 降级：几何/帧率不变（同 1080x1920@30），编码换 H.264——
                // AVAssetExportPresetHighestQuality 会把 BT.2020+HLG 自动色调映射到
                // BT.709（POC 验证点③实测与 709 composition 路径产物逐像素一致）。
                // 不用 .tiktok（同为 1080x1920@30 H.264）是刻意解耦语义档位名。
                : .custom(width: 1080, height: 1920, frameRate: 30, codec: .h264)
        }

        var elements: [any Kadr.Clip] = []
        for clip in plan.clips {
            guard let asset = plan.asset(withID: clip.assetID) else {
                throw MissingAssetError(assetID: clip.assetID)
            }
            let sourceURL = resolver.resolve(asset)
            switch clip.source {
            case .video(let range):
                var videoClip = Kadr.VideoClip(url: sourceURL)
                    .trimmed(to: range)
                // Kadr 1.x 校准：`speed(_:)` 只接受 Speed 枚举（Double 重载在 v0.14 被移除）。
                if clip.speed.rate != 1.0 {
                    videoClip = videoClip.speed(.flat(clip.speed.rate))
                }
                elements.append(videoClip)
            case .still(let duration):
                // 图片无源区间：预合成到 preset 画幅（消除 Kadr 拉伸变形），
                // 时长 = 基准 / 倍速（图片「变速」即改输出时长）。
                guard let image = StillImagePreparer.prepare(url: sourceURL, canvas: preset.resolution) else {
                    throw ImageDecodeError(assetID: clip.assetID)
                }
                elements.append(Kadr.ImageClip(image, duration: duration / clip.speed.rate))
            }
            if let transition = clip.transitionAfter {
                elements.append(kadrTransition(transition))
            }
        }

        // Kadr 1.x 校准：VideoBuilder 的 buildExpression 只接受单个 Clip，
        // 单个数组表达式不编译——用 for 循环走 buildArray 路径。
        var video = Kadr.Video {
            for element in elements { element }
        }.preset(preset)

        if let track = plan.captions, track.isEnabled {
            guard let captionAsset = plan.asset(withID: track.assetID) else {
                throw MissingAssetError(assetID: track.assetID)
            }
            let cues = try await Kadr.Caption.load(srt: resolver.resolve(captionAsset))
            video = video.captions(cues)                    // 软字幕：AVMetadataItem
            for cue in cues {
                video = video.overlay(captionOverlay(cue, style: track.style))  // 烧录：ImageOverlay（见 captionOverlay 注释）
            }
        }
        return video
    }
```

（`kadrTransition` / `captionOverlay` / `MissingAssetError` 保持原样。）

- [ ] **Step 5: `EditPlanValidator` 放开图片 + source/kind 一致**

替换 `Packages/JangyCore/Sources/JangyCore/EditPlanValidator.swift` 的 clip 循环体（原第 48–91 行）为：

```swift
        for (i, clip) in plan.clips.enumerated() {
            // 素材引用必须落在登记表里，且 source 与素材 kind 一致（视频↔video、图片↔image）
            let asset = plan.asset(withID: clip.assetID)
            if asset == nil {
                issues.append(ValidationIssue(path: "clips[\(i)].assetID", message: "引用了未登记的素材: \(clip.assetID)"))
            } else if let asset {
                switch clip.source {
                case .video where asset.kind != .video:
                    issues.append(ValidationIssue(path: "clips[\(i)].assetID",
                                                  message: "视频片段必须引用视频素材，实际为 \(asset.kind.rawValue)"))
                case .still where asset.kind != .image:
                    issues.append(ValidationIssue(path: "clips[\(i)].assetID",
                                                  message: "图片片段必须引用图片素材，实际为 \(asset.kind.rawValue)"))
                default:
                    break
                }
            }

            switch clip.source {
            case .video(let range):
                if range.lowerBound < 0 {
                    issues.append(ValidationIssue(path: "clips[\(i)].range", message: "裁剪起点不能为负"))
                } else if range.upperBound <= range.lowerBound {
                    issues.append(ValidationIssue(path: "clips[\(i)].range", message: "裁剪区间不能为空"))
                } else if let duration = asset?.duration,
                          range.upperBound > duration + Self.durationTolerance {
                    issues.append(ValidationIssue(path: "clips[\(i)].range",
                                                  message: "裁剪终点超出素材时长（\(duration)s）"))
                }
            case .still(let duration):
                if duration <= 0 {
                    issues.append(ValidationIssue(path: "clips[\(i)].source", message: "图片时长必须为正"))
                }
            }

            if !Self.speedRange.contains(clip.speed.rate) {
                issues.append(ValidationIssue(path: "clips[\(i)].speed",
                                              message: "变速倍率必须在 \(Self.speedRange.lowerBound)–\(Self.speedRange.upperBound) 之间"))
            }

            if let transition = clip.transitionAfter {
                guard i + 1 < plan.clips.count else {
                    issues.append(ValidationIssue(path: "clips[\(i)].transitionAfter", message: "最后一个片段不能挂转场"))
                    continue
                }
                if transition.duration <= 0 {
                    issues.append(ValidationIssue(path: "clips[\(i)].transitionAfter", message: "转场时长必须为正"))
                    continue
                }
                // Kadr CompositionBuilder 按变速后时长（裁剪时长 / speedRate）检查转场适配。
                // 这里刻意保持保守：用完整转场时长对 min(两侧)，而非 Kadr 的 fade 每侧 duration/2——
                // 过严安全（误拒少数合法 plan），过松危险（放行 Kadr 导出期才拒绝的 plan）。
                let thisDuration = clip.outputDuration
                let next = plan.clips[i + 1]
                let nextDuration = next.outputDuration
                if transition.duration > min(thisDuration, nextDuration) {
                    issues.append(ValidationIssue(path: "clips[\(i)].transitionAfter", message: "转场时长不能超过相邻片段时长"))
                }
            }
        }
```

- [ ] **Step 6: `ProjectPackage` 改写引用时带上 source**

`Packages/JangyCore/Sources/JangyCore/ProjectPackage.swift` 第 144–145 行改为：

```swift
            PlanClip(id: $0.id, assetID: idMap[$0.assetID] ?? $0.assetID,
                     source: $0.source, speed: $0.speed, transitionAfter: $0.transitionAfter)
```

- [ ] **Step 7: `SamplePlan` 改 source**

`Packages/JangyCore/Sources/JangyTestSupport/SamplePlan.swift` 三处 `range: 0...3` / `range: 0...2` 改为 `source: .video(0...3)` / `source: .video(0...2)`（其余参数不动）。

- [ ] **Step 8: `AgentTools` split / trim 加 still 分支**

`Packages/JangyCore/Sources/JangyAgent/AgentTools.swift` 的 `SplitClipTool.call` 中，从 `let clip = store.plan.clips[index]`（原第 232 行）到 `return ToolEnvelope.applied(...)` 结束（原第 250 行）整段替换为：

```swift
            let clip = store.plan.clips[index]
            switch clip.source {
            case .video(let range):
                guard args.at > range.lowerBound, args.at < range.upperBound else {
                    return ToolEnvelope.error("分割点 \(args.at) 须严格落在片段源区间 \(range.lowerBound)–\(range.upperBound) 内")
                }
                let secondID = UUID()
                let result = store.apply { plan in
                    var first = plan.clips[index]
                    var second = plan.clips[index]
                    first.source = .video(range.lowerBound...args.at)
                    first.transitionAfter = nil
                    second.id = secondID
                    second.source = .video(args.at...range.upperBound)
                    plan.clips.replaceSubrange(index...index, with: [first, second])
                }
                return ToolEnvelope.applied(result) { plan in
                    Payload(firstClipID: args.clipID, secondClipID: secondID.uuidString,
                            renderedDuration: plan.renderedDuration)
                }
            case .still(let duration):
                // 图片无源区间：分割点按「片段内已过时间」解释，切成两段 still（倍率两段都保留）。
                guard args.at > 0, args.at < duration else {
                    return ToolEnvelope.error("分割点 \(args.at) 须严格落在图片时长 0–\(duration) 内")
                }
                let secondID = UUID()
                let result = store.apply { plan in
                    var first = plan.clips[index]
                    var second = plan.clips[index]
                    first.source = .still(duration: args.at)
                    first.transitionAfter = nil
                    second.id = secondID
                    second.source = .still(duration: duration - args.at)
                    plan.clips.replaceSubrange(index...index, with: [first, second])
                }
                return ToolEnvelope.applied(result) { plan in
                    Payload(firstClipID: args.clipID, secondClipID: secondID.uuidString,
                            renderedDuration: plan.renderedDuration)
                }
            }
```

`SplitClipTool` 的 `description` 改为：

```swift
    let description = "在片段内指定时刻把片段切成两段。变速等片段属性两段都保留；原片段尾部转场归后半段。视频按源区间时间切，图片按片段内已过时间切。"
```

`TrimClipTool.call` 中 `store.apply { plan in plan.clips[index].range = ... }`（原第 285–287 行）替换为：

```swift
            let result = store.apply { plan in
                switch plan.clips[index].source {
                case .video:
                    plan.clips[index].source = .video(args.rangeStart...args.rangeEnd)
                case .still:
                    // 图片无源区间：以 rangeEnd − rangeStart 作为新基准时长。
                    plan.clips[index].source = .still(duration: args.rangeEnd - args.rangeStart)
                }
            }
```

`TrimClipTool` 的 `description` 改为：

```swift
    let description = "修改片段时长。视频：改源区间（区间须在素材时长内且非空）；图片：以 rangeEnd − rangeStart 作为新时长。"
```

- [ ] **Step 9: `AppModel` 按 kind 分支上轨**

`Jangy/AppModel.swift` 的两个 `appendAssetToTimeline` 替换为：

```swift
    /// 素材从素材库上轨：登记（若未登记）+ 追加片段，同一次 apply（公约 §3 单撤销步）。
    /// 视频全长上轨（duration 未探测则不追加）；图片以默认时长上轨。
    func appendAssetToTimeline(_ item: AssetItem) {
        edit { plan in
            if plan.asset(withID: item.id) == nil {
                plan.assets.append(item)
            }
            switch item.kind {
            case .image:
                plan.clips.append(PlanClip(assetID: item.id, source: .still(duration: Self.defaultStillDuration)))
            default:
                if let duration = item.duration {
                    plan.clips.append(PlanClip(assetID: item.id, source: .video(0...duration)))
                }
            }
        }
    }

    /// trim 后上轨：片段区间取 trim 结果。
    func appendAssetToTimeline(_ item: AssetItem, range: ClosedRange<TimeInterval>) {
        edit { plan in
            if plan.asset(withID: item.id) == nil {
                plan.assets.append(item)
            }
            plan.clips.append(PlanClip(assetID: item.id, source: .video(range)))
        }
    }

    /// 图片上轨：以指定时长追加（预览页时长选择器）。
    func appendImageToTimeline(_ item: AssetItem, duration: TimeInterval) {
        edit { plan in
            if plan.asset(withID: item.id) == nil {
                plan.assets.append(item)
            }
            plan.clips.append(PlanClip(assetID: item.id, source: .still(duration: duration)))
        }
    }

    /// 图片上轨默认时长（秒）。
    static let defaultStillDuration: TimeInterval = 3.0
```

- [ ] **Step 10: `TimelineView` 裁剪分支改 source**

`Jangy/TimelineView.swift` 的 `toggleTrim`（原第 89–94 行）替换为：

```swift
    private func toggleTrim(_ index: Int) {
        model.edit {
            switch $0.clips[index].source {
            case .video(let range):
                $0.clips[index].source = .video(range.lowerBound == 0 ? 0.5...2.5 : 0...3)
            case .still:
                $0.clips[index].source = .still(duration: 2.0)
            }
        }
    }
```

- [ ] **Step 11: 更新黄金 JSON 为新格式**

`Packages/JangyCore/Tests/JangyCoreTests/Fixtures/SamplePlan.golden.json`：把三段 clip 的 `"range": [a, b]` 各替换为 tagged source，并把末尾 `"version": 2` 改为 `"version": 3`。例如第一段：

```json
      "source" : {
        "range" : [
          0,
          3
        ],
        "type" : "video"
      },
```

（三段的 range 值分别是 `[0,3]`、`[0,3]`、`[0,2]`，其余字段不动。）

- [ ] **Step 12: 机械更新测试文件里的 `range:` 与 `.range`**

按下表逐处替换（构造点改 `source:`，断言点改 `source`）：

| 文件:行 | 原 | 新 |
|---|---|---|
| `EditStoreGroupingTests.swift:12` | `PlanClip(assetID: assetID, range: 0...3)` | `PlanClip(assetID: assetID, source: .video(0...3))` |
| `EditStoreGroupingTests.swift:22` | `$0.clips[0].range = 0...2` | `$0.clips[0].source = .video(0...2)` |
| `EditStoreGroupingTests.swift:29` | `store.plan.clips[0].range, 0...3` | `store.plan.clips[0].source, .video(0...3)` |
| `EditStoreTests.swift:10` | `PlanClip(assetID: assetID, range: 0...3)` | `PlanClip(assetID: assetID, source: .video(0...3))` |
| `EditStoreTests.swift:37` | `PlanClip(assetID: UUID(), range: 0...1)` | `PlanClip(assetID: UUID(), source: .video(0...1))` |
| `EditStoreTests.swift:49` | `PlanClip(assetID: newAsset.id, range: 0...6)` | `PlanClip(assetID: newAsset.id, source: .video(0...6))` |
| `UndoStackTests.swift:10` | `PlanClip(assetID: asset.id, range: 0...1)` | `PlanClip(assetID: asset.id, source: .video(0...1))` |
| `EngineBridgeTests.swift:70` | `PlanClip(assetID: assetID, range: 0...3)` | `PlanClip(assetID: assetID, source: .video(0...3))` |
| `AssetImporterTests.swift:61` | `PlanClip(assetID: item.id, range: 0...(item.duration ?? 0))` | `PlanClip(assetID: item.id, source: .video(0...(item.duration ?? 0)))` |
| `ExportEndToEndTests.swift:195` | `PlanClip(assetID: asset.id, range: spec.range, speed: .flat(spec.speed))` | `PlanClip(assetID: asset.id, source: .video(spec.range), speed: .flat(spec.speed))` |
| `ProjectPackageTests.swift:48-49` | `PlanClip(id: $0.id, assetID: idMap[$0.assetID]!, range: $0.range, speed: $0.speed, transitionAfter: $0.transitionAfter)` | `PlanClip(id: $0.id, assetID: idMap[$0.assetID]!, source: $0.source, speed: $0.speed, transitionAfter: $0.transitionAfter)` |
| `PreviewPlaybackTests.swift:42,44,86,88,120,122` | 各自 `range: 0...3` | `source: .video(0...3)` |
| `EditPlanTests.swift:18,22` | `range: 0...3` | `source: .video(0...3)` |
| `EditPlanTests.swift:88` | `plan.clips[0].range, 0...3` | `plan.clips[0].source, .video(0...3)` |
| `AgentToolsTests.swift:127` | `clips[0].range, 0...1.5` | `clips[0].source, .video(0...1.5)` |
| `AgentToolsTests.swift:129` | `clips[1].range, 1.5...3` | `clips[1].source, .video(1.5...3)` |
| `AgentToolsTests.swift:158` | `plan.clips[0].range, 1...2.5` | `plan.clips[0].source, .video(1...2.5)` |
| `AgentToolsTests.swift:168` | `plan.clips[0].range, 0...3` | `plan.clips[0].source, .video(0...3)` |

测试辅助函数里构造 clip 的（`EditPlanValidatorTests.clip(_:)`、`TimelineDurationTests.clip(_:)`）改为：

```swift
// EditPlanValidatorTests.swift:20-25
    private func clip(_ range: ClosedRange<TimeInterval> = 0...3,
                      speed: SpeedPlan = .flat(1.0),
                      transition: PlanTransition? = nil,
                      assetID: UUID? = nil) -> PlanClip {
        PlanClip(assetID: assetID ?? videoID, source: .video(range), speed: speed, transitionAfter: transition)
    }
```
```swift
// TimelineDurationTests.swift:9-12
    private func clip(_ range: ClosedRange<TimeInterval>, rate: Double = 1.0,
                      transition: PlanTransition? = nil) -> PlanClip {
        PlanClip(assetID: UUID(), source: .video(range), speed: .flat(rate), transitionAfter: transition)
    }
```

`EditPlanTests.swift` 的版本断言两处改为 3：

- 第 44 行 `func testDefaultVersionIs2()` → 重命名为 `testDefaultVersionIs3()`，断言 `XCTAssertEqual(makePlan().version, 3)`
- 第 79 行（`testDecodesMinimalJSON` 内）`XCTAssertEqual(plan.version, 2)` → `XCTAssertEqual(plan.version, 3)`

`EditPlanTests.testDecodesMinimalJSON` / `testDecodesWithoutAssetsTable`、`PlanLoaderTests.swift:13,21` 里的 JSON 用的是旧 `"range": [0, 3]`——**保留不动**（正好覆盖 v2 回落路径；PlanLoaderTests 不断言 version 值，仍绿）。

- [ ] **Step 13: 加 source 编解码与 still 的专项测试**

在 `Packages/JangyCore/Tests/JangyCoreTests/EditPlanTests.swift` 末尾（`}` 前）追加：

```swift
    func testPlanClipSourceWireFormat() throws {
        struct Wrapper: Codable { var source: PlanClipSource }
        let videoJSON = String(decoding: try JSONEncoder().encode(Wrapper(source: .video(0...3))), as: UTF8.self)
        XCTAssertTrue(videoJSON.contains("\"type\":\"video\""), "got: \(videoJSON)")
        XCTAssertTrue(videoJSON.contains("\"range\":[0,3]"), "got: \(videoJSON)")

        let stillJSON = String(decoding: try JSONEncoder().encode(Wrapper(source: .still(duration: 2.5))), as: UTF8.self)
        XCTAssertTrue(stillJSON.contains("\"type\":\"still\""), "got: \(stillJSON)")
        XCTAssertTrue(stillJSON.contains("\"duration\":2.5"), "got: \(stillJSON)")

        XCTAssertEqual(try JSONDecoder().decode(PlanClipSource.self,
                                                from: Data(#"{"type":"still","duration":2.5}"#.utf8)),
                       .still(duration: 2.5))
    }

    /// v2 旧 clip（只有 range）宽容解码为 .video(range)。
    func testDecodesLegacyRangeField() throws {
        let json = #"{"assetID":"aaaaaaaa-0000-0000-0000-000000000001","range":[1,2.5]}"#
        let clip = try JSONDecoder().decode(PlanClip.self, from: Data(json.utf8))
        XCTAssertEqual(clip.source, .video(1...2.5))
    }

    func testUnknownClipSourceTypeThrows() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(PlanClipSource.self,
                                     from: Data(#"{"type":"gif","duration":1}"#.utf8))
        ) { error in
            XCTAssertTrue(String(describing: error).contains("gif"))
        }
    }
```

- [ ] **Step 14: 跑全量测试**

Run: `cd Packages/JangyCore && swift test`
Expected: 全绿（数量 ≈ 152 + 新增 3 个 source 测试）

- [ ] **Step 15: Commit**

```bash
git add -A
git commit -m "Core: PlanClip.range 演进为 source 枚举（.video(range)/.still(duration)，schema v3）——图片上轨的模型基础 + 引擎/校验/Agent 的 still 支持

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Agent `add_clip` 支持图片

**Files:**
- Modify: `Packages/JangyCore/Sources/JangyAgent/AgentTools.swift`
- Test: `Packages/JangyCore/Tests/JangyAgentTests/AgentToolsTests.swift`

- [ ] **Step 1: 写失败测试**

在 `AgentToolsTests.swift` 的 `// MARK: - add_clip` 段落末尾追加：

```swift
    func testAddImageClipRegistersAndProbesRealFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jangy-agent-img-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 造一张 PNG
        let pngURL = dir.appendingPathComponent("photo.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
            .write(to: pngURL)

        let context = AgentRunContext(plan: SamplePlan.make(),
                                      resolver: AssetResolver(directory: dir),
                                      framesDirectory: dir, maxToolCalls: 30)
        let result = try await AddClipTool(context: context)
            .call(parsed: .init(fileName: "photo.png", rangeStart: nil, rangeEnd: nil, speed: nil, duration: 4.0))
        XCTAssertEqual(try decodeEnvelope(result).status, "ok")
        let plan = await context.plan
        XCTAssertEqual(plan.clips.count, 4)
        XCTAssertEqual(plan.clips.last?.source, .still(duration: 4.0))
        let registered = plan.assets.first { $0.fileName == "photo.png" }
        XCTAssertEqual(registered?.kind, .image)
        XCTAssertEqual(registered?.pixelWidth, 1)
    }

    func testAddImageClipDefaultsToThreeSeconds() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jangy-agent-img-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
            .write(to: dir.appendingPathComponent("photo.png"))

        let context = AgentRunContext(plan: SamplePlan.make(),
                                      resolver: AssetResolver(directory: dir),
                                      framesDirectory: dir, maxToolCalls: 30)
        let result = try await AddClipTool(context: context)
            .call(parsed: .init(fileName: "photo.png", rangeStart: nil, rangeEnd: nil, speed: nil, duration: nil))
        XCTAssertEqual(try decodeEnvelope(result).status, "ok")
        XCTAssertEqual(await context.plan.clips.last?.source, .still(duration: 3.0))
    }

    func testAddVideoClipStillRequiresRange() async throws {
        let context = makeContext()
        let result = try await AddClipTool(context: context)
            .call(parsed: .init(fileName: "clip1.mp4", rangeStart: nil, rangeEnd: nil, speed: nil, duration: nil))
        let envelope = try decodeEnvelope(result)
        XCTAssertEqual(envelope.status, "error")
        XCTAssertTrue(envelope.message?.contains("rangeStart") == true)
    }
```

同时把本文件里现有的三处 `AddClipTool(...).call(parsed: .init(fileName:..., rangeStart: 0, rangeEnd: 1, speed: nil))` 补上 `duration: nil` 参数（第 64、76、95、107 行的 `.init(...)`）。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd Packages/JangyCore && swift test --filter AgentToolsTests`
Expected: FAIL — 编译错误，`Args` 无 `duration` 参数、`rangeStart`/`rangeEnd` 仍为必填

- [ ] **Step 3: 实现**

`Packages/JangyCore/Sources/JangyAgent/AgentTools.swift` 的 `AddClipTool` 整体替换为：

```swift
struct AddClipTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "add_clip"
    let description = "把素材追加为时间线末尾的片段。视频：提供 rangeStart/rangeEnd（源区间）；图片：提供可选 duration（秒，缺省 3），忽略 range。fileName 未登记时会在同一次编辑里自动登记（先探测素材元数据）。"

    @Generable
    struct Args {
        @Guide(description: "素材文件名（相对素材目录），如 clip1.mp4 或 photo.png")
        let fileName: String
        @Guide(description: "视频源区间起点（秒）。图片忽略。")
        let rangeStart: Double?
        @Guide(description: "视频源区间终点（秒）。图片忽略。")
        let rangeEnd: Double?
        @Guide(description: "变速倍率，0.25–4.0，缺省 1.0")
        let speed: Double?
        @Guide(description: "图片显示时长（秒），缺省 3.0。视频忽略。")
        let duration: Double?
    }

    struct Payload: Encodable {
        let clipID: String
        let assetID: String
        let registeredNewAsset: Bool
        let renderedDuration: TimeInterval
    }

    /// 按扩展名判图片（登记表未命中、需先探测时用）。
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "webp", "gif", "bmp"]

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        let currentPlan = await context.plan
        let existingFileNames = Set(currentPlan.assets.map(\.fileName))

        // 已登记则复用其 kind；否则按扩展名判类型
        let knownKind = currentPlan.assets.first { $0.fileName == args.fileName }?.kind
        let ext = (args.fileName as NSString).pathExtension.lowercased()
        let isImage = (knownKind == .image) || (knownKind == nil && Self.imageExtensions.contains(ext))

        // 登记素材：未登记先探测元数据（文件不存在直接报错，免得到引擎期才炸）
        var asset = currentPlan.assets.first { $0.fileName == args.fileName }
        if asset == nil {
            if isImage {
                guard context.resolver.exists(AssetItem(kind: .image, fileName: args.fileName)) else {
                    return ToolEnvelope.error("素材文件不存在: \(args.fileName)。请用 list_assets 查看可用素材")
                }
                let metadata = AssetImporter.probeImageMetadata(of: context.resolver.resolve(fileName: args.fileName))
                asset = AssetItem(kind: .image, fileName: args.fileName, origin: .files,
                                  pixelWidth: metadata.pixelWidth, pixelHeight: metadata.pixelHeight,
                                  importedAt: Date())
            } else {
                guard context.resolver.exists(AssetItem(kind: .video, fileName: args.fileName)) else {
                    return ToolEnvelope.error("素材文件不存在: \(args.fileName)。请用 list_assets 查看可用素材")
                }
                let metadata = await AssetImporter.probeMetadata(of: context.resolver.resolve(fileName: args.fileName))
                asset = AssetItem(kind: .video, fileName: args.fileName, origin: .files,
                                  duration: metadata.duration, pixelWidth: metadata.pixelWidth,
                                  pixelHeight: metadata.pixelHeight, hasAudio: metadata.hasAudio,
                                  importedAt: Date())
            }
        }
        guard let asset else { return ToolEnvelope.error("素材登记失败") }
        let rate = args.speed ?? 1.0

        // 视频需 range（ClosedRange 构造下界>上界会运行时 trap，必须先拦）
        if asset.kind == .video {
            guard let start = args.rangeStart, let end = args.rangeEnd, start < end else {
                return ToolEnvelope.error("视频片段必须提供非空源区间：rangeStart 须小于 rangeEnd")
            }
        }

        // 登记 + 追加必须在同一次 apply（公约：单事务、单撤销步）
        return await context.withStore { store in
            let result = store.apply { plan in
                let assetID: UUID
                if let registered = plan.assets.first(where: { $0.fileName == asset.fileName }) {
                    assetID = registered.id
                } else {
                    plan.assets.append(asset)
                    assetID = asset.id
                }
                let clip: PlanClip
                switch asset.kind {
                case .image:
                    clip = PlanClip(assetID: assetID, source: .still(duration: args.duration ?? 3.0), speed: .flat(rate))
                default:
                    clip = PlanClip(assetID: assetID,
                                    source: .video(args.rangeStart!...args.rangeEnd!),
                                    speed: .flat(rate))
                }
                plan.clips.append(clip)
            }
            return ToolEnvelope.applied(result) { plan in
                let clip = plan.clips.last!
                let registered = plan.assets.first { $0.fileName == asset.fileName }!
                return Payload(clipID: clip.id.uuidString, assetID: registered.id.uuidString,
                               registeredNewAsset: !existingFileNames.contains(asset.fileName),
                               renderedDuration: plan.renderedDuration)
            }
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd Packages/JangyCore && swift test --filter AgentToolsTests`
Expected: PASS（含新增 3 个 + 原有全部）

- [ ] **Step 5: Commit**

```bash
git add Packages/JangyCore/Sources/JangyAgent/AgentTools.swift Packages/JangyCore/Tests/JangyAgentTests/AgentToolsTests.swift
git commit -m "Agent: add_clip 支持图片——按扩展名判类型、探测像素尺寸、追加 .still(duration)，range 对视频必填/图片忽略

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: AssetSynthesizer 合成测试图 + CoverGenerator 图片封面

**Files:**
- Modify: `Packages/JangyCore/Sources/JangyTestSupport/AssetSynthesizer.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/CoverGenerator.swift`
- Modify: `Packages/JangyCore/Sources/jangy-cli/JangyCLI.swift`（genassets 输出列表）
- Test: `Packages/JangyCore/Tests/JangyCoreTests/CoverGeneratorTests.swift`

- [ ] **Step 1: 写失败测试**

在 `CoverGeneratorTests.swift` 末尾（`}` 前）追加：

```swift
    func testGeneratesCoverForImageClip() async throws {
        // 首个片段是图片：封面应直接来自图片（不依赖 AVAssetImageGenerator）
        let imageURL = workDir.appendingPathComponent("Assets").appendingPathComponent(AssetSynthesizer.imageFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path), "合成器应生成图片")

        let asset = AssetItem(kind: .image, fileName: AssetSynthesizer.imageFileName,
                              origin: .synthesized, pixelWidth: 640, pixelHeight: 360)
        let plan = EditPlan(assets: [asset], clips: [PlanClip(assetID: asset.id, source: .still(duration: 3.0))])
        let cover = workDir.appendingPathComponent("cover-img.jpg")
        await CoverGenerator.generate(for: plan, resolver: resolver, to: cover)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cover.path))
        XCTAssertTrue(try Data(contentsOf: cover).starts(with: [0xFF, 0xD8]), "应为 JPEG")
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd Packages/JangyCore && swift test --filter CoverGeneratorTests`
Expected: FAIL — `AssetSynthesizer.imageFileName` 不存在

- [ ] **Step 3: AssetSynthesizer 增合成图**

`Packages/JangyCore/Sources/JangyTestSupport/AssetSynthesizer.swift`：

顶部 `import` 补 `import ImageIO` 与 `import UniformTypeIdentifiers`。加常量：

```swift
    public static let imageFileName = "still.png"
```

在 `synthesize` 里 srt 写入之后追加：

```swift
        let imageURL = directory.appendingPathComponent(imageFileName)
        if !FileManager.default.fileExists(atPath: imageURL.path) {
            try writeSolidColorImage(to: imageURL, color: CGColor(red: 0.95, green: 0.85, blue: 0.1, alpha: 1),
                                     width: 640, height: 360)
        }
```

加实现：

```swift
    /// 合成纯色 PNG 测试图（16:9，非 preset 画幅——用于验证 letterbox 无变形）。
    static func writeSolidColorImage(to url: URL, color: CGColor, width: Int, height: Int) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "AssetSynthesizer", code: 2, userInfo: [NSLocalizedDescriptionKey: "图片合成失败"])
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "AssetSynthesizer", code: 3, userInfo: [NSLocalizedDescriptionKey: "图片写入失败"])
        }
    }
```

- [ ] **Step 4: CoverGenerator 图片分支**

`Packages/JangyCore/Sources/JangyCore/CoverGenerator.swift` 的 `generate` 整体替换为（注意：**保持文件既有的 ImageIO 路线，不用 UIKit**——JangyCore 同时在 macOS 构建，`import UIKit` 编不过）：

```swift
    public static func generate(for plan: EditPlan, resolver: AssetResolver, to url: URL) async {
        let fm = FileManager.default
        guard let first = plan.clips.first,
              let asset = plan.asset(withID: first.assetID),
              resolver.exists(asset) else {
            try? fm.removeItem(at: url)
            return
        }
        let sourceURL = resolver.resolve(asset)
        let cgImage: CGImage?
        switch asset.kind {
        case .image:
            // 图片：ImageIO 降采样（不走 AVAssetImageGenerator——它只对视频有效）
            cgImage = downsample(url: sourceURL, maxPixel: 640)
        default:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: sourceURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            cgImage = try? await generator.image(at: .zero).image
        }
        guard let cgImage, let data = jpegData(of: cgImage, quality: 0.8) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// ImageIO 降采样：不加载全尺寸像素进内存。
    private static func downsample(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
```

（`jpegData(of:quality:)` 辅助函数保持原样不动。）

- [ ] **Step 5: CLI genassets 输出列表补图片**

`Packages/JangyCore/Sources/jangy-cli/JangyCLI.swift` 第 71 行的文件列表补 `AssetSynthesizer.imageFileName`：

```swift
                                   files: AssetSynthesizer.clipFileNames + [AssetSynthesizer.srtFileName, AssetSynthesizer.imageFileName]))
```

- [ ] **Step 6: 跑测试确认通过**

Run: `cd Packages/JangyCore && swift test --filter CoverGeneratorTests`
再跑 `swift test` 确认合成图未破坏其它用例（`SamplePlanTests` 等）
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Core: AssetSynthesizer 合成 16:9 测试图 + CoverGenerator 图片封面分支（ImageIO 降采样 JPEG）；CLI genassets 输出图片

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: 导出 e2e（纯图片 / 混排 / letterbox 无变形 / 快照）

**Files:**
- Test: `Packages/JangyCore/Tests/JangyCoreTests/ExportEndToEndTests.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/ImageExportEndToEndTests.swift`（新建）

- [ ] **Step 1: 写失败测试**

创建 `Packages/JangyCore/Tests/JangyCoreTests/ImageExportEndToEndTests.swift`：

```swift
import XCTest
import AVFoundation
import CoreGraphics
@testable import JangyCore
@testable import JangyTestSupport

/// 图片上轨的端到端导出回归：纯图片工程、视频+图片混排、letterbox 无变形、快照。
final class ImageExportEndToEndTests: XCTestCase {

    private var resolver: AssetResolver!
    private var assetsDir: URL!

    override func setUp() async throws {
        assetsDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        resolver = try AssetSynthesizer.synthesize(into: assetsDir)
    }

    override func tearDown() async throws {
        if let assetsDir { try? FileManager.default.removeItem(at: assetsDir) }
        resolver = nil
        assetsDir = nil
    }

    /// 合成图登记项（640×360 16:9，非 preset 画幅）
    private var imageAsset: AssetItem {
        AssetItem(kind: .image, fileName: AssetSynthesizer.imageFileName,
                  origin: .synthesized, pixelWidth: 640, pixelHeight: 360)
    }

    private func export(_ plan: EditPlan, to name: String) async throws -> URL {
        let out = assetsDir.appendingPathComponent(name)
        for try await _ in ExportRunner.export(plan: plan, resolver: resolver, to: out) {}
        return out
    }

    /// 抽帧（零容差）读单点像素。y 从图像顶部起算（CGBitmapContext 内存行 0 = 图像顶部）。
    private func pixel(_ url: URL, at seconds: TimeInterval, x: Int, y: Int) throws -> (UInt8, UInt8, UInt8) {
        let cg = try FrameSnapshotter.frame(from: AVURLAsset(url: url), at: seconds)
        let w = cg.width, h = cg.height
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
        defer { buf.deallocate() }
        let ctx = CGContext(data: buf, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let o = (y * w + x) * 4
        return (buf[o], buf[o + 1], buf[o + 2])
    }

    func testPureImageExportDurationAndContent() async throws {
        let image = imageAsset
        let plan = EditPlan(assets: [image],
                            clips: [PlanClip(assetID: image.id, source: .still(duration: 2.0))])
        let out = try await export(plan, to: "img-only.mp4")

        let duration = try await CMTimeGetSeconds(AVURLAsset(url: out).load(.duration))
        XCTAssertEqual(duration, 2.0, accuracy: 0.2, "渲染时长 = 图片时长")

        // 16:9 图在 9:16 画幅里贴满宽、上下留黑：中心为图片色（黄），顶部为黑边。
        // 断言用「中心明显亮于黑边」的相对式，规避 HDR→SDR 色调映射的绝对色偏。
        let center = try pixel(out, at: 1.0, x: 540, y: 960)
        let top = try pixel(out, at: 1.0, x: 540, y: 60)
        XCTAssertGreaterThan(Int(center.0), 120, "中心应为图片（偏黄）")
        XCTAssertGreaterThan(Int(center.1), 100)
        XCTAssertLessThan(Int(top.0), 60, "顶部应为黑边")
        XCTAssertLessThan(Int(top.1), 60)
        XCTAssertLessThan(Int(top.2), 60)
        XCTAssertGreaterThan(Int(center.0) - Int(top.0), 80, "中心应明显亮于黑边")
    }

    func testMixedVideoImageTransitionExport() async throws {
        // clip1 视频 + dissolve + 图片 + fade + clip2 视频
        let v1 = AssetItem(kind: .video, fileName: "clip1.mp4", origin: .synthesized,
                           duration: 4.0, pixelWidth: 1280, pixelHeight: 720, hasAudio: false)
        let v2 = AssetItem(kind: .video, fileName: "clip2.mp4", origin: .synthesized,
                           duration: 4.0, pixelWidth: 1280, pixelHeight: 720, hasAudio: false)
        let image = imageAsset
        let plan = EditPlan(assets: [v1, image, v2], clips: [
            PlanClip(assetID: v1.id, source: .video(0...3), transitionAfter: .dissolve(duration: 0.5)),
            PlanClip(assetID: image.id, source: .still(duration: 2.0), transitionAfter: .fade(duration: 0.5)),
            PlanClip(assetID: v2.id, source: .video(0...3)),
        ])
        let out = try await export(plan, to: "mixed.mp4")

        let asset = AVURLAsset(url: out)
        // 单视频轨（无 passthrough）
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let duration = try await CMTimeGetSeconds(asset.load(.duration))
        XCTAssertEqual(duration, plan.renderedDuration, accuracy: 0.25)
    }

    func testSnapshotInsideStillRegion() async throws {
        let image = imageAsset
        let plan = EditPlan(assets: [image],
                            clips: [PlanClip(assetID: image.id, source: .still(duration: 3.0))])
        let frames = try await FrameSnapshotter.snapshots(plan: plan, resolver: resolver, at: [1.5])
        let png = try XCTUnwrap(frames[1.5])
        XCTAssertTrue(png.starts(with: [0x89, 0x50, 0x4E, 0x47]), "应为 PNG")
    }

    func testStillSpeedHalvesOutputDuration() async throws {
        let image = imageAsset
        let plan = EditPlan(assets: [image],
                            clips: [PlanClip(assetID: image.id, source: .still(duration: 4.0), speed: .flat(2.0))])
        let out = try await export(plan, to: "img-speed.mp4")
        let duration = try await CMTimeGetSeconds(AVURLAsset(url: out).load(.duration))
        XCTAssertEqual(duration, 2.0, accuracy: 0.2, "图片 4s @2x → 输出 2s")
    }
}
```

- [ ] **Step 2: 跑测试确认通过（引擎已在 Task 2 打通）**

Run: `cd Packages/JangyCore && swift test --filter ImageExportEndToEndTests`
Expected: PASS（4 个测试）。若 `testPureImageExportDurationAndContent` 的黑边断言失败，说明 letterbox 未生效——回查 `StillImagePreparer` 与 `EngineBridge` 的 canvas 传参。

- [ ] **Step 3: 跑全量**

Run: `cd Packages/JangyCore && swift test`
Expected: 全绿

- [ ] **Step 4: Commit**

```bash
git add Packages/JangyCore/Tests/JangyCoreTests/ImageExportEndToEndTests.swift
git commit -m "Core: 图片导出 e2e——纯图片工程/视频+图片混排/letterbox 无变形/快照/图片变速时长

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: App UI（预览页时长选择器 + 素材库 ＋ + 时间线）

**Files:**
- Modify: `Jangy/AssetPreviewView.swift`
- Modify: `Jangy/LibraryView.swift`
- Modify: `Jangy/TimelineView.swift`
- Modify: `Jangy/LibraryModel.swift`

无单测（App 层），验证靠 App 构建 + 真机清单。

- [ ] **Step 1: `AssetPreviewView` 放开图片 + 时长选择器**

`Jangy/AssetPreviewView.swift`：

`canAdd` 改为：

```swift
    private var canAdd: Bool {
        guard model.attachedEditor != nil else { return false }
        switch item.kind {
        case .video: return item.duration != nil
        case .image: return true
        default: return false
        }
    }
```

加状态：

```swift
    @State private var stillDuration: TimeInterval = 3.0
    @State private var customStillDuration: Double = 3.0
```

在 `content` 之后、`canAdd` 按钮之前插入图片时长选择器（放在视频 trim 块同一位置）：

```swift
            if item.kind == .image {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("显示时长", selection: $stillDuration) {
                        Text("2s").tag(2.0)
                        Text("3s").tag(3.0)
                        Text("5s").tag(5.0)
                        Text("自定义").tag(-1.0)
                    }
                    .pickerStyle(.segmented)
                    if stillDuration == -1.0 {
                        HStack {
                            Text("\(customStillDuration.formatted(.number.precision(.fractionLength(1))))s")
                                .font(.caption).foregroundStyle(.secondary)
                            Slider(value: $customStillDuration, in: 0.5...30, step: 0.5)
                        }
                    }
                }
                .padding()
            }
```

「添加到时间线」按钮改为按类型分派：

```swift
            if canAdd {
                Button {
                    if item.kind == .image {
                        let duration = stillDuration == -1.0 ? customStillDuration : stillDuration
                        model.addImageToTimeline(item, duration: duration)
                    } else {
                        model.addToTimeline(item, range: trimRange)
                    }
                } label: {
                    Text("添加到时间线").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(item.kind == .video && trimRange.upperBound <= trimRange.lowerBound)
                .padding()
            }
```

并把文件顶部注释改为：

```swift
/// 素材预览页：视频（播放 + trim + 添加）、图片（缩放预览 + 时长选择 + 添加）、音频（播放示意）。
/// 添加按钮在剪辑页语境显示（视频/图片）；音频维持后置。
/// 信息面板：元数据 + 引用项目列表。预览页不提供删除。
```

- [ ] **Step 2: `LibraryModel` 加图片上轨入口**

`Jangy/LibraryModel.swift` 的 `addToTimeline` 之后追加：

```swift
    /// 图片上轨（预览页时长选择器）。
    func addImageToTimeline(_ item: AssetItem, duration: TimeInterval) {
        guard let editor = attachedEditor, !editor.agent.isRunning else { return }
        editor.appendImageToTimeline(item, duration: duration)
        toastMessage = "已添加到时间线"
        toastSequence += 1
    }
```

- [ ] **Step 3: `LibraryView` 图片 tab 显示 ＋**

`Jangy/LibraryView.swift` 第 138 行 `showQuickAdd` 改为：

```swift
                              showQuickAdd: model.attachedEditor != nil
                                  && ((tab == .video && item.duration != nil) || tab == .image),
```

并把文件顶部注释里的「视频格带 ＋ 快捷上轨」改为「视频/图片格带 ＋ 快捷上轨」。

- [ ] **Step 4: 构建验证**

Run: `xcodebuild -project Jangy.xcodeproj -scheme Jangy -destination 'generic/platform=iOS Simulator' build -skipMacroValidation`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Jangy/
git commit -m "App: 图片上轨 UI——预览页时长选择器（2/3/5/自定义）+ 素材库图片 tab 快捷上轨 + 时间线图片裁剪分支

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: 文档同步（known-pitfalls / 公约 / roadmap）

**Files:**
- Modify: `docs/known-pitfalls.md`
- Modify: `docs/architecture-covenant.md`
- Modify: `docs/roadmap-path-a.md`
- Modify: `AGENTS.md`（测试数）
- Modify: `README.md`（测试数/功能）

- [ ] **Step 1: known-pitfalls 增引擎行为条目**

在 `docs/known-pitfalls.md` 的「引擎行为」小节追加：

```markdown
- **Kadr ImageClip 拉伸图片到 preset 画幅（不保宽高比）**（2026-10-15 实测：100×100 方图导出 1080×1920 整帧填充）：`ImageEncoder.createPixelBuffer` 把 CGImage 直接 `draw(in: 全画幅 rect)`，非匹配宽高比的图片被压扁/拉长。规避：`EngineBridge` 交给 Kadr 前先用 `StillImagePreparer` 把图片等比 aspect-fit 居中贴到 preset 画幅黑底画布（`preset.resolution`），之后 Kadr 的拉伸变为恒等缩放。`ImageClip.background(_:)` 不能替代——`insertImageClip` 调 `ImageEncoder.encode` 时未传 backgroundColor，该修饰符在此路径不生效
- **Kadr ImageClip 内部物化**：`CompositionBuilder.insertImageClip` 每次构建 composition 都把图片按 preset 分辨率+帧率编码成临时 mp4、插入后即删。我们层无需物化/缓存/登记表扩展；代价是图片工程每次 rebuild 都有一次编码开销（当前可接受）
```

- [ ] **Step 2: 公约 §5.1 更新措辞**

`docs/architecture-covenant.md` §5.1 两条改为：

```markdown
- 模型层按 §3.4 建「无源区间素材」（`PlanClip.source` 枚举：`.video(range)` / `.still(duration)`）。引擎层直接用 Kadr 原生 `ImageClip`——它内部把图片编码成固定时长帧序列（临时文件，用后即删），无需自建写帧能力。交 Kadr 前先经 `StillImagePreparer` 预合成到 preset 画幅（Kadr 会拉伸，见 known-pitfalls）。
- 图片 clip 支持的操作集与视频一致（分割/转场）；「变速」= 存倍率、输出时长 = 基准时长 / rate（效果上即改输出时长）。
```

- [ ] **Step 3: roadmap 勾选 + 测试数**

`docs/roadmap-path-a.md`「待办 / 阶段：v1 执行」加一条并勾选（放在「已完成」区）：

```markdown
- [x] **图片上轨**（✅ 2026-10-15；spec：[image-on-timeline-design](superpowers/specs/2026-10-15-image-on-timeline-design.md)，plan：[image-on-timeline](superpowers/plans/2026-10-15-image-on-timeline.md)）
  - 要点：`PlanClip.source` 枚举（.video(range)/.still(duration)，schema v3）+ Kadr 原生 ImageClip 路线（不物化）+ Core letterbox 预合成消除拉伸 + 图片变速存倍率 + Agent add_clip/split/trim 图片分支 + App 预览页时长选择器/素材库图片 ＋
  - 验收：全量测试全绿 + 图片 e2e（纯图片/混排/letterbox 无变形/快照）+ App 构建通过
```

- [ ] **Step 4: AGENTS.md / README 测试数**

跑 `cd Packages/JangyCore && swift test 2>&1 | tail -5` 取实际测试总数，更新 `AGENTS.md` 与 `README.md` 里出现的「152 个」为该数。

- [ ] **Step 5: Commit**

```bash
git add docs/ AGENTS.md README.md
git commit -m "docs: 图片上轨落地同步——known-pitfalls 两条（Kadr 拉伸 + ImageClip 内部物化）、公约 §5.1 措辞、roadmap 勾选、测试数

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## 自检记录

- **Spec 覆盖**：引擎路线（Task 2 步骤 4）/ 画幅 letterbox（Task 1 + Task 2 步骤 4 + Task 5 断言）/ 模型 source（Task 2 步骤 1）/ 校验（Task 2 步骤 5）/ Agent 工具（Task 2 步骤 8 + Task 3）/ 封面（Task 4）/ UI（Task 6）/ 测试（Task 5 + 各任务内）/ 文档（Task 7）——逐条有落点。
- **顺序依赖**：Task 1（preparer，独立）→ Task 2（模型迁移，消费 preparer）→ Task 3/4（Agent、封面）→ Task 5（e2e）→ Task 6（UI）→ Task 7（文档）。Task 2 是类型变更，模型与全部消费方必须在同一次提交（否则包不编译），故合并为一个任务。
- **类型一致性**：`PlanClipSource.length`（Task 2 步骤 1 定义）被 `outputDuration`（步骤 2）使用；`StillImagePreparer.prepare(url:canvas:)` / `prepareCGImage(url:canvas:)`（Task 1）被 `EngineBridge`（Task 2 步骤 4）与测试使用；`AssetSynthesizer.imageFileName`（Task 4）被 CoverGenerator 测试与 e2e（Task 5）使用；`AppModel.appendImageToTimeline(_:duration:)`（Task 2 步骤 9）被 `LibraryModel.addImageToTimeline`（Task 6 步骤 2）使用。
- **CLI 零影响**：`sample`/`validate`/`export`/`snapshot`/`agent` 读写的 plan 经宽容解码兼容旧格式；`genassets` 多产一张图（Task 4 步骤 5）。
