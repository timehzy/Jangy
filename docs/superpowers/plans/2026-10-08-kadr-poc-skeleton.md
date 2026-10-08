# Kadr POC 工程骨架实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 搭建覆盖「多段拼接 + 转场 + 变速 + 字幕 + headless 导出」的 Kadr 最小 POC 工程骨架，含快照撤销栈与三层 App 结构。

**Architecture:** SwiftPM 包 `KadrPOC`（POCCore 库 + kadrpoc-cli 可执行）为核心，iOS App 薄壳本地引用。POCCore 内分编辑状态层（EditPlan/UndoStack/EditStore，纯 Swift）与引擎适配层（EngineBridge/PreviewBridge/ExportRunner，唯一 import Kadr 的地方）。

**Tech Stack:** Swift 6.3 / Xcode 26.4 / SwiftPM / Kadr `from: "1.0.0"` / KadrCaptions `.upToNextMinor(from: "0.12.0")` / swift-argument-parser / SwiftUI（iOS 17+）

**依据 Spec:** `docs/superpowers/specs/2026-10-08-kadr-poc-skeleton-design.md`

**API 核实说明（2026-10-08）：** 本计划代码已对照 Kadr 仓库 `main` 分支真实源码核实：`VideoBuilder` 接受 `[any Clip]` 动态数组；`Transition` 是 `Clip` 的 enum（fade/slide/dissolve，有 `TimeInterval` 工厂）；`Caption(text:timeRange:)`；`Video.captions(_:)` 累积；`overlay(_:)` 单条追加可循环 fold；`exporter(to:).run()` 返回 `AsyncThrowingStream<ExportProgress, Error>`；`makePlayerItem()` 为 `@MainActor async throws`。KadrCaptions 提供 `Caption.load(srt:)`。

**两处对 spec 的有意调整：**

1. **命名**：spec 中的 `Clip`/`Transition` 更名为 `PlanClip`/`PlanTransition`——Kadr 有同名 `Clip` 协议与 `Transition` 枚举，而 EngineBridge 与模型同处 POCCore 模块，同名会造成模块内歧义。
2. **字幕预览**：Kadr 官方文档明确 overlay 不进入预览（AVFoundation 的 `AVVideoCompositionCoreAnimationTool` 仅导出可用）。因此字幕烧录在导出产物中生效；App 预览用 SwiftUI Text 叠加层按播放器时间显示字幕。「所见即所导」对字幕这一项降级为「预览以原生 UI 近似」。

---

## 文件结构

```
KadrPOC/
├── Package.swift                          # Task 1
├── .gitignore                             # Task 1（.build/、TestArtifacts/）
├── Sources/
│   ├── POCCore/
│   │   ├── EditPlan.swift                 # Task 2：EditPlan/PlanClip/PlanTransition/SpeedPlan/CaptionTrack/CaptionStyle/MediaRef/OutputPreset
│   │   ├── AssetResolver.swift            # Task 3：素材目录解析
│   │   ├── EditPlanValidator.swift        # Task 4：ValidationIssue + 结构校验 + 素材存在性校验
│   │   ├── UndoStack.swift                # Task 5：快照栈
│   │   ├── EditStore.swift                # Task 6：@Observable 状态容器
│   │   ├── AssetSynthesizer.swift         # Task 7：AVAssetWriter 生成测试素材 + sample.srt
│   │   ├── SamplePlan.swift               # Task 7：内置演示工程 + JSON 输出
│   │   ├── EngineBridge.swift             # Task 8：EditPlan → Kadr.Video（唯一 import Kadr/KadrCaptions）
│   │   ├── PreviewBridge.swift            # Task 9：makePlayerItem 封装 + CaptionCue
│   │   ├── ExportRunner.swift             # Task 10：exporter.run() → ExportEvent 流
│   │   └── PlanLoader.swift               # Task 10：JSON 解码 + DecodingError 字段路径翻译
│   └── kadrpoc-cli/
│       └── KadrPOCCLI.swift               # Task 11：sample/validate/export/genassets 四子命令
└── Tests/
    └── POCCoreTests/
        ├── EditPlanTests.swift            # Task 2
        ├── AssetResolverTests.swift       # Task 3
        ├── EditPlanValidatorTests.swift   # Task 4
        ├── UndoStackTests.swift           # Task 5
        ├── EditStoreTests.swift           # Task 6
        ├── SamplePlanTests.swift          # Task 7（黄金 JSON 契约）
        ├── Fixtures/SamplePlan.golden.json# Task 7
        ├── EngineBridgeTests.swift        # Task 8
        ├── PlanLoaderTests.swift          # Task 10
        └── ExportEndToEndTests.swift      # Task 12
App/
└── JangyPOC.xcodeproj + Sources/          # Task 13（Xcode GUI 建工程 + 4 个 SwiftUI 文件）
docs/
└── poc-verification-checklist.md          # Task 14
```

---

## Task 1: SwiftPM 包初始化与依赖解析

**Files:**
- Create: `KadrPOC/Package.swift`
- Create: `KadrPOC/.gitignore`
- Create: `KadrPOC/Sources/POCCore/EditPlan.swift`（占位，Task 2 填实）
- Create: `KadrPOC/Sources/kadrpoc-cli/KadrPOCCLI.swift`（占位，Task 11 填实）

- [x] **Step 1: 创建 Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KadrPOC",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "POCCore", targets: ["POCCore"]),
        .executable(name: "kadrpoc-cli", targets: ["kadrpoc-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SteliyanH/kadr.git", from: "1.0.0"),
        .package(url: "https://github.com/SteliyanH/kadr-captions.git", .upToNextMinor(from: "0.12.0")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "POCCore",
            dependencies: [
                .product(name: "Kadr", package: "kadr"),
                .product(name: "KadrCaptions", package: "kadr-captions"),
            ]
        ),
        .executableTarget(
            name: "kadrpoc-cli",
            dependencies: [
                "POCCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "POCCoreTests",
            dependencies: ["POCCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

- [x] **Step 2: 创建占位源文件与 .gitignore**

`KadrPOC/Sources/POCCore/EditPlan.swift`：

```swift
import Foundation

/// POCCore 占位 —— Task 2 填充 EditPlan 模型。
public enum _POCCorePlaceholder {}
```

`KadrPOC/Sources/kadrpoc-cli/KadrPOCCLI.swift`：

```swift
@main
enum KadrPOCCLI {
    static func main() { print("kadrpoc-cli placeholder") }
}
```

`KadrPOC/.gitignore`：

```
.build/
TestArtifacts/
```

注意：`@main` 在 Task 11 会替换为 ArgumentParser 形式，届时 `main.swift` 冲突不存在（本文件即唯一入口）。

- [x] **Step 3: 验证依赖解析**

Run: `cd KadrPOC && swift build`
Expected: `Build complete!` —— Kadr、KadrCaptions、swift-argument-parser 全部解析成功。

**失败兜底（仅当依赖解析冲突时执行）**：若 KadrCaptions 的 kadr 版本钉与 `from: "1.0.0"` 冲突，则从 Package.swift 移除 kadr-captions 依赖，并在 Task 8 的 EngineBridge 中用下面的内置解析器替代 `Caption.load(srt:)`（写入 `Sources/POCCore/SRTParser.swift`）：

```swift
import Foundation
import CoreMedia

/// 兜底：最小 SRT 解析器（仅在 kadr-captions 依赖解析失败时启用）。
/// 支持子集：序号行、`HH:MM:SS,mmm --> HH:MM:SS,mmm`、单行文本、空行分隔。
public enum SRTParser {
    public struct Cue: Sendable, Equatable {
        public let text: String
        public let start: TimeInterval
        public let end: TimeInterval
    }

    public static func parse(_ content: String) -> [Cue] {
        var cues: [Cue] = []
        let blocks = content.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true)
            guard lines.count >= 3,
                  let rangeLine = lines.first(where: { $0.contains("-->") }),
                  let (start, end) = parseTimeRange(String(rangeLine)) else { continue }
            let text = lines.drop(while: { !$0.contains("-->") }).dropFirst().joined(separator: "\n")
            cues.append(Cue(text: text, start: start, end: end))
        }
        return cues
    }

    private static func parseTimeRange(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: " --> ")
        guard parts.count == 2, let s = parseTime(parts[0]), let e = parseTime(parts[1]) else { return nil }
        return (s, e)
    }

    private static func parseTime(_ s: String) -> TimeInterval? {
        let parts = s.trimmingCharacters(in: .whitespaces).components(separatedBy: ",")
        guard parts.count == 2, let ms = Double(parts[1]) else { return nil }
        let hms = parts[0].components(separatedBy: ":")
        guard hms.count == 3, let h = Double(hms[0]), let m = Double(hms[1]), let sec = Double(hms[2]) else { return nil }
        return h * 3600 + m * 60 + sec + ms / 1000
    }
}
```

- [x] **Step 4: Commit**

```bash
git add KadrPOC
git commit -m "KadrPOC SwiftPM 骨架：锁定 kadr 1.x / kadr-captions / argument-parser 依赖"
```

---

## Task 2: EditPlan 数据模型

**Files:**
- Modify: `KadrPOC/Sources/POCCore/EditPlan.swift`（替换占位）
- Test: `KadrPOC/Tests/POCCoreTests/EditPlanTests.swift`
- Create: `KadrPOC/Tests/POCCoreTests/Fixtures/.gitkeep`（资源目录占位）

- [x] **Step 1: 写失败测试**

```swift
import XCTest
@testable import POCCore

final class EditPlanTests: XCTestCase {

    private func makePlan() -> EditPlan {
        EditPlan(
            clips: [
                PlanClip(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                         source: MediaRef(fileName: "clip1.mp4"),
                         range: 0...3, speed: .flat(1.0),
                         transitionAfter: .dissolve(duration: 0.5)),
                PlanClip(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                         source: MediaRef(fileName: "clip2.mp4"),
                         range: 0...3, speed: .flat(0.5),
                         transitionAfter: nil),
            ],
            captions: CaptionTrack(source: MediaRef(fileName: "sample.srt"),
                                   isEnabled: true,
                                   style: CaptionStyle(fontSize: 48, isBold: true)),
            preset: .reelsAndShorts
        )
    }

    func testRoundTrip() throws {
        let plan = makePlan()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(plan)
        let decoded = try JSONDecoder().decode(EditPlan.self, from: data)
        XCTAssertEqual(decoded, plan)
    }

    func testDefaultVersionIs1() {
        XCTAssertEqual(makePlan().version, 1)
    }

    func testSpeedRateAccessor() {
        XCTAssertEqual(SpeedPlan.flat(0.5).rate, 0.5)
    }

    func testTransitionDurationAccessor() {
        XCTAssertEqual(PlanTransition.dissolve(duration: 0.5).duration, 0.5)
        XCTAssertEqual(PlanTransition.fade(duration: 0.3).duration, 0.3)
    }
}
```

- [x] **Step 2: 跑测试确认失败**

Run: `cd KadrPOC && swift test --filter EditPlanTests`
Expected: 编译失败（`EditPlan`/`PlanClip` 未定义）——Swift TDD 的失败态即编译失败。

- [x] **Step 3: 实现 EditPlan.swift（整体替换占位文件）**

```swift
import Foundation

/// 唯一事实源：撤销栈快照、磁盘存档、CLI 输入、Agent 生成目标共用此模型。
public struct EditPlan: Codable, Equatable, Sendable {
    public var version: Int
    public var clips: [PlanClip]
    public var captions: CaptionTrack?
    public var preset: OutputPreset

    public init(version: Int = 1, clips: [PlanClip], captions: CaptionTrack? = nil, preset: OutputPreset = .reelsAndShorts) {
        self.version = version
        self.clips = clips
        self.captions = captions
        self.preset = preset
    }
}

/// 时间线片段。转场挂在片段尾部（`transitionAfter`），与 Kadr DSL 中
/// Transition 作为时间线一等元素的位置一一对应。
public struct PlanClip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var source: MediaRef
    public var range: ClosedRange<TimeInterval>
    public var speed: SpeedPlan
    public var transitionAfter: PlanTransition?

    public init(id: UUID = UUID(), source: MediaRef, range: ClosedRange<TimeInterval>,
                speed: SpeedPlan = .flat(1.0), transitionAfter: PlanTransition? = nil) {
        self.id = id
        self.source = source
        self.range = range
        self.speed = speed
        self.transitionAfter = transitionAfter
    }
}

/// 素材引用：素材目录中的文件名；以 "/" 开头则视为绝对路径（CLI 喂 4K HDR 素材用）。
public struct MediaRef: Codable, Equatable, Sendable {
    public var fileName: String
    public init(fileName: String) { self.fileName = fileName }
}

/// POC 只做恒定变速；曲线变速（.curved）留待正式版。
public enum SpeedPlan: Codable, Equatable, Sendable {
    case flat(Double)

    public var rate: Double {
        switch self { case .flat(let r): return r }
    }
}

public enum PlanTransition: Codable, Equatable, Sendable {
    case dissolve(duration: TimeInterval)
    case fade(duration: TimeInterval)

    public var duration: TimeInterval {
        switch self {
        case .dissolve(let d): return d
        case .fade(let d): return d
        }
    }
}

public struct CaptionTrack: Codable, Equatable, Sendable {
    public var source: MediaRef
    public var isEnabled: Bool
    public var style: CaptionStyle

    public init(source: MediaRef, isEnabled: Bool, style: CaptionStyle) {
        self.source = source
        self.isEnabled = isEnabled
        self.style = style
    }
}

public struct CaptionStyle: Codable, Equatable, Sendable {
    public var fontSize: Double
    public var isBold: Bool

    public init(fontSize: Double, isBold: Bool) {
        self.fontSize = fontSize
        self.isBold = isBold
    }
}

public enum OutputPreset: String, Codable, Sendable {
    case reelsAndShorts
}
```

- [x] **Step 4: 跑测试确认通过**

Run: `cd KadrPOC && swift test --filter EditPlanTests`
Expected: 4 个测试全 PASS。

- [x] **Step 5: Commit**

```bash
git add KadrPOC/Sources/POCCore/EditPlan.swift KadrPOC/Tests
git commit -m "POCCore: EditPlan Codable 模型（PlanClip/SpeedPlan/PlanTransition/CaptionTrack）"
```

---

## Task 3: AssetResolver

**Files:**
- Create: `KadrPOC/Sources/POCCore/AssetResolver.swift`
- Test: `KadrPOC/Tests/POCCoreTests/AssetResolverTests.swift`

- [x] **Step 1: 写失败测试**

```swift
import XCTest
@testable import POCCore

final class AssetResolverTests: XCTestCase {

    func testResolvesFileNameAgainstDirectory() {
        let dir = URL(fileURLWithPath: "/tmp/poc-assets")
        let resolver = AssetResolver(directory: dir)
        XCTAssertEqual(resolver.resolve(MediaRef(fileName: "clip1.mp4")).path, "/tmp/poc-assets/clip1.mp4")
    }

    func testAbsolutePathPassThrough() {
        let resolver = AssetResolver(directory: URL(fileURLWithPath: "/tmp/ignored"))
        XCTAssertEqual(resolver.resolve(MediaRef(fileName: "/Users/x/4k-hdr.mp4")).path, "/Users/x/4k-hdr.mp4")
    }

    func testExists() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("a.mp4")
        try! Data().write(to: file)
        let resolver = AssetResolver(directory: dir)
        XCTAssertTrue(resolver.exists(MediaRef(fileName: "a.mp4")))
        XCTAssertFalse(resolver.exists(MediaRef(fileName: "b.mp4")))
    }
}
```

- [x] **Step 2: 跑测试确认失败**

Run: `cd KadrPOC && swift test --filter AssetResolverTests`
Expected: 编译失败（`AssetResolver` 未定义）。

- [x] **Step 3: 实现 AssetResolver.swift**

```swift
import Foundation

/// 把 MediaRef 解析为磁盘 URL。文件名相对 resolver 目录解析；
/// 绝对路径原样透传（CLI 喂任意素材、4K HDR 验证用）。
public struct AssetResolver: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func resolve(_ ref: MediaRef) -> URL {
        if ref.fileName.hasPrefix("/") {
            return URL(fileURLWithPath: ref.fileName)
        }
        return directory.appendingPathComponent(ref.fileName)
    }

    public func exists(_ ref: MediaRef) -> Bool {
        FileManager.default.fileExists(atPath: resolve(ref).path)
    }
}
```

- [x] **Step 4: 跑测试确认通过**

Run: `cd KadrPOC && swift test --filter AssetResolverTests`
Expected: 3 个测试全 PASS。

- [x] **Step 5: Commit**

```bash
git add KadrPOC/Sources/POCCore/AssetResolver.swift KadrPOC/Tests/POCCoreTests/AssetResolverTests.swift
git commit -m "POCCore: AssetResolver（文件名/绝对路径双模式素材解析）"
```

---

## Task 4: EditPlanValidator

**Files:**
- Create: `KadrPOC/Sources/POCCore/EditPlanValidator.swift`
- Test: `KadrPOC/Tests/POCCoreTests/EditPlanValidatorTests.swift`

- [x] **Step 1: 写失败测试**

```swift
import XCTest
@testable import POCCore

final class EditPlanValidatorTests: XCTestCase {

    private let validator = EditPlanValidator()

    private func clip(_ range: ClosedRange<TimeInterval> = 0...3,
                      speed: SpeedPlan = .flat(1.0),
                      transition: PlanTransition? = nil,
                      source: String = "clip1.mp4") -> PlanClip {
        PlanClip(source: MediaRef(fileName: source), range: range, speed: speed, transitionAfter: transition)
    }

    func testValidPlanPasses() {
        let plan = EditPlan(clips: [clip(transition: .dissolve(duration: 0.5)), clip()])
        XCTAssertTrue(validator.validate(plan).isEmpty)
    }

    func testEmptyClips() {
        let issues = validator.validate(EditPlan(clips: []))
        XCTAssertEqual(issues, [ValidationIssue(path: "clips", message: "至少需要一个片段")])
    }

    func testNegativeRangeStart() {
        let issues = validator.validate(EditPlan(clips: [clip(-1...3)]))
        XCTAssertEqual(issues.map(\.path), ["clips[0].range"])
    }

    func testEmptyRange() {
        let issues = validator.validate(EditPlan(clips: [clip(2...2)]))
        XCTAssertEqual(issues.map(\.path), ["clips[0].range"])
    }

    func testSpeedOutOfBounds() {
        XCTAssertEqual(validator.validate(EditPlan(clips: [clip(speed: .flat(0.1))])).map(\.path), ["clips[0].speed"])
        XCTAssertEqual(validator.validate(EditPlan(clips: [clip(speed: .flat(5.0))])).map(\.path), ["clips[0].speed"])
    }

    func testDanglingTransitionOnLastClip() {
        let issues = validator.validate(EditPlan(clips: [clip(transition: .dissolve(duration: 0.5))]))
        XCTAssertEqual(issues.map(\.path), ["clips[0].transitionAfter"])
    }

    func testTransitionLongerThanNeighbor() {
        // clip0 裁后 1s，转场 2s 超过它
        let issues = validator.validate(EditPlan(clips: [clip(0...1, transition: .dissolve(duration: 2)), clip()]))
        XCTAssertEqual(issues.map(\.path), ["clips[0].transitionAfter"])
    }

    func testCaptionSourceMustBeSRT() {
        let plan = EditPlan(clips: [clip()],
                            captions: CaptionTrack(source: MediaRef(fileName: "a.vtt"), isEnabled: true,
                                                   style: CaptionStyle(fontSize: 48, isBold: true)))
        XCTAssertEqual(validator.validate(plan).map(\.path), ["captions.source"])
    }

    func testCollectsAllIssuesAtOnce() {
        let plan = EditPlan(clips: [clip(speed: .flat(99)), clip(5...1)])
        XCTAssertEqual(validator.validate(plan).count, 2)
    }

    func testAssetExistence() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! Data().write(to: dir.appendingPathComponent("exists.mp4"))
        let resolver = AssetResolver(directory: dir)
        let plan = EditPlan(clips: [clip(source: "exists.mp4"), clip(source: "missing.mp4")])
        let issues = validator.validateAssets(plan, resolver: resolver)
        XCTAssertEqual(issues.map(\.path), ["clips[1].source"])
    }
}
```

- [x] **Step 2: 跑测试确认失败**

Run: `cd KadrPOC && swift test --filter EditPlanValidatorTests`
Expected: 编译失败。

- [x] **Step 3: 实现 EditPlanValidator.swift**

```swift
import Foundation

/// 校验问题：path 指向 JSON 字段路径（如 "clips[1].speed"），Agent/人都可读。
public struct ValidationIssue: Equatable, Sendable, CustomStringConvertible {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    public var description: String { "\(path): \(message)" }
}

/// 结构校验（纯函数，无 IO）与素材存在性校验（有 IO）分离：
/// EditStore.apply 只跑前者；CLI validate / 导出前两者都跑。
public struct EditPlanValidator: Sendable {

    public static let speedRange: ClosedRange<Double> = 0.25...4.0

    public init() {}

    public func validate(_ plan: EditPlan) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        if plan.clips.isEmpty {
            issues.append(ValidationIssue(path: "clips", message: "至少需要一个片段"))
        }

        for (i, clip) in plan.clips.enumerated() {
            if clip.range.lowerBound < 0 {
                issues.append(ValidationIssue(path: "clips[\(i)].range", message: "裁剪起点不能为负"))
            } else if clip.range.upperBound <= clip.range.lowerBound {
                issues.append(ValidationIssue(path: "clips[\(i)].range", message: "裁剪区间不能为空"))
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
                let thisDuration = clip.range.upperBound - clip.range.lowerBound
                let next = plan.clips[i + 1]
                let nextDuration = next.range.upperBound - next.range.lowerBound
                if transition.duration > min(thisDuration, nextDuration) {
                    issues.append(ValidationIssue(path: "clips[\(i)].transitionAfter", message: "转场时长不能超过相邻片段时长"))
                }
            }
        }

        if let captions = plan.captions, captions.isEnabled,
           !captions.source.fileName.lowercased().hasSuffix(".srt") {
            issues.append(ValidationIssue(path: "captions.source", message: "POC 仅支持 SRT 字幕文件"))
        }

        return issues
    }

    public func validateAssets(_ plan: EditPlan, resolver: AssetResolver) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        for (i, clip) in plan.clips.enumerated() where !resolver.exists(clip.source) {
            issues.append(ValidationIssue(path: "clips[\(i)].source", message: "素材不存在: \(clip.source.fileName)"))
        }
        if let captions = plan.captions, captions.isEnabled, !resolver.exists(captions.source) {
            issues.append(ValidationIssue(path: "captions.source", message: "字幕文件不存在: \(captions.source.fileName)"))
        }
        return issues
    }
}
```

- [x] **Step 4: 跑测试确认通过**

Run: `cd KadrPOC && swift test --filter EditPlanValidatorTests`
Expected: 10 个测试全 PASS。

- [x] **Step 5: Commit**

```bash
git add KadrPOC/Sources/POCCore/EditPlanValidator.swift KadrPOC/Tests/POCCoreTests/EditPlanValidatorTests.swift
git commit -m "POCCore: EditPlanValidator（结构校验与素材存在性校验分离）"
```

---

## Task 5: UndoStack（快照撤销栈）

**Files:**
- Create: `KadrPOC/Sources/POCCore/UndoStack.swift`
- Test: `KadrPOC/Tests/POCCoreTests/UndoStackTests.swift`

- [x] **Step 1: 写失败测试**

```swift
import XCTest
@testable import POCCore

final class UndoStackTests: XCTestCase {

    private func plan(_ marker: String) -> EditPlan {
        EditPlan(clips: [PlanClip(source: MediaRef(fileName: marker), range: 0...1)])
    }

    func testInitialState() {
        let stack = UndoStack(initial: plan("a"))
        XCTAssertEqual(stack.current, plan("a"))
        XCTAssertFalse(stack.canUndo)
        XCTAssertFalse(stack.canRedo)
    }

    func testPushAdvancesCurrent() {
        var stack = UndoStack(initial: plan("a"))
        stack.push(plan("b"))
        XCTAssertEqual(stack.current, plan("b"))
        XCTAssertTrue(stack.canUndo)
        XCTAssertEqual(stack.snapshots.count, 2)
    }

    func testUndoRedo() {
        var stack = UndoStack(initial: plan("a"))
        stack.push(plan("b"))
        XCTAssertEqual(stack.undo(), plan("a"))
        XCTAssertTrue(stack.canRedo)
        XCTAssertEqual(stack.redo(), plan("b"))
        XCTAssertFalse(stack.canRedo)
    }

    func testUndoAtStartReturnsNil() {
        var stack = UndoStack(initial: plan("a"))
        XCTAssertNil(stack.undo())
        XCTAssertEqual(stack.current, plan("a"))
    }

    func testPushTruncatesRedoBranch() {
        var stack = UndoStack(initial: plan("a"))
        stack.push(plan("b"))
        stack.push(plan("c"))
        stack.undo()                       // 回到 b
        stack.push(plan("d"))              // c 被截断
        XCTAssertEqual(stack.snapshots, [plan("a"), plan("b"), plan("d")])
        XCTAssertFalse(stack.canRedo)
    }

    func testLimitEvictsOldest() {
        var stack = UndoStack(initial: plan("s0"), limit: 3)
        for i in 1...4 { stack.push(plan("s\(i)")) }
        XCTAssertEqual(stack.snapshots.count, 3)
        XCTAssertEqual(stack.snapshots.first, plan("s2"))   // s0、s1 被淘汰
        XCTAssertEqual(stack.current, plan("s4"))
        XCTAssertTrue(stack.canUndo)
    }

    func testDefaultLimitIs100() {
        let stack = UndoStack(initial: plan("a"))
        XCTAssertEqual(stack.limit, 100)
    }
}
```

- [x] **Step 2: 跑测试确认失败**

Run: `cd KadrPOC && swift test --filter UndoStackTests`
Expected: 编译失败。

- [x] **Step 3: 实现 UndoStack.swift**

```swift
import Foundation

/// 整树快照撤销栈。Swift 值类型 + Copy-on-Write 使快照近乎零成本，
/// POC 不做增量快照与命令合并（YAGNI）。
public struct UndoStack: Equatable, Sendable {
    public private(set) var snapshots: [EditPlan]
    public private(set) var index: Int
    public let limit: Int

    public init(initial: EditPlan, limit: Int = 100) {
        self.snapshots = [initial]
        self.index = 0
        self.limit = limit
    }

    public var current: EditPlan { snapshots[index] }
    public var canUndo: Bool { index > 0 }
    public var canRedo: Bool { index < snapshots.count - 1 }

    /// push 语义：截断 index 之后的 redo 分支，再追加；超出 limit 淘汰最旧。
    public mutating func push(_ snapshot: EditPlan) {
        snapshots = Array(snapshots[...index])
        snapshots.append(snapshot)
        if snapshots.count > limit {
            snapshots.removeFirst(snapshots.count - limit)
        }
        index = snapshots.count - 1
    }

    @discardableResult
    public mutating func undo() -> EditPlan? {
        guard canUndo else { return nil }
        index -= 1
        return current
    }

    @discardableResult
    public mutating func redo() -> EditPlan? {
        guard canRedo else { return nil }
        index += 1
        return current
    }
}
```

- [x] **Step 4: 跑测试确认通过**

Run: `cd KadrPOC && swift test --filter UndoStackTests`
Expected: 7 个测试全 PASS。

- [x] **Step 5: Commit**

```bash
git add KadrPOC/Sources/POCCore/UndoStack.swift KadrPOC/Tests/POCCoreTests/UndoStackTests.swift
git commit -m "POCCore: UndoStack 整树快照撤销栈"
```

---

## Task 6: EditStore

**Files:**
- Create: `KadrPOC/Sources/POCCore/EditStore.swift`
- Test: `KadrPOC/Tests/POCCoreTests/EditStoreTests.swift`

- [x] **Step 1: 写失败测试**

```swift
import XCTest
@testable import POCCore

final class EditStoreTests: XCTestCase {

    private func initialPlan() -> EditPlan {
        EditPlan(clips: [PlanClip(source: MediaRef(fileName: "clip1.mp4"), range: 0...3)])
    }

    func testApplyValidMutationPushesSnapshot() {
        let store = EditStore(initial: initialPlan())
        let result = store.apply { $0.clips[0].speed = .flat(0.5) }
        guard case .success = result else { return XCTFail("应成功") }
        XCTAssertEqual(store.plan.clips[0].speed, .flat(0.5))
        XCTAssertTrue(store.canUndo)
    }

    func testApplyInvalidMutationIsTransactional() {
        let store = EditStore(initial: initialPlan())
        let result = store.apply { $0.clips[0].speed = .flat(99) }
        guard case .failure(let issues) = result else { return XCTFail("应失败") }
        XCTAssertEqual(issues.map(\.path), ["clips[0].speed"])
        // 事务语义：失败 = 什么都没发生
        XCTAssertEqual(store.plan, initialPlan())
        XCTAssertFalse(store.canUndo)
    }

    func testUndoRedoRestoresPlan() {
        let store = EditStore(initial: initialPlan())
        store.apply { $0.clips[0].speed = .flat(0.5) }
        store.undo()
        XCTAssertEqual(store.plan, initialPlan())
        store.redo()
        XCTAssertEqual(store.plan.clips[0].speed, .flat(0.5))
    }

    func testJSONRoundTrip() throws {
        let store = EditStore(initial: initialPlan())
        let json = try store.json()
        let decoded = try JSONDecoder().decode(EditPlan.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, initialPlan())
    }
}
```

- [x] **Step 2: 跑测试确认失败**

Run: `cd KadrPOC && swift test --filter EditStoreTests`
Expected: 编译失败。

- [x] **Step 3: 实现 EditStore.swift**

```swift
import Foundation

/// 编辑状态层入口：持有当前快照，所有编辑操作 = 产出新快照压栈。
/// 校验失败 = 不产出新快照 = 栈不变（快照模型天然是事务语义）。
@Observable
public final class EditStore {
    public private(set) var plan: EditPlan
    private var undoStack: UndoStack
    private let validator = EditPlanValidator()

    public init(initial: EditPlan) {
        self.plan = initial
        self.undoStack = UndoStack(initial: initial)
    }

    public var canUndo: Bool { undoStack.canUndo }
    public var canRedo: Bool { undoStack.canRedo }
    public var historyCount: Int { undoStack.snapshots.count }

    @discardableResult
    public func apply(_ mutate: (inout EditPlan) -> Void) -> Result<EditPlan, [ValidationIssue]> {
        var next = plan
        mutate(&next)
        let issues = validator.validate(next)
        guard issues.isEmpty else { return .failure(issues) }
        undoStack.push(next)
        plan = next
        return .success(next)
    }

    public func undo() {
        if let restored = undoStack.undo() { plan = restored }
    }

    public func redo() {
        if let restored = undoStack.redo() { plan = restored }
    }

    /// 与 CLI `sample` 子命令、Agent 契约同一份序列化格式。
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(plan), as: UTF8.self)
    }
}
```

- [x] **Step 4: 跑测试确认通过**

Run: `cd KadrPOC && swift test --filter EditStoreTests`
Expected: 4 个测试全 PASS。

- [x] **Step 5: Commit**

```bash
git add KadrPOC/Sources/POCCore/EditStore.swift KadrPOC/Tests/POCCoreTests/EditStoreTests.swift
git commit -m "POCCore: EditStore（@Observable + 事务式 apply）"
```

---

## Task 7: AssetSynthesizer + SamplePlan

**Files:**
- Create: `KadrPOC/Sources/POCCore/AssetSynthesizer.swift`
- Create: `KadrPOC/Sources/POCCore/SamplePlan.swift`
- Test: `KadrPOC/Tests/POCCoreTests/SamplePlanTests.swift`
- Create: `KadrPOC/Tests/POCCoreTests/Fixtures/SamplePlan.golden.json`

- [x] **Step 1: 写失败测试**

```swift
import XCTest
@testable import POCCore

final class SamplePlanTests: XCTestCase {

    /// 黄金契约：Agent 手写/LLM 生成的 JSON 必须能解码为与 SamplePlan.make() 完全相等的模型。
    /// 方向是 外部 JSON → 模型，这正是 Agent 场景的消费方向。
    func testGoldenJSONDecodesToSamplePlan() throws {
        let fixtureURL = Bundle.module.url(forResource: "SamplePlan.golden", withExtension: "json", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: fixtureURL)
        let decoded = try JSONDecoder().decode(EditPlan.self, from: data)
        XCTAssertEqual(decoded, SamplePlan.make())
    }

    func testSamplePlanIsValid() {
        XCTAssertTrue(EditPlanValidator().validate(SamplePlan.make()).isEmpty)
    }

    func testSynthesizeProducesAssets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resolver = try AssetSynthesizer.synthesize(into: dir)
        for name in AssetSynthesizer.clipFileNames {
            XCTAssertTrue(resolver.exists(MediaRef(fileName: name)), "\(name) 应已生成")
        }
        XCTAssertTrue(resolver.exists(MediaRef(fileName: AssetSynthesizer.srtFileName)))
        // 生成后素材存在性校验应通过
        XCTAssertTrue(EditPlanValidator().validateAssets(SamplePlan.make(), resolver: resolver).isEmpty)
    }
}
```

- [x] **Step 2: 创建黄金 JSON fixture**

`KadrPOC/Tests/POCCoreTests/Fixtures/SamplePlan.golden.json`（注意 Codable 派生格式：无标签关联值用 `_0`，ClosedRange 用 lowerBound/upperBound）：

```json
{
  "version": 1,
  "preset": "reelsAndShorts",
  "clips": [
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "source": { "fileName": "clip1.mp4" },
      "range": { "lowerBound": 0, "upperBound": 3 },
      "speed": { "flat": { "_0": 1.0 } },
      "transitionAfter": { "dissolve": { "duration": 0.5 } }
    },
    {
      "id": "22222222-2222-2222-2222-222222222222",
      "source": { "fileName": "clip2.mp4" },
      "range": { "lowerBound": 0, "upperBound": 3 },
      "speed": { "flat": { "_0": 0.5 } },
      "transitionAfter": null
    },
    {
      "id": "33333333-3333-3333-3333-333333333333",
      "source": { "fileName": "clip3.mp4" },
      "range": { "lowerBound": 0, "upperBound": 2 },
      "speed": { "flat": { "_0": 2.0 } },
      "transitionAfter": null
    }
  ],
  "captions": {
    "source": { "fileName": "sample.srt" },
    "isEnabled": true,
    "style": { "fontSize": 48, "isBold": true }
  }
}
```

- [x] **Step 3: 跑测试确认失败**

Run: `cd KadrPOC && swift test --filter SamplePlanTests`
Expected: 编译失败（`SamplePlan`/`AssetSynthesizer` 未定义）。

- [x] **Step 4: 实现 SamplePlan.swift**

```swift
import Foundation

/// 内置演示工程：三段素材 + 转场 + 变速 + 字幕，覆盖 POC 五个关键字。
/// 固定 UUID 保证黄金 JSON 契约可比对。
public enum SamplePlan {
    public static func make() -> EditPlan {
        EditPlan(
            clips: [
                PlanClip(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                         source: MediaRef(fileName: "clip1.mp4"),
                         range: 0...3, speed: .flat(1.0),
                         transitionAfter: .dissolve(duration: 0.5)),
                PlanClip(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                         source: MediaRef(fileName: "clip2.mp4"),
                         range: 0...3, speed: .flat(0.5),
                         transitionAfter: nil),
                PlanClip(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                         source: MediaRef(fileName: "clip3.mp4"),
                         range: 0...2, speed: .flat(2.0),
                         transitionAfter: nil),
            ],
            captions: CaptionTrack(source: MediaRef(fileName: "sample.srt"),
                                   isEnabled: true,
                                   style: CaptionStyle(fontSize: 48, isBold: true)),
            preset: .reelsAndShorts
        )
    }

    /// CLI `sample` 子命令的输出，与 EditStore.json() 同一格式。
    public static func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(SamplePlan.make()), as: UTF8.self)
    }
}
```

- [x] **Step 5: 实现 AssetSynthesizer.swift**

```swift
import AVFoundation
import CoreGraphics

/// 用 AVAssetWriter 合成确定性测试素材：三段 4 秒纯色 720p 视频 + 一份 SRT。
/// 无二进制资产进 git，CI/真机/CLI 随时可再生成。幂等：已存在则跳过。
public enum AssetSynthesizer {

    public static let clipFileNames = ["clip1.mp4", "clip2.mp4", "clip3.mp4"]
    public static let srtFileName = "sample.srt"

    /// SRT 时间轴按 sample 工程的合成时间轴编写（clip1 3s@1x + 转场 0.5s + clip2 3s@0.5x=6s + clip3 2s@2x=1s）。
    static let srtContent = """
    1
    00:00:00,000 --> 00:00:02,500
    第一段：开场

    2
    00:00:03,000 --> 00:00:07,500
    第二段：慢动作

    3
    00:00:08,000 --> 00:00:09,000
    第三段：收尾

    """

    @discardableResult
    public static func synthesize(into directory: URL) throws -> AssetResolver {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let colors: [CGColor] = [
            CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1),
            CGColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1),
            CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1),
        ]
        for (i, name) in clipFileNames.enumerated() {
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try writeSolidColorVideo(to: url, color: colors[i], seconds: 4)
            }
        }
        let srtURL = directory.appendingPathComponent(srtFileName)
        if !FileManager.default.fileExists(atPath: srtURL.path) {
            try srtContent.write(to: srtURL, atomically: true, encoding: .utf8)
        }
        return AssetResolver(directory: directory)
    }

    private static func writeSolidColorVideo(to url: URL, color: CGColor, seconds: Double) throws {
        let width = 1280, height = 720, fps: Int32 = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int(seconds * Double(fps))
        for frame in 0..<totalFrames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            let buffer = try makePixelBuffer(pool: adaptor.pixelBufferPool!, width: width, height: height, color: color)
            let time = CMTime(value: CMTimeValue(frame), timescale: fps)
            guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error! }
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status != .failed else { throw writer.error! }
    }

    private static func makePixelBuffer(pool: CVPixelBufferPool, width: Int, height: Int, color: CGColor) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw NSError(domain: "AssetSynthesizer", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法分配像素缓冲"]) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
```

注意：`synthesize(into:)` 直接返回 `AssetResolver`（比另造 SampleAssets 类型更省一层，调用方拿到的正是后续所有 API 需要的东西）。

- [x] **Step 6: 跑测试确认通过**

Run: `cd KadrPOC && swift test --filter SamplePlanTests`
Expected: 3 个测试全 PASS（素材合成约需数秒）。

- [x] **Step 7: Commit**

```bash
git add KadrPOC/Sources/POCCore/AssetSynthesizer.swift KadrPOC/Sources/POCCore/SamplePlan.swift KadrPOC/Tests/POCCoreTests/SamplePlanTests.swift KadrPOC/Tests/POCCoreTests/Fixtures
git commit -m "POCCore: AssetSynthesizer 测试素材合成器 + SamplePlan 黄金 JSON 契约"
```

---

## Task 8: EngineBridge（EditPlan → Kadr DSL）

**Files:**
- Create: `KadrPOC/Sources/POCCore/EngineBridge.swift`
- Test: `KadrPOC/Tests/POCCoreTests/EngineBridgeTests.swift`

- [x] **Step 1: 写失败测试**

```swift
import XCTest
import CoreMedia
import Kadr
@testable import POCCore

final class EngineBridgeTests: XCTestCase {

    private var resolver: AssetResolver!

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        resolver = try AssetSynthesizer.synthesize(into: dir)
    }

    func testSamplePlanStructure() async throws {
        let video = try await EngineBridge.makeComposition(from: SamplePlan.make(), resolver: resolver)
        // 3 个 PlanClip + 1 个转场 = 4 个时间线元素，转场在第 2 位
        XCTAssertEqual(video.clips.count, 4)
        XCTAssertTrue(video.clips[0] is Kadr.VideoClip)
        XCTAssertTrue(video.clips[1] is Kadr.Transition)
        XCTAssertTrue(video.clips[2] is Kadr.VideoClip)
        XCTAssertTrue(video.clips[3] is Kadr.VideoClip)
        // 字幕：3 条 cue → 软字幕 3 条 + 烧录 overlay 3 个
        XCTAssertEqual(video.captions.count, 3)
        XCTAssertEqual(video.overlays.count, 3)
        // duration = 3(clip1@1x) + 0.5(转场) + 6(clip2@0.5x) + 1(clip3@2x) = 10.5
        // （Kadr Video.duration 为各 Clip.duration 之和，转场时长计入）
        XCTAssertEqual(CMTimeGetSeconds(video.duration), 10.5, accuracy: 0.01)
    }

    func testCaptionsDisabledProducesNoOverlays() async throws {
        var plan = SamplePlan.make()
        plan.captions?.isEnabled = false
        let video = try await EngineBridge.makeComposition(from: plan, resolver: resolver)
        XCTAssertEqual(video.captions.count, 0)
        XCTAssertEqual(video.overlays.count, 0)
    }

    func testTransitionMapping() {
        XCTAssertEqual(EngineBridge.kadrTransition(.dissolve(duration: 0.5)),
                       Kadr.Transition.dissolve(duration: 0.5))
        XCTAssertEqual(EngineBridge.kadrTransition(.fade(duration: 0.3)),
                       Kadr.Transition.fade(duration: 0.3))
    }

    func testSingleClipNoTransition() async throws {
        let plan = EditPlan(clips: [PlanClip(source: MediaRef(fileName: "clip1.mp4"), range: 0...3)])
        let video = try await EngineBridge.makeComposition(from: plan, resolver: resolver)
        XCTAssertEqual(video.clips.count, 1)
        XCTAssertEqual(CMTimeGetSeconds(video.duration), 3.0, accuracy: 0.01)
    }
}
```

- [x] **Step 2: 跑测试确认失败**

Run: `cd KadrPOC && swift test --filter EngineBridgeTests`
Expected: 编译失败（`EngineBridge` 未定义）。

- [x] **Step 3: 实现 EngineBridge.swift**

```swift
import Foundation
import CoreMedia
import Kadr
import KadrCaptions

/// EditPlan → Kadr DSL 的单向映射。预览与导出共用这一个出口。
/// 本文件是 POCCore 中唯一 import Kadr / KadrCaptions 的地方（硬边界规则 1）。
public enum EngineBridge {

    public static func makeComposition(from plan: EditPlan, resolver: AssetResolver) async throws -> Kadr.Video {
        var elements: [any Kadr.Clip] = []
        for clip in plan.clips {
            var videoClip = Kadr.VideoClip(url: resolver.resolve(clip.source))
                .trimmed(to: clip.range)
            if clip.speed.rate != 1.0 {
                videoClip = videoClip.speed(clip.speed.rate)
            }
            elements.append(videoClip)
            if let transition = clip.transitionAfter {
                elements.append(kadrTransition(transition))
            }
        }

        var video = Kadr.Video { elements }.preset(.reelsAndShorts)

        if let track = plan.captions, track.isEnabled {
            let cues = try await Kadr.Caption.load(srt: resolver.resolve(track.source))
            video = video.captions(cues)                    // 软字幕：AVMetadataItem
            for cue in cues {
                video = video.overlay(captionOverlay(cue, style: track.style))  // 烧录：TextOverlay
            }
        }
        return video
    }

    static func kadrTransition(_ transition: PlanTransition) -> Kadr.Transition {
        switch transition {
        case .dissolve(let d): return .dissolve(duration: d)
        case .fade(let d): return .fade(duration: d)
        }
    }

    static func captionOverlay(_ cue: Kadr.Caption, style: CaptionStyle) -> Kadr.TextOverlay {
        let start = cue.timeRange.start.seconds
        let end = start + cue.timeRange.duration.seconds
        return Kadr.TextOverlay(
            cue.text,
            style: Kadr.TextStyle(
                fontSize: style.fontSize,
                alignment: .center,
                weight: style.isBold ? .bold : .regular
            )
        )
        .position(.bottom)
        .anchor(.bottom)
        .visible(during: start...end)
    }
}
```

**编译期 API 校准笔记**（Kadr 真实 API 若与假设有出入，按此调整，EditPlan schema 不变）：

1. 若 `VideoClip.speed(_:)` 只接受 `Speed` 枚举而非 `Double`，改为 `videoClip = videoClip.speed(.flat(clip.speed.rate))`。
2. 若 `Kadr.Video { elements }` 对单个 `[any Clip]` 数组表达式不编译，改为 `Kadr.Video { elements.map { $0 } }`。
3. 若 Task 1 走了 SRTParser 兜底：删掉 `import KadrCaptions`，把 `Kadr.Caption.load(srt:)` 一行换成：

```swift
let srtText = try String(contentsOf: resolver.resolve(track.source), encoding: .utf8)
let cues = SRTParser.parse(srtText).map {
    Kadr.Caption(text: $0.text, timeRange: CMTimeRange(
        start: CMTime(seconds: $0.start, preferredTimescale: 600),
        duration: CMTime(seconds: $0.end - $0.start, preferredTimescale: 600)))
}
```

- [x] **Step 4: 跑测试确认通过**

Run: `cd KadrPOC && swift test --filter EngineBridgeTests`
Expected: 4 个测试全 PASS。若 `video.duration` 断言失败且偏差恰好是转场时长，说明该 Kadr 版本的 duration 语义变化——以实际导出时长为准调整断言，并在 POC 结论中记录。

- [x] **Step 5: Commit**

```bash
git add KadrPOC/Sources/POCCore/EngineBridge.swift KadrPOC/Tests/POCCoreTests/EngineBridgeTests.swift
git commit -m "POCCore: EngineBridge（EditPlan → Kadr DSL 单向映射，字幕软/烧录双通道）"
```

---

## Task 9: PreviewBridge + CaptionCue

**Files:**
- Create: `KadrPOC/Sources/POCCore/PreviewBridge.swift`

本任务无可单测逻辑（产物是 AVPlayerItem，验证在 Task 13 真机/模拟器进行），直接实现后编译验证。

- [x] **Step 1: 实现 PreviewBridge.swift**

```swift
import AVFoundation
import Kadr

/// UI 中立的字幕 cue（表现层不 import Kadr，故不能暴露 Kadr.Caption）。
public struct CaptionCue: Equatable, Sendable {
    public let text: String
    public let range: ClosedRange<TimeInterval>

    public init(text: String, range: ClosedRange<TimeInterval>) {
        self.text = text
        self.range = range
    }
}

/// 预览包：AVPlayerItem + 字幕 cue 列表。
/// 注意：Kadr 的 overlay（烧录字幕）不进入预览（AVFoundation 限制，export-only），
/// 表现层需用 SwiftUI 原生叠加层按播放器时间显示 cues。
public struct PreviewPackage {
    public let playerItem: AVPlayerItem
    public let cues: [CaptionCue]
}

public enum PreviewBridge {

    @MainActor
    public static func makePreview(for plan: EditPlan, resolver: AssetResolver) async throws -> PreviewPackage {
        let video = try await EngineBridge.makeComposition(from: plan, resolver: resolver)
        let item = try await video.makePlayerItem()
        let cues = video.captions.map {
            CaptionCue(text: $0.text,
                       range: $0.timeRange.start.seconds...($0.timeRange.start.seconds + $0.timeRange.duration.seconds))
        }
        return PreviewPackage(playerItem: item, cues: cues)
    }
}
```

- [x] **Step 2: 编译验证**

Run: `cd KadrPOC && swift build`
Expected: `Build complete!`

- [x] **Step 3: Commit**

```bash
git add KadrPOC/Sources/POCCore/PreviewBridge.swift
git commit -m "POCCore: PreviewBridge + CaptionCue（预览桥接，字幕 cue UI 中立化）"
```

---

## Task 10: ExportRunner + PlanLoader

**Files:**
- Create: `KadrPOC/Sources/POCCore/ExportRunner.swift`
- Create: `KadrPOC/Sources/POCCore/PlanLoader.swift`
- Test: `KadrPOC/Tests/POCCoreTests/PlanLoaderTests.swift`

- [x] **Step 1: 写 PlanLoader 失败测试**

```swift
import XCTest
@testable import POCCore

final class PlanLoaderTests: XCTestCase {

    private func writeTemp(_ content: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testLoadsValidPlan() throws {
        let url = writeTemp(#"{"version":1,"clips":[{"id":"11111111-1111-1111-1111-111111111111","source":{"fileName":"a.mp4"},"range":{"lowerBound":0,"upperBound":3},"speed":{"flat":{"_0":1.0}},"transitionAfter":null}],"captions":null,"preset":"reelsAndShorts"}"#)
        let plan = try PlanLoader.load(from: url)
        XCTAssertEqual(plan.clips.count, 1)
        XCTAssertEqual(plan.clips[0].source.fileName, "a.mp4")
    }

    func testTypeMismatchReportsFieldPath() throws {
        let url = writeTemp(#"{"version":1,"clips":[{"id":"11111111-1111-1111-1111-111111111111","source":{"fileName":"a.mp4"},"range":{"lowerBound":0,"upperBound":3},"speed":{"flat":{"_0":"fast"}},"transitionAfter":null}],"captions":null,"preset":"reelsAndShorts"}"#)
        XCTAssertThrowsError(try PlanLoader.load(from: url)) { error in
            guard case let PlanLoaderError.decodingFailed(path, _) = error else {
                return XCTFail("应为 decodingFailed，实际 \(error)")
            }
            XCTAssertTrue(path.contains("clips[0].speed"), "路径应指到出错字段，实际: \(path)")
        }
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try PlanLoader.load(from: URL(fileURLWithPath: "/tmp/no-such-\(UUID().uuidString).json")))
    }

    func testGarbageJSONThrows() {
        let url = writeTemp("not json at all")
        XCTAssertThrowsError(try PlanLoader.load(from: url))
    }
}
```

- [x] **Step 2: 跑测试确认失败**

Run: `cd KadrPOC && swift test --filter PlanLoaderTests`
Expected: 编译失败。

- [x] **Step 3: 实现 PlanLoader.swift**

```swift
import Foundation

/// JSON 层错误：把 DecodingError 翻译成人/Agent 可读的字段路径。
public enum PlanLoaderError: Error, Equatable, CustomStringConvertible {
    case decodingFailed(path: String, message: String)

    public var description: String {
        switch self {
        case .decodingFailed(let path, let message): return "\(path): \(message)"
        }
    }
}

public enum PlanLoader {

    public static func load(from url: URL) throws -> EditPlan {
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(EditPlan.self, from: data)
        } catch let error as DecodingError {
            let (path, message) = describe(error)
            throw PlanLoaderError.decodingFailed(path: path, message: message)
        }
    }

    static func describe(_ error: DecodingError) -> (path: String, message: String) {
        switch error {
        case .keyNotFound(let key, let context):
            return (pathString(context.codingPath + [key]), "缺少字段 \(key.stringValue)")
        case .typeMismatch(_, let context):
            return (pathString(context.codingPath), "类型不匹配: \(context.debugDescription)")
        case .valueNotFound(_, let context):
            return (pathString(context.codingPath), "值为空: \(context.debugDescription)")
        case .dataCorrupted(let context):
            return (pathString(context.codingPath), "数据损坏: \(context.debugDescription)")
        @unknown default:
            return ("(root)", "未知解码错误")
        }
    }

    static func pathString(_ codingPath: [CodingKey]) -> String {
        var result = ""
        for key in codingPath {
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                result += result.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return result.isEmpty ? "(root)" : result
    }
}
```

- [x] **Step 4: 实现 ExportRunner.swift**

```swift
import Foundation
import Kadr

/// headless 导出的进度事件流。CLI 逐行 JSON 化输出；App 驱动进度条。
public enum ExportEvent: Sendable, Equatable {
    case progress(Double)
    case done(url: URL, durationMs: Int)
}

public enum ExportRunner {

    public static func export(plan: EditPlan, resolver: AssetResolver, to output: URL) -> AsyncThrowingStream<ExportEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let start = Date()
                    let video = try await EngineBridge.makeComposition(from: plan, resolver: resolver)
                    let exporter = video.exporter(to: output)
                    for try await progress in exporter.run() {
                        continuation.yield(.progress(progress.fractionCompleted))
                    }
                    continuation.yield(.done(url: output, durationMs: Int(Date().timeIntervalSince(start) * 1000)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

- [x] **Step 5: 跑测试确认通过 + 编译**

Run: `cd KadrPOC && swift test --filter PlanLoaderTests && swift build`
Expected: 4 个测试 PASS；`Build complete!`

- [x] **Step 6: Commit**

```bash
git add KadrPOC/Sources/POCCore/PlanLoader.swift KadrPOC/Sources/POCCore/ExportRunner.swift KadrPOC/Tests/POCCoreTests/PlanLoaderTests.swift
git commit -m "POCCore: PlanLoader（DecodingError 字段路径翻译）+ ExportRunner（进度事件流）"
```

---

## Task 11: kadrpoc-cli 四子命令

**Files:**
- Modify: `KadrPOC/Sources/kadrpoc-cli/KadrPOCCLI.swift`（整体替换占位）

- [x] **Step 1: 实现 CLI（整体替换）**

```swift
import ArgumentParser
import Foundation
import POCCore

@main
struct KadrPOCCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kadrpoc-cli",
        abstract: "Kadr POC: EditPlan JSON → DSL → headless 导出",
        subcommands: [Sample.self, Validate.self, Export.self, GenAssets.self]
    )
}

/// stdout 只走结构化数据；日志/错误走 stderr。exit code: 0 成功 / 1 JSON 解码失败 / 2 语义校验失败 / 3 引擎错误。
enum CLIError {
    static func stderr(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

struct JSONLines {
    struct ProgressLine: Encodable { let progress: Double }
    struct DoneLine: Encodable { let done: String; let durationMs: Int }

    static func print<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        print(String(decoding: data, as: UTF8.self))
    }
}

struct Sample: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "输出内置演示工程的 EditPlan JSON（Agent few-shot 样例 / schema 活文档）")

    mutating func run() async throws {
        print(try SamplePlan.json())
    }
}

struct GenAssets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "生成测试素材（3 段视频 + sample.srt）到指定目录")

    @Option(help: "素材输出目录，默认 ./Assets")
    var to: String = "./Assets"

    mutating func run() async throws {
        let resolver = try AssetSynthesizer.synthesize(into: URL(fileURLWithPath: to))
        struct Result: Encodable { let directory: String; let files: [String] }
        try JSONLines.print(Result(directory: resolver.directory.path,
                                   files: AssetSynthesizer.clipFileNames + [AssetSynthesizer.srtFileName]))
    }
}

struct Validate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "校验 EditPlan JSON（结构 + 素材存在性），不导出")

    @Argument(help: "EditPlan JSON 文件路径")
    var plan: String

    @Option(help: "素材目录，默认 ./Assets")
    var assets: String = "./Assets"

    mutating func run() async throws {
        let plan: EditPlan
        do {
            plan = try PlanLoader.load(from: URL(fileURLWithPath: self.plan))
        } catch let error as PlanLoaderError {
            CLIError.stderr("\(error)")
            throw ExitCode(1)
        }

        let resolver = AssetResolver(directory: URL(fileURLWithPath: assets))
        let issues = EditPlanValidator().validate(plan) + EditPlanValidator().validateAssets(plan, resolver: resolver)
        guard issues.isEmpty else {
            struct IssueLine: Encodable { let errors: [Issue] }
            struct Issue: Encodable { let path: String; let message: String }
            let line = IssueLine(errors: issues.map { Issue(path: $0.path, message: $0.message) })
            let data = try JSONEncoder().encode(line)
            CLIError.stderr(String(decoding: data, as: UTF8.self))
            throw ExitCode(2)
        }
        struct ValidLine: Encodable { let valid: Bool }
        try JSONLines.print(ValidLine(valid: true))
    }
}

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "完整管线：EditPlan JSON → DSL → headless 导出 mp4")

    @Argument(help: "EditPlan JSON 文件路径")
    var plan: String

    @Option(name: .shortAndLong, help: "输出 mp4 路径")
    var output: String

    @Option(help: "素材目录，默认 ./Assets")
    var assets: String = "./Assets"

    mutating func run() async throws {
        let plan: EditPlan
        do {
            plan = try PlanLoader.load(from: URL(fileURLWithPath: self.plan))
        } catch let error as PlanLoaderError {
            CLIError.stderr("\(error)")
            throw ExitCode(1)
        }

        let resolver = AssetResolver(directory: URL(fileURLWithPath: assets))
        let issues = EditPlanValidator().validate(plan) + EditPlanValidator().validateAssets(plan, resolver: resolver)
        guard issues.isEmpty else {
            for issue in issues { CLIError.stderr("\(issue)") }
            throw ExitCode(2)
        }

        do {
            for try await event in ExportRunner.export(plan: plan, resolver: resolver, to: URL(fileURLWithPath: output)) {
                switch event {
                case .progress(let fraction):
                    try JSONLines.print(JSONLines.ProgressLine(progress: (fraction * 100).rounded() / 100))
                case .done(let url, let ms):
                    try JSONLines.print(JSONLines.DoneLine(done: url.path, durationMs: ms))
                }
            }
        } catch {
            CLIError.stderr("引擎错误: \(error)")
            throw ExitCode(3)
        }
    }
}
```

- [x] **Step 2: 构建 CLI**

Run: `cd KadrPOC && swift build`
Expected: `Build complete!`

- [x] **Step 3: 冒烟测试四子命令**

```bash
cd KadrPOC
swift run kadrpoc-cli genassets --to ./Assets
swift run kadrpoc-cli sample > /tmp/poc-sample.json
swift run kadrpoc-cli validate /tmp/poc-sample.json --assets ./Assets
swift run kadrpoc-cli export /tmp/poc-sample.json -o /tmp/poc-out.mp4 --assets ./Assets
```

Expected:
- genassets 输出 `{"directory":...,"files":[...]}`
- validate 输出 `{"valid":true}`，exit 0
- export 逐行输出 `{"progress":...}`，末行 `{"done":"/tmp/poc-out.mp4","durationMs":...}`，exit 0
- `/tmp/poc-out.mp4` 存在且可播放

再验证错误路径 exit code：

```bash
echo '{"version":1}' > /tmp/bad.json && swift run kadrpoc-cli validate /tmp/bad.json; echo "exit=$?"   # 期望 exit=1
echo '{"version":1,"clips":[],"captions":null,"preset":"reelsAndShorts"}' > /tmp/empty.json && swift run kadrpoc-cli validate /tmp/empty.json; echo "exit=$?"   # 期望 exit=2
```

- [x] **Step 4: Commit**

```bash
echo "Assets/" >> KadrPOC/.gitignore
git add KadrPOC/Sources/kadrpoc-cli/KadrPOCCLI.swift KadrPOC/.gitignore
git commit -m "kadrpoc-cli: sample/validate/export/genassets 四子命令（JSONL 进度流 + 语义化 exit code）"
```

---

## Task 12: 端到端黄金测试

CLI 是 ArgumentParser 的薄壳，参数解析由框架负责；端到端测试在进程内走同一条代码路径（PlanLoader → Validator → ExportRunner），等价覆盖 CLI `export` 的引擎链路。

**Files:**
- Test: `KadrPOC/Tests/POCCoreTests/ExportEndToEndTests.swift`

- [x] **Step 1: 实现端到端测试**

```swift
import XCTest
import AVFoundation
@testable import POCCore

/// 端到端黄金测试：真实素材 → headless 导出 → AVFoundation 读回产物断言。
/// 抽帧 PNG 存入 TestArtifacts/ 供人工核对字幕烧录。
final class ExportEndToEndTests: XCTestCase {

    private var assetsDir: URL!
    private var resolver: AssetResolver!
    private var artifactsDir: URL!

    override func setUp() async throws {
        assetsDir = FileManager.default.temporaryDirectory.appendingPathComponent("kadrpoc-e2e-\(UUID().uuidString)")
        resolver = try AssetSynthesizer.synthesize(into: assetsDir)
        artifactsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // POCCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // KadrPOC
            .appendingPathComponent("TestArtifacts")
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
    }

    /// 全链路：拼接 + 转场 + 变速 + 字幕（sample 工程原样导出）。
    /// 理论时长区间 [9.0, 10.5]：clip1 3s + clip2 6s + clip3 1s，转场重叠语义待本测试实测确认。
    /// 测试通过后将实测时长记录进 POC 结论（这是 POC 的学习目标之一）。
    func testSamplePlanExport() async throws {
        let out = assetsDir.appendingPathComponent("sample-out.mp4")
        var done = false
        for try await event in ExportRunner.export(plan: SamplePlan.make(), resolver: resolver, to: out) {
            if case .done = event { done = true }
        }
        XCTAssertTrue(done)

        let asset = AVURLAsset(url: out)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        XCTAssertGreaterThanOrEqual(duration, 9.0)
        XCTAssertLessThanOrEqual(duration, 10.5)
        print("📐 sample 导出实测时长: \(duration)s（理论区间 9.0–10.5，转场重叠语义实测值）")

        let tracks = try await asset.load(.tracks)
        XCTAssertTrue(tracks.contains { $0.mediaType == .video })
        // 软字幕：metadata 组应含 description 条目
        let metadata = try await asset.load(.metadata)
        XCTAssertFalse(metadata.isEmpty, "软字幕 AVMetadataItem 应存在")

        try await extractFrames(from: out, times: [1.0, 5.0, 8.5], tag: "sample")
    }

    /// 变速专项：单段 3s @0.5x → 产物时长 ≈ 6s。
    func testSpeedDoublesDuration() async throws {
        let plan = EditPlan(clips: [PlanClip(source: MediaRef(fileName: "clip2.mp4"), range: 0...3, speed: .flat(0.5))])
        let out = assetsDir.appendingPathComponent("speed-out.mp4")
        for try await _ in ExportRunner.export(plan: plan, resolver: resolver, to: out) {}
        let duration = CMTimeGetSeconds(try await AVURLAsset(url: out).load(.duration))
        XCTAssertEqual(duration, 6.0, accuracy: 0.3)
    }

    /// 拼接专项：clip1 3s@1x + clip3 2s@1x，无转场 → ≈ 5s。
    func testSpliceDuration() async throws {
        let plan = EditPlan(clips: [
            PlanClip(source: MediaRef(fileName: "clip1.mp4"), range: 0...3, speed: .flat(1.0)),
            PlanClip(source: MediaRef(fileName: "clip3.mp4"), range: 0...2, speed: .flat(1.0)),
        ])
        let out = assetsDir.appendingPathComponent("splice-out.mp4")
        for try await _ in ExportRunner.export(plan: plan, resolver: resolver, to: out) {}
        let duration = CMTimeGetSeconds(try await AVURLAsset(url: out).load(.duration))
        XCTAssertEqual(duration, 5.0, accuracy: 0.3)
    }

    /// 抽帧存 PNG：人工核对字幕是否烧录进画面（元数据无法断言烧录）。
    private func extractFrames(from url: URL, times: [TimeInterval], tag: String) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for time in times {
            let cgImage = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let rep = NSBitmapImageRep(cgImage: cgImage)
            let png = rep.representation(using: .png, properties: [:])!
            let out = artifactsDir.appendingPathComponent("\(tag)-\(time)s.png")
            try png.write(to: out)
            print("🖼 抽帧已保存: \(out.path)（人工核对字幕烧录）")
        }
    }
}
```

注意：`NSBitmapImageRep` 是 AppKit API，测试只跑在 macOS 上（`swift test` 的默认宿主），无需跨平台条件编译。

- [x] **Step 2: 跑端到端测试**

Run: `cd KadrPOC && swift test --filter ExportEndToEndTests`
Expected: 3 个测试全 PASS（导出耗时数十秒属正常）。`TestArtifacts/` 下出现 3 张抽帧 PNG。

- [x] **Step 3: 人工核对抽帧**

打开 `KadrPOC/TestArtifacts/sample-*.png`，确认三张帧画面底部可见中文字幕。若不可见：检查 EngineBridge 的 `captionOverlay` 是否生效（`.visible(during:)` 时间轴与 SRT cue 是否对齐），勿直接放过。

- [x] **Step 4: 全量测试回归**

Run: `cd KadrPOC && swift test`
Expected: 全部测试 PASS。

- [x] **Step 5: Commit**

```bash
git add KadrPOC/Tests/POCCoreTests/ExportEndToEndTests.swift
git commit -m "POCCore: 端到端黄金测试（拼接/变速/全链路时长断言 + 字幕抽帧）"
```

---

## Task 13: App 壳（iOS 表现层）

**Files:**
- Create: `App/JangyPOC.xcodeproj`（Xcode GUI 创建）
- Create: `App/JangyPOC/JangyPOCApp.swift`
- Create: `App/JangyPOC/AppModel.swift`
- Create: `App/JangyPOC/ContentView.swift`
- Create: `App/JangyPOC/PreviewView.swift`
- Create: `App/JangyPOC/TimelineView.swift`

- [x] **Step 1: Xcode 创建工程（手动 GUI 步骤）**

1. Xcode → Create New Project → iOS → App
2. Product Name: `JangyPOC`；Interface: SwiftUI；Language: Swift；Storage: None；**取消勾选** Include Tests（POC 测试全在 SwiftPM 侧）
3. 保存位置选择仓库根目录下的 `App/`，使工程落在 `App/JangyPOC.xcodeproj`；取消勾选 Create Git repository
4. 选中 JangyPOC target → General → Minimum Deployments → **iOS 17.0**
5. 项目导航器选中根工程 → File → Add Package Dependencies… → 左下角 Add Local… → 选择仓库的 `KadrPOC` 目录 → Add Package；JangyPOC target → Frameworks and Libraries → 确认 `POCCore` 已链接
6. ⌘B 编译通过（此时工程还是模板代码）

- [x] **Step 2: 替换 JangyPOCApp.swift**

```swift
import SwiftUI
import POCCore

@main
struct JangyPOCApp: App {
    @State private var model: AppModel

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JangyPOC", isDirectory: true)
        do {
            let resolver = try AssetSynthesizer.synthesize(into: support)
            let store = EditStore(initial: SamplePlan.make())
            _model = State(initialValue: AppModel(store: store, resolver: resolver))
        } catch {
            preconditionFailure("测试素材合成失败: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
```

- [x] **Step 3: 创建 AppModel.swift**

```swift
import Foundation
import Observation
import POCCore

/// App 侧状态装配：EditStore（编辑状态层）+ PlayerController（预览）+ 导出进度。
/// 所有编辑经 edit() 进入 EditStore.apply —— 校验失败不压栈，撤销栈纹丝不动。
@MainActor
@Observable
final class AppModel {
    let store: EditStore
    let resolver: AssetResolver
    let player: PlayerController

    var exportProgress: Double?
    var exportMessage: String?
    var lastIssues: [ValidationIssue]?

    init(store: EditStore, resolver: AssetResolver) {
        self.store = store
        self.resolver = resolver
        self.player = PlayerController(store: store, resolver: resolver)
    }

    func edit(_ mutate: (inout EditPlan) -> Void) {
        switch store.apply(mutate) {
        case .success:
            lastIssues = nil
            player.rebuild()
        case .failure(let issues):
            lastIssues = issues
        }
    }

    func undo() { store.undo(); player.rebuild() }
    func redo() { store.redo(); player.rebuild() }

    func export() {
        exportProgress = 0
        exportMessage = nil
        let out = resolver.directory.appendingPathComponent("poc-export-\(Int(Date().timeIntervalSince1970)).mp4")
        Task {
            do {
                for try await event in ExportRunner.export(plan: store.plan, resolver: resolver, to: out) {
                    switch event {
                    case .progress(let fraction):
                        exportProgress = fraction
                    case .done(let url, let ms):
                        exportProgress = nil
                        exportMessage = "已导出 \(url.lastPathComponent)（\(ms)ms）\n路径: \(url.path)"
                    }
                }
            } catch {
                exportProgress = nil
                exportMessage = "导出失败: \(error.localizedDescription)"
            }
        }
    }
}
```

- [x] **Step 4: 创建 PlayerController（并入 AppModel.swift 同一文件）**

```swift
import AVFoundation
import POCCore

/// 预览播放器：plan 变化 → PreviewBridge 重建 playerItem；周期性时间观察驱动字幕叠加层。
@MainActor
@Observable
final class PlayerController {
    private(set) var player: AVPlayer?
    private(set) var currentTime: TimeInterval = 0
    private(set) var cues: [CaptionCue] = []

    private var timeObserver: Any?
    private var rebuildTask: Task<Void, Never>?
    private let store: EditStore
    private let resolver: AssetResolver

    init(store: EditStore, resolver: AssetResolver) {
        self.store = store
        self.resolver = resolver
        rebuild()
    }

    func rebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            guard let package = try? await PreviewBridge.makePreview(for: store.plan, resolver: resolver) else { return }
            if let old = player, let observer = timeObserver { old.removeTimeObserver(observer) }
            let newPlayer = AVPlayer(playerItem: package.playerItem)
            timeObserver = newPlayer.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated { self?.currentTime = time.seconds }
            }
            player = newPlayer
            cues = package.cues
            newPlayer.play()
        }
    }

    var currentCue: CaptionCue? {
        cues.first { $0.range.contains(currentTime) }
    }
}
```

- [x] **Step 5: 替换 ContentView.swift**

```swift
import SwiftUI
import POCCore

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PreviewView(player: model.player)

            // 操作条：撤销/重做 + 字幕开关 + 追加片段 + 导出
            HStack {
                Button("撤销") { model.undo() }.disabled(!model.store.canUndo)
                Button("重做") { model.redo() }.disabled(!model.store.canRedo)
                Spacer()
                Button(model.store.plan.captions?.isEnabled == true ? "字幕：开" : "字幕：关") {
                    model.edit { $0.captions?.isEnabled.toggle() }
                }
                Button("追加片段") {
                    model.edit {
                        $0.clips.append(PlanClip(source: MediaRef(fileName: "clip1.mp4"), range: 0...2))
                    }
                }
                Button("导出") { model.export() }
                    .disabled(model.exportProgress != nil)
            }
            .padding(.horizontal)

            if let progress = model.exportProgress {
                ProgressView(value: progress).padding(.horizontal)
            }
            if let message = model.exportMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            if let issues = model.lastIssues {
                Text(issues.map(\.description).joined(separator: "\n"))
                    .font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            TimelineView(model: model)
        }
    }
}
```

- [x] **Step 6: 创建 PreviewView.swift**

```swift
import AVKit
import SwiftUI

/// 预览：VideoPlayer + SwiftUI 字幕叠加层。
/// Kadr overlay（烧录字幕）不进入预览（AVFoundation 限制），故用原生 Text 按播放时间叠加。
struct PreviewView: View {
    let player: PlayerController

    var body: some View {
        ZStack(alignment: .bottom) {
            if let avPlayer = player.player {
                VideoPlayer(player: avPlayer)
            } else {
                Color.black.overlay(Text("加载预览…").foregroundStyle(.white))
            }
            if let cue = player.currentCue {
                Text(cue.text)
                    .font(.title2).bold()
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 8))
                    .foregroundStyle(.white)
                    .padding(.bottom, 40)
            }
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 12))
        .padding()
    }
}
```

- [x] **Step 7: 创建 TimelineView.swift**

```swift
import SwiftUI
import POCCore

/// 时间线：每行一个片段，提供 POC 五类操作中的四类（裁剪/变速/转场/删除）。
struct TimelineView: View {
    let model: AppModel

    var body: some View {
        List {
            ForEach(Array(model.store.plan.clips.enumerated()), id: \.element.id) { index, clip in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(index + 1). \(clip.source.fileName)  [\(clip.range.lowerBound, format: .number.precision(.fractionLength(1)))–\(clip.range.upperBound, format: .number.precision(.fractionLength(1)))s]  \(clip.speed.rate, format: .number.precision(.fractionLength(2)))x")
                        .font(.callout)
                    HStack {
                        Button("裁剪") { toggleTrim(index) }
                        Button("变速") { cycleSpeed(index) }
                        if index < model.store.plan.clips.count - 1 {
                            Button(clip.transitionAfter == nil ? "加转场" : "去转场") { toggleTransition(index) }
                        }
                        Button("删除", role: .destructive) { delete(index) }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func toggleTrim(_ index: Int) {
        model.edit {
            let clip = $0.clips[index]
            $0.clips[index].range = clip.range.lowerBound == 0 ? 0.5...2.5 : 0...3
        }
    }

    private func cycleSpeed(_ index: Int) {
        model.edit {
            let current = $0.clips[index].speed.rate
            let next: Double = current == 1.0 ? 0.5 : (current == 0.5 ? 2.0 : 1.0)
            $0.clips[index].speed = .flat(next)
        }
    }

    private func toggleTransition(_ index: Int) {
        model.edit {
            $0.clips[index].transitionAfter = $0.clips[index].transitionAfter == nil ? .dissolve(duration: 0.5) : nil
        }
    }

    private func delete(_ index: Int) {
        model.edit {
            $0.clips.remove(at: index)
            // 删除后若新的末位片段挂着转场，一并清掉（否则校验失败）
            if let last = $0.clips.indices.last, $0.clips[last].transitionAfter != nil {
                $0.clips[last].transitionAfter = nil
            }
        }
    }
}
```

注意一个刻意的演示设计：删除片段后若末位片段挂着转场，校验会失败、快照不压栈、错误红字显示——这正是「快照模型事务语义」的活演示。

- [x] **Step 8: 模拟器验证**

在 Xcode 中选 iPhone 模拟器（iOS 17+）⌘R 运行，按顺序验证：

1. 预览自动播放，底部出现 SwiftUI 字幕叠加层
2. 五类操作各点一次，预览随每次操作重建（会重新从头播放，POC 可接受）
3. 连点两次「撤销」→ 状态回退两次；「重做」恢复
4. 删除全部片段 → 红字显示校验错误，状态不变
5. 点「导出」→ 进度条推进 → 显示导出路径与耗时

- [x] **Step 9: Commit**

```bash
git add App
git commit -m "App 壳：SwiftUI 表现层（预览/时间线/五操作/撤销重做/导出）"
```

---

## Task 14: 验证清单文档与收尾

**Files:**
- Create: `docs/poc-verification-checklist.md`

- [x] **Step 1: 写验证清单**

```markdown
# Kadr POC 验证清单

对应调研报告第 10 节三个验证点 + POC 五个关键字的逐项闭环。

## 自动化验证（swift test 全绿即通过）

- [x] 多段拼接：testSpliceDuration（时长 = 片段之和 ±0.3s）
- [x] 变速：testSpeedDoublesDuration（0.5x → 时长翻倍 ±0.3s）
- [x] 转场 + 字幕 + 全链路：testSamplePlanExport（时长 9.0–10.5s，含 metadata 字幕轨）
- [x] EditPlan JSON → DSL：SamplePlanTests 黄金契约 + PlanLoader 字段路径
- [x] 快照撤销栈：UndoStack/EditStore 全部单测

## CLI 冒烟（验证点①：Agent 链路）

- [x] `genassets` → 素材生成，`{"directory":...,"files":[...]}`
- [x] `sample` → 合法 EditPlan JSON（= Agent few-shot 样例）
- [x] `validate` 合法 JSON → exit 0 + `{"valid":true}`
- [x] `validate` 损坏 JSON → exit 1 + stderr 字段路径
- [x] `validate` 语义非法 → exit 2 + stderr 全部问题一次报全
- [x] `export` → JSONL 进度流 + `{"done":...}` + exit 0

## App 真机手动清单（iOS 17 真机）

- [x] 预览流畅播放，字幕叠加层随时间切换
- [x] 五类操作（裁剪/变速/转场/删除/字幕开关）各执行一次，预览重建正确
- [x] 连续编辑 5 次后撤销 5 次回到初始，再重做 5 次恢复
- [x] 非法操作（删空片段）红字报错且撤销栈不变
- [x] App 导出产物与 CLI 同 JSON 导出产物时长一致（±0.3s）

## 验证点③：4K HDR 素材

- [x] CLI：`--assets` 指向 4K HDR 素材目录，export 记录耗时 / 产物大小 / 是否成功
- [x] App 真机：换 4K HDR 素材预览，记录流畅度与发热（主观记录即可）

## 验证点②：iOS 17 底线覆盖率（人工调研项，代码无法验证）

- [x] 查目标用户群的 iOS 版本分布（App Store Connect 或第三方统计），确认 iOS 17+ 覆盖率

## POC 结论模板

| 关键字 | 结果 | 备注 |
|---|---|---|
| 多段拼接 | ☐ | |
| 转场 | ☐ | 转场重叠语义实测时长：___s |
| 变速 | ☐ | |
| 字幕 | ☐ | 抽帧人工核对：☐ 通过 |
| headless 导出 | ☐ | |
| EditPlan JSON → DSL 端到端 | ☐ | |
| 4K HDR 预览/导出 | ☐ | |

结论：☐ 正式立项走路径 A / ☐ 有问题待解（列出）
```

- [x] **Step 2: Commit**

```bash
git add docs/poc-verification-checklist.md
git commit -m "POC 验证清单：自动化 + CLI 冒烟 + 真机手动 + 4K HDR + 结论模板"
```

---

## 自审记录（计划写完后核对）

- **Spec 覆盖**：五个关键字 → Task 8/12；快照撤销栈 → Task 5/6；三层结构 → Task 2–10（后两层）+ Task 13（表现层）；EditPlan JSON → DSL（验证点①）→ Task 7/10/11/12；iOS 17 底线（②）→ Task 1 platforms + Task 14 调研项；4K HDR（③）→ Task 3 绝对路径 + Task 14 清单；三条硬边界 → Task 8/9/13 分层落实。无缺口。
- **占位符扫描**：无 TBD/TODO；所有代码步骤均含完整实现。
- **类型一致性**：`AssetSynthesizer.synthesize(into:) -> AssetResolver`（Task 7 起一致）；`PlanClip`/`PlanTransition`/`SpeedPlan`/`MediaRef`/`CaptionTrack`/`CaptionStyle`/`ValidationIssue`/`AssetResolver`/`UndoStack`/`EditStore`/`EngineBridge`/`PreviewBridge`/`PreviewPackage`/`CaptionCue`/`ExportRunner`/`ExportEvent`/`PlanLoader`/`PlanLoaderError` 全计划签名一致。
- **已知 API 假设**（实现期按编译结果校准，均不冲击 EditPlan schema）：`VideoClip.speed(_:)` 的 Double 重载；`Video { [any Clip] }` 单数组表达式；转场时长对导出总时长的影响（测试留出了实测区间）。

---

## 实施变更记录（计划 → 落地的偏差汇总，2026-10-08 实施完成后补记）

所有任务已完成。以下是实施与评审过程中对原计划的有意修正，均已通过两级评审：

**JSON 契约（Task 2 评审驱动，先于 Task 7 冻结）**
- `SpeedPlan`/`PlanTransition` 改用 tagged 格式：`{"type":"flat","rate":0.5}` / `{"type":"dissolve","duration":0.5}`（消除合成 Codable 的 `_0` 位置键，Agent 友好）
- `EditPlan`/`PlanClip` 增加自定义 `init(from:)`：version/id/speed/preset 解码时可用默认值（LLM 可生成极简 JSON）
- `range` 的 wire 格式实为二元数组 `[0, 3]`（Foundation ClosedRange Codable 是无键数组，非对象）
- `ValidationFailure` wrapper 取代 `[ValidationIssue]` 的 retroactive Error 一致性（Task 6 评审）

**Kadr 1.1.0 真实 API 校准（Task 8 实施发现）**
- `VideoClip.speed(_:)` 无 Double 重载（v0.14 移除）→ `.speed(.flat(rate))`
- `VideoBuilder` 的 `buildExpression` 拦截单个数组表达式 → 动态列表必须用 `for element in elements { element }` 走 `buildArray`
- `Kadr.Transition` 无 Equatable → 测试用模式匹配断言
- `TextOverlay.visible(during:)` 有 `CMTimeRange` 重载 → 字幕时间直达，消除 timescale 1000→600 重量化漂移
- 校验器转场适配检查改为变速后时长（Kadr 按 post-speed 校验，dissolve 每侧吃全额、fade 吃半额；我们保守按全额）

**导出管线根因修复（Task 11 评审暴露，计划外新增，commit 42e1950）**
- Issue 1（Critical）：无音频素材 → Kadr CompositionBuilder 产生空音频轨 → AVFoundation HEVC 兼容性检查 false → ExportEngine 静默回退 passthrough（preset/转场/字幕全丢但报"成功"）。POC 侧修复：SilentAudio 静音 WAV 兜底 + ExportVerifier 导出后硬校验（单视频轨/分辨率/编码）
- Issue 2（macOS）：TextOverlay 的 CATextLayer 在 macOS headless 导出不渲染 → CaptionImageRenderer 预渲染图片 + ImageOverlay 替代
- 两条均建议提上游 issue（详见 docs/poc-verification-checklist.md 末节）

**App 壳（Task 13 评审驱动）**
- `@MainActor` 标注 App 结构体（App.init 调 @MainActor 初始化器的 Swift 6 合规）
- 周期性时间观察从 `addPeriodicTimeObserver`（@Sendable 闭包捕获非 Sendable self 报错）改为 100ms 轮询 Task
- rebuild 增加二次取消检查消除竞态

**其他**
- CLI 子命令显式 `commandName: "genassets"`（ArgumentParser 默认派生 kebab-case）
- 验证器测试 `5...1` → `5...5`（ClosedRange 前置条件会崩溃，语义不变）
- 涉及随机 UUID 的相等断言统一捕获同一实例（PlanClip.id 默认值陷阱）
- Bundle ID 为 Xcode 模板自动生成的 `com.haozhenyi.JangyPOC`，正式立项时改
