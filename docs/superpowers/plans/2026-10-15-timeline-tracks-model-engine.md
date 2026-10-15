# 时间线多轨实施计划（阶段①：模型 + 引擎）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 EditPlan 从「扁平单视频轨 + 整片字幕引用」换成「多轨 + 特性注册表」模型，并打通引擎、字幕逐句化、Agent 工具、v3→v4 迁移全链路。

**Architecture:** L2 核心只认识「轨道 = 通用字段 + 一串带时间区间的元素」；元素 payload 按 `type` 字段交给注册的特性模块编解码。一类轨 = 一个 `Features/<Name>/` 目录，按层切片（L2 payload+校验 / L3 引擎映射 / L0 呈现，L0 在阶段②）。注册表由 JangyCore 内部静态装配，headless CLI 可直接用。

**Tech Stack:** Swift 6 / SwiftPM / XCTest / Kadr 1.2 / kadr-captions

**Spec:** [2026-10-15-timeline-tracks-design.md](../specs/2026-10-15-timeline-tracks-design.md)

**范围边界：** 本计划只做阶段①（模型 + 引擎）。时间线 UI、L1 Interaction 层、L0 lane 呈现器属阶段②——本计划对 `Jangy/TimelineView.swift` 只做「让它编译通过、行为不变」的最小适配。

**执行顺序约束：** Task 1–5 每步独立可编译可测、可单独提交（**都不破坏现有代码**）。**红色区间从 Task 6 开始**：`EditPlan` 换形状 + `PlanClip` 去 `id` 会让所有消费者同时失效，因此 **Task 6 + 7 + 8 必须作为一个工作单元连续完成、中途不要提交**，直到 `swift build` + `swift test` + `xcodebuild` 三者全绿再一次性提交。

**`type` 判别字段归 `TrackPayload` box 所有（Task 1 执行时确认）**：box 在 `encode` 里注入 `type`、在 `init(from:)` 里用 `TypeProbe` 读它；**具体 payload 一律不得在自己的 `encode` 里写 `type`**（会写两次）。这样 payload 忘了写判别字段这件事在结构上不可能发生。Task 2 / Task 3 的 payload 代码已按此修正。

---

## 文件结构

**新建：**

| 文件 | 层 | 职责 |
|---|---|---|
| `Packages/JangyCore/Sources/JangyCore/Plan/TrackKind.swift` | L2 | 开放轨道类型（包 String） |
| `Packages/JangyCore/Sources/JangyCore/Plan/TrackPlacement.swift` | L2 | 链式 / 绝对定位（结构属性） |
| `Packages/JangyCore/Sources/JangyCore/Plan/PlanTrack.swift` | L2 | 轨道容器 |
| `Packages/JangyCore/Sources/JangyCore/Plan/PlanElement.swift` | L2 | 元素 + `ElementContent` |
| `Packages/JangyCore/Sources/JangyCore/Plan/TrackPayload.swift` | L2 | type-erased payload box |
| `Packages/JangyCore/Sources/JangyCore/Features/TrackFeature.swift` | L2 | 特性模块协议（L2 片）+ 校验上下文 |
| `Packages/JangyCore/Sources/JangyCore/Features/Manifest.swift` | L2 | 唯一清单 + 注册表 |
| `Packages/JangyCore/Sources/JangyCore/Features/Video/VideoFeature.swift` | L2 | 视频轨 payload + 校验 |
| `Packages/JangyCore/Sources/JangyCore/Features/Video/VideoEngine.swift` | L3 | 视频轨 → Kadr |
| `Packages/JangyCore/Sources/JangyCore/Features/Caption/CaptionFeature.swift` | L2 | 字幕轨 payload + 校验 |
| `Packages/JangyCore/Sources/JangyCore/Features/Caption/CaptionEngine.swift` | L3 | 字幕轨 → Kadr.Caption |
| `Packages/JangyCore/Sources/JangyCore/SRTParser.swift` | L2 | 极简纯 Swift SRT 解析（迁移用） |
| `Packages/JangyCore/Sources/JangyCore/TrackOperations.swift` | L2 | 轨级原子操作 + 两条不变式维持 |
| `Packages/JangyCore/Sources/JangyCore/PlanMigration.swift` | L2 | v3 → v4 迁移 |

**修改：** `EditPlan.swift`（换 v4，`PlanClip` 去 `id`）、`EditPlanValidator.swift`、`TimelineDuration.swift`、`EngineBridge.swift`、`PlanLoader.swift`、`ProjectStore.swift`、`ProjectPackage.swift`、`ReferenceScanner.swift`、`CoverGenerator.swift`、`PreviewBridge.swift`、`AgentTools.swift`、`AgentPromptBuilder.swift`、`jangy-cli/*.swift`、`SamplePlan.swift`、`Jangy/*.swift`。

---

## Task 1: 核心轨道类型 + TrackPayload + 特性注册表

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/Plan/TrackKind.swift`
- Create: `Packages/JangyCore/Sources/JangyCore/Plan/TrackPlacement.swift`
- Create: `Packages/JangyCore/Sources/JangyCore/Plan/TrackPayload.swift`
- Create: `Packages/JangyCore/Sources/JangyCore/Plan/PlanElement.swift`
- Create: `Packages/JangyCore/Sources/JangyCore/Plan/PlanTrack.swift`
- Create: `Packages/JangyCore/Sources/JangyCore/Features/TrackFeature.swift`
- Create: `Packages/JangyCore/Sources/JangyCore/Features/Manifest.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/PlanTrackTests.swift`

**设计要点：** 特性模块的校验接口吃一个**窄上下文**（`TrackValidationContext`），不吃整个 `EditPlan`。这样核心类型与特性协议不必等 v4 的 `EditPlan` 存在即可落地（Task 6 才换 `EditPlan`），同时窄接口本身也是更好的边界。

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import JangyCore

/// 测试用假 payload：只验证注册表的分发机制。
struct TestPingPayload: TrackElementPayload {
    static let payloadType = "test-ping"
    var value: Int
    var duration: TimeInterval { 1.0 }
}

final class PlanTrackTests: XCTestCase {

    // 测试假特性必须注册进注册表：往返用例要经 TrackPayload 的解码路径查表。
    // 注册在 setUp 而不是单个用例里——XCTest 按字母序执行，往返用例会排在注入用例之前。
    override func setUp() {
        super.setUp()
        TrackFeatureRegistry.testOnlyFeatures = [TestPingFeature.self]
    }

    override func tearDown() {
        TrackFeatureRegistry.testOnlyFeatures = []
        super.tearDown()
    }

    // MARK: 轨道与元素

    func testTrackKindIsOpenType() {
        let custom = TrackKind(rawValue: "sticker")
        XCTAssertEqual(custom.rawValue, "sticker")
        XCTAssertNotEqual(custom, .video)
    }

    func testChainedTrackDerivesSpanFromOrder() {
        let track = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .gap(duration: 2)),
            PlanElement(content: .gap(duration: 3)),
        ])
        XCTAssertEqual(track.span, 5)
        XCTAssertNil(track.elements[0].at, "链式轨元素不带 at")
    }

    func testAbsoluteTrackSpanIsMaxOfEnds() {
        let track = PlanTrack(kind: .caption, placement: .absolute, elements: [
            PlanElement(at: 1.0, content: .gap(duration: 2)),
            PlanElement(at: 4.0, content: .gap(duration: 1)),
        ])
        XCTAssertEqual(track.span, 5)
    }

    func testElementDurationComesFromContent() {
        XCTAssertEqual(PlanElement(content: .gap(duration: 1.5)).duration, 1.5)
        XCTAssertEqual(PlanElement(content: .content(TrackPayload(TestPingPayload(value: 1)))).duration, 1.0)
    }

    func testElementContentRoundTrips() throws {
        for content: ElementContent in [.gap(duration: 1.5), .content(TrackPayload(TestPingPayload(value: 7)))] {
            let data = try JSONEncoder().encode(content)
            XCTAssertEqual(try JSONDecoder().decode(ElementContent.self, from: data), content)
        }
    }

    func testUnknownContentTypeThrows() {
        let json = #"{"type":"no-such-content"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(ElementContent.self, from: json))
    }

    // MARK: payload 与注册表

    func testPayloadRoundTripsThroughRegisteredCodec() throws {
        let payload = TrackPayload(TestPingPayload(value: 7))
        XCTAssertEqual(payload.payloadType, "test-ping")
        XCTAssertEqual(payload.duration, 1.0)

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TrackPayload.self, from: data)
        XCTAssertEqual(decoded.value as? TestPingPayload, TestPingPayload(value: 7))
    }

    func testUnknownPayloadTypeThrowsAndListsRegistered() throws {
        let json = #"{"type":"no-such-payload"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(TrackPayload.self, from: json)) { error in
            XCTAssertTrue("\(error)".contains("已注册"), "报错应列出已注册类型，便于排查")
        }
    }

    func testPayloadEqualityDistinguishesDifferentValuesOfSameType() {
        XCTAssertNotEqual(TrackPayload(TestPingPayload(value: 1)),
                          TrackPayload(TestPingPayload(value: 2)))
    }

    func testPlanTrackRoundTripsThroughJSON() throws {
        // v4 JSON 是 CLI / Agent / 落盘共用的互操作契约，这个形状必须往返稳定
        let track = PlanTrack(kind: .video, placement: .chained, name: "主轨",
                              isMuted: true, elements: [
            PlanElement(at: nil, content: .content(TrackPayload(TestPingPayload(value: 3)))),
            PlanElement(at: nil, content: .gap(duration: 2)),
        ])
        let data = try JSONEncoder().encode(track)
        XCTAssertEqual(try JSONDecoder().decode(PlanTrack.self, from: data), track)
    }

    func testChainedElementOmitsAtFromJSON() throws {
        let element = PlanElement(content: .gap(duration: 1))
        let data = try JSONEncoder().encode(element)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(json?["at"], "链式轨元素的 at 为 nil，不应出现在 JSON 里")
    }

    func testRegistryIsStaticallyAssembledWithoutExternalInit() {
        // 注册表必须在 JangyCore 内部装配：headless CLI 不做任何初始化即可用。
        // 本步生产清单还是空的（Video/Caption 特性在 Task 2/3 加入），
        // 只断言「静态可读、不依赖任何外部初始化」。
        XCTAssertNotNil(TrackFeatureRegistry.payloadCodecs)
        XCTAssertNotNil(TrackFeatureRegistry.features)
    }

    func testTestOnlyFeatureInjectionReachesRegistry() {
        TrackFeatureRegistry.testOnlyFeatures = [TestPingFeature.self]
        defer { TrackFeatureRegistry.testOnlyFeatures = [] }

        XCTAssertEqual(TrackFeatureRegistry.payloadCodecs["test-ping"]?.payloadType, "test-ping")
        XCTAssertEqual(TrackFeatureRegistry.feature(for: TrackKind(rawValue: "test-ping-track"))?.kind,
                       TrackKind(rawValue: "test-ping-track"))
    }
}

/// 测试用假特性片。
enum TestPingFeature: TrackFeature {
    static let kind = TrackKind(rawValue: "test-ping-track")
    static let payloadTypes: [any TrackElementPayload.Type] = [TestPingPayload.self]
    static func validate(track: PlanTrack, context: TrackValidationContext) -> [ValidationIssue] { [] }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/JangyCore && swift test --filter PlanTrackTests`
Expected: 编译失败 —— `cannot find 'PlanTrack' in scope`

- [ ] **Step 3: 实现类型**

`Plan/TrackKind.swift`：

```swift
import Foundation

/// 轨道类型：开放类型（包 String），核心不 switch 它。
/// 核心能说「这条轨是链式的」，说不出「这条轨是音乐」——具体轨类型由特性模块解释。
public struct TrackKind: Codable, Equatable, Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let video = TrackKind(rawValue: "video")
    public static let caption = TrackKind(rawValue: "caption")
}
```

`Plan/TrackPlacement.swift`：

```swift
import Foundation

/// 元素定位方式：结构属性（核心认识），不是类型属性。
/// - chained：位置由数组顺序推出，元素不带 at（主轨）
/// - absolute：每个元素自带 at（叠加轨 / 字幕轨）
public enum TrackPlacement: String, Codable, Sendable {
    case chained
    case absolute
}
```

`Plan/TrackPayload.swift`：

```swift
import Foundation

/// 元素 payload 的值语义契约。实现者自带 `payloadType` 判别字符串，
/// 核心只读这个字符串查表分发，不认识任何具体 payload 类型。
public protocol TrackElementPayload: Codable, Equatable, Sendable {
    static var payloadType: String { get }
    /// 元素时长。有内容的元素时长由 payload 推出（gap 的时长自带）。
    var duration: TimeInterval { get }

    /// 同具体类型的相等比较。**声明为协议要求**（而非仅扩展方法），
    /// 保证通过 `any TrackElementPayload` 调用时走见证表动态派发，
    /// 而不是被静态派发到默认实现上。
    func isEqual(to other: any TrackElementPayload) -> Bool
}

/// type-erased payload box：JSON 形如 {"type":"clip", ...}。
public struct TrackPayload: Codable, Equatable, Sendable {
    public let payloadType: String
    public let value: any TrackElementPayload

    public init(_ value: any TrackElementPayload) {
        self.value = value
        self.payloadType = type(of: value).payloadType
    }

    public var duration: TimeInterval { value.duration }

    private struct TypeProbe: Decodable { let type: String }

    public init(from decoder: Decoder) throws {
        let probe = try TypeProbe(from: decoder)
        guard let codec = TrackFeatureRegistry.payloadCodecs[probe.type] else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "未注册的元素 payload 类型 '\(probe.type)'。已注册：\(TrackFeatureRegistry.payloadCodecs.keys.sorted().joined(separator: ", "))"))
        }
        self.payloadType = probe.type
        self.value = try codec.init(from: decoder)
    }

    private enum TypeKey: String, CodingKey { case type }

    public func encode(to encoder: Encoder) throws {
        // 判别字段 `type` 由 box 注入（具体 payload 只关心自己的字段），
        // 与 `init(from:)` 的 TypeProbe 对称：JSON 形如 {"type":"clip", ...}。
        var container = encoder.container(keyedBy: TypeKey.self)
        try container.encode(payloadType, forKey: .type)
        try value.encode(to: encoder)
    }

    public static func == (lhs: TrackPayload, rhs: TrackPayload) -> Bool {
        guard lhs.payloadType == rhs.payloadType else { return false }
        return lhs.value.isEqual(to: rhs.value)
    }
}

extension TrackElementPayload {
    /// 默认实现：同具体类型才相等。
    public func isEqual(to other: any TrackElementPayload) -> Bool {
        guard let other = other as? Self else { return false }
        return self == other
    }
}
```

`Plan/PlanElement.swift`：

```swift
import Foundation

/// 时间线上的一个元素。id 是唯一寻址单元（原 PlanClip.id 挪到这一层）。
public struct PlanElement: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// 仅 .absolute 轨使用；.chained 轨为 nil（位置由顺序推出，避免两个事实源）。
    public var at: TimeInterval?
    public var content: ElementContent

    public init(id: UUID = UUID(), at: TimeInterval? = nil, content: ElementContent) {
        self.id = id
        self.at = at
        self.content = content
    }

    /// 元素时长。有内容的由 payload 推出，gap 的时长自带——各自单一事实源。
    public var duration: TimeInterval {
        switch content {
        case .gap(let d): return d
        case .content(let payload): return payload.duration
        }
    }
}

/// 元素内容：有内容（payload 由特性模块解释）/ 空档（占位无内容）。
/// gap 归核心而不是归某个特性模块——它是「结构」（这里空着），不是「类型」（空的是音乐）。
public enum ElementContent: Codable, Equatable, Sendable {
    case content(TrackPayload)
    case gap(duration: TimeInterval)

    private enum CodingKeys: String, CodingKey { case type, duration, payload }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "gap":
            self = .gap(duration: try container.decode(TimeInterval.self, forKey: .duration))
        case "content":
            self = .content(try container.decode(TrackPayload.self, forKey: .payload))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "未知的 ElementContent 类型 '\(type)'；支持的类型：content, gap")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .gap(let duration):
            try container.encode("gap", forKey: .type)
            try container.encode(duration, forKey: .duration)
        case .content(let payload):
            try container.encode("content", forKey: .type)
            try container.encode(payload, forKey: .payload)
        }
    }
}
```

`Plan/PlanTrack.swift`：

```swift
import Foundation

/// 一条轨道。通用字段（id / kind / name / flags / placement）由核心持有；
/// 轨级参数与元素内容按 kind 交给注册的特性模块解释。
public struct PlanTrack: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: TrackKind
    public var name: String?
    public var placement: TrackPlacement
    public var isMuted: Bool
    public var isHidden: Bool
    public var isLocked: Bool
    /// 轨级参数（如字幕样式）。核心原样带着走，不认识里面是什么。
    public var settings: TrackPayload?
    public var elements: [PlanElement]

    public init(id: UUID = UUID(), kind: TrackKind, name: String? = nil,
                placement: TrackPlacement, isMuted: Bool = false, isHidden: Bool = false,
                isLocked: Bool = false, settings: TrackPayload? = nil,
                elements: [PlanElement] = []) {
        self.id = id
        self.kind = kind
        self.name = name
        self.placement = placement
        self.isMuted = isMuted
        self.isHidden = isHidden
        self.isLocked = isLocked
        self.settings = settings
        self.elements = elements
    }

    /// 轨道自身的时间跨度。链式轨 = Σ 元素时长（**不含转场重叠，因此不等于成片时长**）；
    /// 绝对轨 = max(at + duration)（绝对轨元素本来就按成片时间轴定位，所以它等于轨道末端）。
    ///
    /// 成片时长一律用 `EditPlan.renderedDuration`（公约 §3.3 的实测口径）。
    /// 校验「其他轨元素是否超出主轨末端」时也必须用 `renderedDuration`，不能用 `span`——
    /// 样例工程两者差 0.5s（span 10 vs renderedDuration 9.5）。
    public var span: TimeInterval {
        switch placement {
        case .chained:
            return elements.reduce(0) { $0 + $1.duration }
        case .absolute:
            return elements.reduce(0) { max($0, ($1.at ?? 0) + $1.duration) }
        }
    }
}
```

`Features/TrackFeature.swift`：

```swift
import Foundation

/// 特性模块的校验上下文：窄接口——特性只需要「素材登记表 + 主轨末端 + 全部轨道」，
/// 不必认识 EditPlan 的其余部分。
public struct TrackValidationContext: Sendable {
    public let assets: [AssetItem]
    /// 主轨链长。其他轨的元素不得超出它。
    public let mainTrackEnd: TimeInterval
    public let tracks: [PlanTrack]

    public init(assets: [AssetItem], mainTrackEnd: TimeInterval, tracks: [PlanTrack]) {
        self.assets = assets
        self.mainTrackEnd = mainTrackEnd
        self.tracks = tracks
    }

    public func asset(withID id: UUID) -> AssetItem? { assets.first { $0.id == id } }
}

/// 一类轨的特性模块（L2 片）。L3 引擎映射与 L0 呈现是同一 kind 的另外两片，
/// 分别在各自的层——因为 L2 不能 import Kadr / SwiftUI。
public protocol TrackFeature {
    static var kind: TrackKind { get }
    /// 本特性贡献的元素 payload 类型（决定 payloadType 字符串 → 编解码器）。
    static var payloadTypes: [any TrackElementPayload.Type] { get }
    /// 本特性的校验规则。由 EditPlanValidator 统一分派调用。
    static func validate(track: PlanTrack, context: TrackValidationContext) -> [ValidationIssue]
}
```

`Features/Manifest.swift`：

```swift
import Foundation

/// 特性清单 —— 全仓库唯一的注册点。加一类轨 = 这里加一行 + 新增一个 Features/<Name>/ 目录。
/// 静态装配（不依赖 App 启动）：`jangy-cli agent` 是 headless 跑的，
/// 若编解码器由 App 注册，CLI 解码带新轨类型的 plan 会直接失败。
public enum TrackFeatureRegistry {

    /// 生产特性清单。计算属性：无共享可变状态，因此不需要 nonisolated(unsafe) 豁免。
    public static var features: [any TrackFeature.Type] {
        []
    }

    /// 测试注入点：可插拔性验收用（Task 13）。生产路径永不写入。
    /// `internal` 而非 `public`——测试经 `@testable import` 访问，生产 API 面不该暴露这个可变全局。
    nonisolated(unsafe) static var testOnlyFeatures: [any TrackFeature.Type] = []

    public static var allFeatures: [any TrackFeature.Type] { features + testOnlyFeatures }

    /// payloadType 字符串 → 编解码器。计算属性而非缓存：测试注入后立即生效。
    public static var payloadCodecs: [String: any TrackElementPayload.Type] {
        var table: [String: any TrackElementPayload.Type] = [:]
        for feature in allFeatures {
            for type in feature.payloadTypes {
                table[type.payloadType] = type
            }
        }
        return table
    }

    public static func feature(for kind: TrackKind) -> (any TrackFeature.Type)? {
        allFeatures.first { $0.kind == kind }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd Packages/JangyCore && swift test --filter PlanTrackTests`
Expected: PASS（13 个用例）

- [ ] **Step 5: 提交**

```bash
git add Packages/JangyCore/Sources/JangyCore/Plan Packages/JangyCore/Sources/JangyCore/Features \
        Packages/JangyCore/Tests/JangyCoreTests/PlanTrackTests.swift
git commit -m "Core: 多轨核心类型 + TrackPayload + 特性注册表（静态装配，headless 可用）"
```

---

## Task 2: Video 特性（L2 片）

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/Features/Video/VideoFeature.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/EditPlan.swift`（`PlanClip` 加 `TrackElementPayload` 一致性 + `duration`；**`id` 本步保留**）
- Modify: `Packages/JangyCore/Sources/JangyCore/TimelineDuration.swift`（`outputDuration` 改为转发 `duration`）
- Modify: `Packages/JangyCore/Sources/JangyCore/EditPlanValidator.swift`（`ValidationIssue` 加 `elementID`）
- Modify: `Packages/JangyCore/Sources/JangyCore/Features/Manifest.swift`（注册 VideoFeature）
- Test: `Packages/JangyCore/Tests/JangyCoreTests/VideoFeatureTests.swift`

**本步必须保持代码库绿色。** `PlanClip` 本步只加协议一致性、**不动 `id`**，所以 `EditPlanValidator` / `EngineBridge` / Agent / App / 全部测试照旧编译。SwiftPM 编译整个 target，若本步顺手把 `id` 去掉，连 `swift test --filter VideoFeatureTests` 都跑不起来。**`PlanClip.id` 的移除与 `plan.clips` → `plan.tracks` 的切换一起在 Task 6 做。**

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import JangyCore

final class VideoFeatureTests: XCTestCase {
    private let assetID = UUID()

    private func context(assets: [AssetItem], mainTrackEnd: TimeInterval = 10) -> TrackValidationContext {
        TrackValidationContext(assets: assets, mainTrackEnd: mainTrackEnd, tracks: [])
    }

    func testClipRoundTripsAsTrackPayload() throws {
        let clip = PlanClip(assetID: assetID, source: .video(0...3), speed: .flat(2.0))
        let payload = TrackPayload(clip)
        XCTAssertEqual(payload.payloadType, "clip")
        XCTAssertEqual(payload.duration, 1.5, accuracy: 0.0001)

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TrackPayload.self, from: data)
        XCTAssertEqual(decoded.value as? PlanClip, clip)
    }

    func testClipJSONCarriesTypeDiscriminator() throws {
        let data = try JSONEncoder().encode(TrackPayload(PlanClip(assetID: assetID, source: .video(0...3))))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "clip")
    }

    func testValidateRejectsVideoClipReferencingImageAsset() {
        let track = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: assetID, source: .video(0...3))))),
        ])
        let issues = VideoFeature.validate(
            track: track,
            context: context(assets: [AssetItem(id: assetID, kind: .image, fileName: "a.png")]))
        XCTAssertTrue(issues.contains { $0.message.contains("视频片段必须引用视频素材") })
    }

    func testValidateRejectsTransitionCrossingGap() {
        let track = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: assetID, source: .video(0...3),
                                                                transitionAfter: .dissolve(duration: 0.5))))),
            PlanElement(content: .gap(duration: 1)),
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: assetID, source: .video(0...3))))),
        ])
        let issues = VideoFeature.validate(track: track, context: context(assets: []))
        XCTAssertTrue(issues.contains { $0.message.contains("转场不能跨过空档") })
    }

    func testValidateIssuesCarryElementID() {
        let element = PlanElement(content: .content(TrackPayload(
            PlanClip(assetID: UUID(), source: .video(0...3)))))
        let track = PlanTrack(kind: .video, placement: .chained, elements: [element])
        let issues = VideoFeature.validate(track: track, context: context(assets: []))
        XCTAssertEqual(issues.first?.elementID, element.id)
    }

    func testValidateAcceptsChainedGap() {
        let track = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .gap(duration: 2)),
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: assetID, source: .video(0...3))))),
        ])
        XCTAssertTrue(VideoFeature.validate(
            track: track,
            context: context(assets: [AssetItem(id: assetID, kind: .video, fileName: "v.mp4", duration: 4)])).isEmpty)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/JangyCore && swift test --filter VideoFeatureTests`
Expected: 编译失败 —— `PlanClip` 不符合 `TrackElementPayload`

- [ ] **Step 3: 改 PlanClip**

`EditPlan.swift` 中 `PlanClip` 的改动——**加协议一致性 + `duration`，本步保留 `id`**：

```swift
/// 视频轨的元素 payload。`type` 判别字段由 TrackPayload box 注入，这里不写。
/// **`id` 本步仍在这里**——它要到 Task 6 才挪去 PlanElement（届时删掉字段与它的编解码）。
public struct PlanClip: Codable, Equatable, Sendable, TrackElementPayload {
    public static let payloadType = "clip"

    public var id: UUID
    /// 素材引用：指向 EditPlan.assets 中的条目。
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

    /// payload 时长 = 输出时长（源区间长 / 倍速）。
    public var duration: TimeInterval { source.length / speed.rate }

    private enum CodingKeys: String, CodingKey {
        case id, assetID, source, speed, transitionAfter
    }
    private enum LegacyKeys: String, CodingKey { case range }

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

    // encode 走合成实现（按 CodingKeys 写 id/assetID/source/speed/transitionAfter）。
    // 不写 `type`——那是 box 的事。
}
```

`TimelineDuration.swift` 里 `PlanClip.outputDuration` 改为转发，保证两者永远是同一个值：

```swift
extension PlanClip {
    /// 片段在输出时间线上的时长 = 源区间长度 / 倍速。
    /// TrackElementPayload.duration 转发到这里——两者是同一个值，不是两处口径。
    public var outputDuration: TimeInterval { duration }
}
```

- [ ] **Step 4: 加 ValidationIssue.elementID**

`EditPlanValidator.swift`：

```swift
public struct ValidationIssue: Equatable, Sendable, Codable, CustomStringConvertible {
    public let path: String
    public let message: String
    /// 出问题的元素 ID（可定位时）。Agent 用它做位置无关的引用——
    /// 下标会随 plan 变动漂移，ID 不会。
    public let elementID: UUID?

    public init(path: String, elementID: UUID? = nil, message: String) {
        self.path = path
        self.elementID = elementID
        self.message = message
    }

    public var description: String { "\(path): \(message)" }
}
```

- [ ] **Step 5: 实现 VideoFeature**

`Features/Video/VideoFeature.swift`：

```swift
import Foundation

/// 视频轨特性（L2 片）：payload 模型 + 校验规则。L3 引擎映射见同目录 VideoEngine.swift。
public enum VideoFeature: TrackFeature {
    public static let kind = TrackKind.video
    public static let payloadTypes: [any TrackElementPayload.Type] = [PlanClip.self]

    public static func validate(track: PlanTrack, context: TrackValidationContext) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        if track.placement != .chained {
            issues.append(ValidationIssue(path: "tracks[\(track.id)].placement",
                                          message: "视频轨必须是链式（.chained）"))
        }

        for (i, element) in track.elements.enumerated() {
            let path = "tracks[\(track.id)].elements[\(i)]"
            // gap 在链式轨上合法（删除留下的空档），不校验内容
            guard case .content(let payload) = element.content,
                  let clip = payload.value as? PlanClip else { continue }

            let asset = context.asset(withID: clip.assetID)
            if asset == nil {
                issues.append(ValidationIssue(path: "\(path).assetID", elementID: element.id,
                                              message: "引用了未登记的素材: \(clip.assetID)"))
            } else if let asset {
                switch clip.source {
                case .video where asset.kind != .video:
                    issues.append(ValidationIssue(path: "\(path).assetID", elementID: element.id,
                                                  message: "视频片段必须引用视频素材，实际为 \(asset.kind.rawValue)"))
                case .still where asset.kind != .image:
                    issues.append(ValidationIssue(path: "\(path).assetID", elementID: element.id,
                                                  message: "图片片段必须引用图片素材，实际为 \(asset.kind.rawValue)"))
                default:
                    break
                }
            }

            switch clip.source {
            case .video(let range):
                if range.lowerBound < 0 {
                    issues.append(ValidationIssue(path: "\(path).source.range", elementID: element.id,
                                                  message: "裁剪起点不能为负"))
                } else if range.upperBound <= range.lowerBound {
                    issues.append(ValidationIssue(path: "\(path).source.range", elementID: element.id,
                                                  message: "裁剪区间不能为空"))
                } else if let duration = asset?.duration,
                          range.upperBound > duration + EditPlanValidator.durationTolerance {
                    issues.append(ValidationIssue(path: "\(path).source.range", elementID: element.id,
                                                  message: "裁剪终点超出素材时长（\(duration)s）"))
                }
            case .still(let duration):
                if duration <= 0 {
                    issues.append(ValidationIssue(path: "\(path).source.duration", elementID: element.id,
                                                  message: "图片时长必须为正"))
                }
            }

            if !EditPlanValidator.speedRange.contains(clip.speed.rate) {
                issues.append(ValidationIssue(
                    path: "\(path).speed", elementID: element.id,
                    message: "变速倍率必须在 \(EditPlanValidator.speedRange.lowerBound)–\(EditPlanValidator.speedRange.upperBound) 之间"))
            }

            guard let transition = clip.transitionAfter else { continue }

            // 转场只对「紧邻的下一个元素」生效；gap 打断邻接
            let nextIndex = i + 1
            guard nextIndex < track.elements.count else {
                issues.append(ValidationIssue(path: "\(path).transitionAfter", elementID: element.id,
                                              message: "最后一个片段不能挂转场"))
                continue
            }
            guard case .content(let nextPayload) = track.elements[nextIndex].content,
                  nextPayload.value is PlanClip else {
                issues.append(ValidationIssue(path: "\(path).transitionAfter", elementID: element.id,
                                              message: "转场不能跨过空档——请先移除转场"))
                continue
            }
            if transition.duration <= 0 {
                issues.append(ValidationIssue(path: "\(path).transitionAfter", elementID: element.id,
                                              message: "转场时长必须为正"))
                continue
            }
            let nextDuration = track.elements[nextIndex].duration
            if transition.duration > min(element.duration, nextDuration) {
                issues.append(ValidationIssue(path: "\(path).transitionAfter", elementID: element.id,
                                              message: "转场时长不能超过相邻片段时长"))
            }
        }
        return issues
    }
}
```

- [ ] **Step 6: 注册 VideoFeature**

`Features/Manifest.swift` 的 `features`：

```swift
    public static let features: [any TrackFeature.Type] = [
        VideoFeature.self,
    ]
```

- [ ] **Step 7: 运行确认通过**

Run: `cd Packages/JangyCore && swift test --filter VideoFeatureTests`
Expected: PASS（6 个用例）

- [ ] **Step 8: 全量回归**

Run: `cd Packages/JangyCore && swift test`
Expected: 190 个既有用例 + 本任务 6 个新用例，全部通过。**本步不破坏任何现有代码**（`PlanClip` 只加协议一致性、没动 `id`），所以这是一次干净的绿色提交。

- [ ] **Step 9: 提交**

```bash
git add Packages/JangyCore/Sources/JangyCore/Features/Video \
        Packages/JangyCore/Sources/JangyCore/EditPlan.swift \
        Packages/JangyCore/Sources/JangyCore/TimelineDuration.swift \
        Packages/JangyCore/Sources/JangyCore/EditPlanValidator.swift \
        Packages/JangyCore/Sources/JangyCore/Features/Manifest.swift \
        Packages/JangyCore/Tests/JangyCoreTests/VideoFeatureTests.swift
git commit -m "Core: Video 特性片（PlanClip 加 TrackElementPayload 一致性，id 归 PlanElement 待 Task 6）"
```

---

## Task 3: Caption 特性（L2 片）

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/Features/Caption/CaptionFeature.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/Features/Manifest.swift`（注册 CaptionFeature）
- Test: `Packages/JangyCore/Tests/JangyCoreTests/CaptionFeatureTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import JangyCore

final class CaptionFeatureTests: XCTestCase {

    func testCueRoundTripsAsTrackPayload() throws {
        let cue = CaptionCuePayload(text: "第一段：开场", duration: 2.5)
        let payload = TrackPayload(cue)
        XCTAssertEqual(payload.payloadType, "caption-cue")
        XCTAssertEqual(payload.duration, 2.5, accuracy: 0.0001)

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TrackPayload.self, from: data)
        XCTAssertEqual(decoded.value as? CaptionCuePayload, cue)
    }

    func testSettingsRoundTrip() throws {
        let sourceID = UUID()
        let settings = CaptionTrackSettings(fontSize: 48, isBold: true, isEnabled: true,
                                            sourceAssetID: sourceID)
        let payload = TrackPayload(settings)
        XCTAssertEqual(payload.payloadType, "caption-settings")
        XCTAssertEqual(payload.duration, 0, "轨级参数不占时间线")
        let data = try JSONEncoder().encode(payload)
        XCTAssertEqual(try JSONDecoder().decode(TrackPayload.self, from: data).value as? CaptionTrackSettings,
                       settings)
    }

    func testSettingsFallsBackToDefaultsWhenMissing() {
        let track = PlanTrack(kind: .caption, placement: .absolute)
        XCTAssertEqual(CaptionFeature.settings(of: track), CaptionTrackSettings())
    }

    func testValidateRejectsCueBeyondMainTrackEnd() {
        let cue = PlanElement(at: 4, content: .content(TrackPayload(
            CaptionCuePayload(text: "越界", duration: 3))))
        let track = PlanTrack(kind: .caption, placement: .absolute, elements: [cue])
        let context = TrackValidationContext(assets: [], mainTrackEnd: 5, tracks: [track])
        let issues = CaptionFeature.validate(track: track, context: context)
        XCTAssertTrue(issues.contains { $0.message.contains("超出主轨末端") })
        XCTAssertEqual(issues.first?.elementID, cue.id)
    }

    func testValidateRejectsAbsoluteElementWithoutAt() {
        let track = PlanTrack(kind: .caption, placement: .absolute, elements: [
            PlanElement(content: .content(TrackPayload(CaptionCuePayload(text: "x", duration: 1)))),
        ])
        let context = TrackValidationContext(assets: [], mainTrackEnd: 10, tracks: [track])
        XCTAssertTrue(CaptionFeature.validate(track: track, context: context)
            .contains { $0.message.contains("必须带 at") })
    }

    func testValidateRejectsUnregisteredSourceAsset() {
        let track = PlanTrack(kind: .caption, placement: .absolute,
                              settings: TrackPayload(CaptionTrackSettings(sourceAssetID: UUID())))
        let context = TrackValidationContext(assets: [], mainTrackEnd: 10, tracks: [track])
        XCTAssertTrue(CaptionFeature.validate(track: track, context: context)
            .contains { $0.message.contains("引用了未登记的字幕素材") })
    }

    func testRegistryKnowsAllPayloadTypes() {
        XCTAssertTrue(TrackFeatureRegistry.payloadCodecs.keys.contains("clip"))
        XCTAssertTrue(TrackFeatureRegistry.payloadCodecs.keys.contains("caption-cue"))
        XCTAssertTrue(TrackFeatureRegistry.payloadCodecs.keys.contains("caption-settings"))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/JangyCore && swift test --filter CaptionFeatureTests`
Expected: 编译失败 —— `cannot find 'CaptionCuePayload' in scope`

- [ ] **Step 3: 实现**

`Features/Caption/CaptionFeature.swift`：

```swift
import Foundation

/// 字幕轨的元素 payload：一条 cue。
/// v1 不做逐句样式——样式是轨级的，放 CaptionTrackSettings。
/// **位置以 PlanElement.at 为权威**，payload 里不再存 start（避免两个事实源）。
public struct CaptionCuePayload: Codable, Equatable, Sendable, TrackElementPayload {
    public static let payloadType = "caption-cue"

    public var text: String
    public var duration: TimeInterval

    public init(text: String, duration: TimeInterval) {
        self.text = text
        self.duration = duration
    }

    private enum CodingKeys: String, CodingKey { case text, duration }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
    }

    /// `type` 由 TrackPayload box 注入，这里只写自己的字段。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(duration, forKey: .duration)
    }
}

/// 字幕轨的轨级参数（原 CaptionTrack + CaptionStyle 的合体）。
public struct CaptionTrackSettings: Codable, Equatable, Sendable, TrackElementPayload {
    public static let payloadType = "caption-settings"

    public var fontSize: Double
    public var isBold: Bool
    public var isEnabled: Bool
    /// 字幕来源文件（登记表里的 .srt）。SRT 已退化为导入源，这里只为维持素材引用保护。
    public var sourceAssetID: UUID?

    public init(fontSize: Double = 48, isBold: Bool = true,
                isEnabled: Bool = true, sourceAssetID: UUID? = nil) {
        self.fontSize = fontSize
        self.isBold = isBold
        self.isEnabled = isEnabled
        self.sourceAssetID = sourceAssetID
    }

    /// 轨级参数不参与时间线。
    public var duration: TimeInterval { 0 }

    private enum CodingKeys: String, CodingKey {
        case fontSize, isBold, isEnabled, sourceAssetID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 48
        isBold = try container.decodeIfPresent(Bool.self, forKey: .isBold) ?? true
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        sourceAssetID = try container.decodeIfPresent(UUID.self, forKey: .sourceAssetID)
    }

    /// `type` 由 TrackPayload box 注入，这里只写自己的字段。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(isBold, forKey: .isBold)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(sourceAssetID, forKey: .sourceAssetID)
    }
}

/// 字幕轨特性（L2 片）。L3 引擎映射见同目录 CaptionEngine.swift。
public enum CaptionFeature: TrackFeature {
    public static let kind = TrackKind.caption
    public static let payloadTypes: [any TrackElementPayload.Type] = [
        CaptionCuePayload.self, CaptionTrackSettings.self,
    ]

    /// 轨级设置。settings 缺失或类型不对时回落默认值。
    public static func settings(of track: PlanTrack) -> CaptionTrackSettings {
        (track.settings?.value as? CaptionTrackSettings) ?? CaptionTrackSettings()
    }

    public static func validate(track: PlanTrack, context: TrackValidationContext) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        if track.placement != .absolute {
            issues.append(ValidationIssue(path: "tracks[\(track.id)].placement",
                                          message: "字幕轨必须是绝对定位（.absolute）"))
        }

        for (i, element) in track.elements.enumerated() {
            let path = "tracks[\(track.id)].elements[\(i)]"
            guard let at = element.at else {
                issues.append(ValidationIssue(path: "\(path).at", elementID: element.id,
                                              message: "绝对定位轨的元素必须带 at"))
                continue
            }
            if at < 0 {
                issues.append(ValidationIssue(path: "\(path).at", elementID: element.id,
                                              message: "字幕起点不能为负"))
            }
            if element.duration <= 0 {
                issues.append(ValidationIssue(path: "\(path)", elementID: element.id,
                                              message: "字幕时长必须为正"))
            }
            if at + element.duration > context.mainTrackEnd + EditPlanValidator.durationTolerance {
                issues.append(ValidationIssue(path: "\(path).at", elementID: element.id,
                                              message: "字幕超出主轨末端（主轨 \(context.mainTrackEnd)s）"))
            }
        }

        if let sourceID = settings(of: track).sourceAssetID {
            switch context.asset(withID: sourceID) {
            case nil:
                issues.append(ValidationIssue(path: "tracks[\(track.id)].settings.sourceAssetID",
                                              message: "引用了未登记的字幕素材: \(sourceID)"))
            case let asset? where asset.kind != .subtitle:
                issues.append(ValidationIssue(path: "tracks[\(track.id)].settings.sourceAssetID",
                                              message: "字幕来源必须是字幕素材，实际为 \(asset.kind.rawValue)"))
            default:
                break
            }
        }

        return issues
    }
}
```

- [ ] **Step 4: 注册 CaptionFeature**

`Features/Manifest.swift` 的 `features`：

```swift
    public static let features: [any TrackFeature.Type] = [
        VideoFeature.self,
        CaptionFeature.self,
    ]
```

- [ ] **Step 5: 运行确认通过**

Run: `cd Packages/JangyCore && swift test --filter CaptionFeatureTests`
Expected: PASS（7 个用例）

- [ ] **Step 6: 提交（只提交新增文件）**

```bash
git add Packages/JangyCore/Sources/JangyCore/Features/Caption \
        Packages/JangyCore/Tests/JangyCoreTests/CaptionFeatureTests.swift
git commit -m "Core: Caption 特性片（cue 逐句 payload + 轨级 settings）"
```

---

## Task 4: 纯 Swift SRT 解析器

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/SRTParser.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/SRTParserTests.swift`

**背景：** v3 → v4 迁移要把整片 SRT 展开成 cue 元素，这发生在 L2，而 `Kadr.Caption.load(srt:)` 在 L3（`kadr-captions`），不能用。SRT 是纯文本格式，写一个极简解析器。

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import JangyCore

final class SRTParserTests: XCTestCase {

    func testParsesBasicCues() {
        let srt = """
        1
        00:00:00,000 --> 00:00:02,500
        第一段：开场

        2
        00:00:02,500 --> 00:00:05,000
        第二段：中景

        """
        let cues = SRTParser.parse(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "第一段：开场")
        XCTAssertEqual(cues[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(cues[0].duration, 2.5, accuracy: 0.001)
        XCTAssertEqual(cues[1].text, "第二段：中景")
        XCTAssertEqual(cues[1].start, 2.5, accuracy: 0.001)
    }

    func testJoinsMultilineText() {
        let srt = "1\n00:00:01,000 --> 00:00:03,000\n第一行\n第二行\n\n"
        XCTAssertEqual(SRTParser.parse(srt).first?.text, "第一行\n第二行")
    }

    func testToleratesDotMillisecondSeparatorAndCRLF() {
        let srt = "1\r\n00:00:01.000 --> 00:00:02.000\r\n你好\r\n\r\n"
        let cues = SRTParser.parse(srt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].duration, 1.0, accuracy: 0.001)
    }

    func testSkipsMalformedBlocks() {
        let srt = "garbage without timeline\n\n1\n00:00:01,000 --> 00:00:02,000\n有效\n\n"
        let cues = SRTParser.parse(srt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "有效")
    }

    func testEmptyInputGivesNoCues() {
        XCTAssertTrue(SRTParser.parse("").isEmpty)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/JangyCore && swift test --filter SRTParserTests`
Expected: 编译失败 —— `cannot find 'SRTParser' in scope`

- [ ] **Step 3: 实现**

`SRTParser.swift`：

```swift
import Foundation

/// 极简 SRT 解析（纯 Swift，不依赖 KadrCaptions）。
/// 用途单一：v3 → v4 迁移时把整片 SRT 展开成 cue 元素。
/// 宽容策略——坏块跳过而不是抛错，保证迁移不会因一行脏数据整体失败。
public enum SRTParser {

    public struct Cue: Equatable, Sendable {
        public let text: String
        public let start: TimeInterval
        public let duration: TimeInterval
    }

    public static func parse(_ content: String) -> [Cue] {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
            .compactMap(parseBlock)
    }

    private static func parseBlock(_ block: String) -> Cue? {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let timelineIndex = lines.firstIndex(where: { $0.contains("-->") }),
              let (start, end) = parseTimeline(lines[timelineIndex]) else { return nil }

        let text = lines[(timelineIndex + 1)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, end > start else { return nil }

        return Cue(text: text, start: start, duration: end - start)
    }

    /// "00:00:01,000 --> 00:00:02,500"，毫秒分隔符逗号与点号都接受。
    private static func parseTimeline(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let start = parseTimestamp(parts[0]),
              let end = parseTimestamp(parts[1]) else { return nil }
        return (start, end)
    }

    private static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let text = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = text.components(separatedBy: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd Packages/JangyCore && swift test --filter SRTParserTests`
Expected: PASS（5 个用例）

- [ ] **Step 5: 提交**

```bash
git add Packages/JangyCore/Sources/JangyCore/SRTParser.swift \
        Packages/JangyCore/Tests/JangyCoreTests/SRTParserTests.swift
git commit -m "Core: 极简纯 Swift SRT 解析器（迁移用，不依赖 KadrCaptions）"
```

---

## Task 5: v3 → v4 迁移

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/PlanMigration.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/PlanMigrationTests.swift`
- Test fixture: `Packages/JangyCore/Tests/JangyCoreTests/Fixtures/plan-v3.json`

> **顺序说明：** 本任务在 Task 6（`EditPlan` 切换）**之前**做，因为 Task 6 的 `PlanLoader` 要接线到迁移实现。本任务自身不依赖 v4 `EditPlan` 的存在——它返回的是「构造 v4 plan 的中间结果」，Task 6 再把它接到 `EditPlan` 上。
>
> 为了让本任务独立可测，迁移产物用一个**只含轨道、不含 EditPlan** 的结构承载。

- [ ] **Step 1: 写 fixture**

把当前 v3 形状的样例工程落到 `Tests/JangyCoreTests/Fixtures/plan-v3.json`。在切换模型**之前**执行一次即可拿到：

```bash
cd Packages/JangyCore && swift run jangy-cli sample > Tests/JangyCoreTests/Fixtures/plan-v3.json
```

> 该文件是 3 clip（含一段 dissolve + 两段变速）+ 一条整片字幕 + 4 条素材登记的 v3 JSON。切换模型后 `sample` 会输出 v4，所以**必须在 Task 6 之前生成**。

- [ ] **Step 2: 写失败的测试**

```swift
import XCTest
@testable import JangyCore
@testable import JangyTestSupport

final class PlanMigrationTests: XCTestCase {

    private func fixtureData() throws -> Data {
        let url = Bundle.module.url(forResource: "plan-v3", withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    private func assetsDirectory(withAssets: Bool) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if withAssets { _ = try AssetSynthesizer.synthesize(into: dir) }
        return dir
    }

    func testLegacyDecodingReadsV3Shape() throws {
        let legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: try fixtureData())
        XCTAssertEqual(legacy.clips.count, 3)
        XCTAssertEqual(legacy.captions?.style?.fontSize, 48)
        XCTAssertEqual(legacy.assets.count, 4)
    }

    func testMigrateBuildsSingleChainedPrimaryTrack() throws {
        let legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: try fixtureData())
        let dir = try assetsDirectory(withAssets: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = PlanMigration.migrate(legacy, assetsDirectory: dir)
        XCTAssertEqual(result.tracks.count, 2, "主轨 + 字幕轨")
        XCTAssertEqual(result.primaryTrackID, result.tracks[0].id)
        XCTAssertEqual(result.tracks[0].placement, .chained)
        XCTAssertEqual(result.tracks[0].elements.count, 3)
        XCTAssertEqual(result.tracks[0].elements[0].id,
                       UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                       "元素 id 继承原 clip id")
    }

    func testMigratedDurationMatchesV3Anchor() throws {
        let legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: try fixtureData())
        let dir = try assetsDirectory(withAssets: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = PlanMigration.migrate(legacy, assetsDirectory: dir)
        let total = result.tracks[0].elements.reduce(0.0) { $0 + $1.duration }
        // 3s@1x + 3s@0.5x + 2s@2x，挂 0.5s dissolve → 输出 9.5s
        XCTAssertEqual(total - 0.5, 9.5, accuracy: 0.001)
    }

    func testCuesExpandFromSRTWhenAssetsPresent() throws {
        let legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: try fixtureData())
        let dir = try assetsDirectory(withAssets: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = PlanMigration.migrate(legacy, assetsDirectory: dir)
        let captionTrack = result.tracks.first { $0.kind == .caption }
        XCTAssertEqual(captionTrack?.elements.count, 2, "sample.srt 有两条 cue")
        XCTAssertEqual(captionTrack?.elements[0].at, 0, "cue 位置进 element.at")
        XCTAssertEqual(CaptionFeature.settings(of: captionTrack!).sourceAssetID,
                       SamplePlan.captionAssetID, "来源素材引用保留")
    }

    func testMissingSRTLeavesEmptyCaptionTrackWithoutThrowing() throws {
        let legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: try fixtureData())
        let dir = try assetsDirectory(withAssets: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = PlanMigration.migrate(legacy, assetsDirectory: dir)
        let captionTrack = result.tracks.first { $0.kind == .caption }
        XCTAssertEqual(captionTrack?.elements.count, 0, "SRT 缺失时留空轨，不抛错")
        XCTAssertEqual(CaptionFeature.settings(of: captionTrack!).sourceAssetID,
                       SamplePlan.captionAssetID, "settings 保留来源，供完整性报告提示")
    }

    func testMissingAssetsDirectoryStillProducesStructure() throws {
        let legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: try fixtureData())
        let result = PlanMigration.migrate(legacy, assetsDirectory: nil)
        XCTAssertEqual(result.tracks.count, 2)
        XCTAssertEqual(result.tracks.first { $0.kind == .caption }?.elements.count, 0)
    }
}
```

- [ ] **Step 3: 运行确认失败**

Run: `cd Packages/JangyCore && swift test --filter PlanMigrationTests`
Expected: 编译失败 —— `cannot find 'LegacyPlanV3' in scope`

- [ ] **Step 4: 实现**

`PlanMigration.swift`：

```swift
import Foundation

/// v3 及更早的 plan 形状。仅用于迁移读取，不参与 v4 编码。
struct LegacyPlanV3: Decodable {
    var version: Int?
    var assets: [AssetItem]
    var clips: [LegacyClipV3]
    var captions: LegacyCaptionTrackV3?
    var preset: OutputPreset?

    struct LegacyClipV3: Decodable {
        var id: UUID?
        var assetID: UUID
        var source: PlanClipSource?
        var range: ClosedRange<TimeInterval>?
        var speed: SpeedPlan?
        var transitionAfter: PlanTransition?
    }

    struct LegacyCaptionTrackV3: Decodable {
        var assetID: UUID
        var isEnabled: Bool?
        var style: LegacyCaptionStyleV3?

        struct LegacyCaptionStyleV3: Decodable {
            var fontSize: Double?
            var isBold: Bool?
        }
    }
}

/// 迁移产物：只含轨道与素材，不含 EditPlan（Task 6 才引入 v4 的 EditPlan）。
struct MigratedPlanParts {
    var assets: [AssetItem]
    var tracks: [PlanTrack]
    var primaryTrackID: UUID
    var preset: OutputPreset
}

/// v3 → v4：扁平 clips → 单主轨；整片 captions → 绝对定位字幕轨。
enum PlanMigration {

    static func migrate(_ legacy: LegacyPlanV3, assetsDirectory: URL?) -> MigratedPlanParts {
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: legacy.clips.map { clip in
            PlanElement(id: clip.id ?? UUID(),
                        content: .content(TrackPayload(PlanClip(
                            assetID: clip.assetID,
                            source: clip.source ?? clip.range.map { .video($0) } ?? .video(0...0),
                            speed: clip.speed ?? .flat(1.0),
                            transitionAfter: clip.transitionAfter))))
        })

        var tracks = [primary]
        if let captions = legacy.captions {
            tracks.append(makeCaptionTrack(captions, assets: legacy.assets, assetsDirectory: assetsDirectory))
        }

        return MigratedPlanParts(assets: legacy.assets, tracks: tracks,
                                 primaryTrackID: primary.id, preset: legacy.preset ?? .reelsAndShorts)
    }

    /// SRT 可读时展开成 cue 元素；不可读时留空轨——settings 保留 sourceAssetID，
    /// 工程完整性报告会显式提示，不静默丢。
    private static func makeCaptionTrack(_ legacy: LegacyPlanV3.LegacyCaptionTrackV3,
                                         assets: [AssetItem],
                                         assetsDirectory: URL?) -> PlanTrack {
        let settings = CaptionTrackSettings(
            fontSize: legacy.style?.fontSize ?? 48,
            isBold: legacy.style?.isBold ?? true,
            isEnabled: legacy.isEnabled ?? true,
            sourceAssetID: legacy.assetID)

        var elements: [PlanElement] = []
        if let assetsDirectory,
           let fileName = assets.first(where: { $0.id == legacy.assetID })?.fileName,
           let text = try? String(contentsOf: assetsDirectory.appendingPathComponent(fileName),
                                  encoding: .utf8) {
            elements = SRTParser.parse(text).map { cue in
                PlanElement(at: cue.start,
                            content: .content(TrackPayload(
                                CaptionCuePayload(text: cue.text, duration: cue.duration))))
            }
        }

        return PlanTrack(kind: .caption, placement: .absolute,
                         settings: TrackPayload(settings), elements: elements)
    }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `cd Packages/JangyCore && swift test --filter PlanMigrationTests`
Expected: PASS（6 个用例）

- [ ] **Step 6: 提交**

```bash
git add Packages/JangyCore/Sources/JangyCore/PlanMigration.swift \
        Packages/JangyCore/Tests/JangyCoreTests/PlanMigrationTests.swift \
        Packages/JangyCore/Tests/JangyCoreTests/Fixtures/plan-v3.json
git commit -m "Core: v3 → v4 迁移（clips → 主轨，SRT 展开成逐句 cue）"
```

---

## Task 6: EditPlan 切到 v4 模型（Sources 全量适配）

**Files:**
- Modify: `Packages/JangyCore/Sources/JangyCore/EditPlan.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/EditPlanValidator.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/TimelineDuration.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/EngineBridge.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/PlanLoader.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/ProjectStore.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/ProjectPackage.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/ReferenceScanner.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/CoverGenerator.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/PreviewBridge.swift`
- Modify: `Packages/JangyCore/Sources/JangyAgent/AgentTools.swift`
- Modify: `Packages/JangyCore/Sources/jangy-cli/JangyCLI.swift`
- Modify: `Packages/JangyCore/Sources/JangyTestSupport/SamplePlan.swift`

> **本任务与 Task 7、Task 8 是一个不可分割的工作单元。** 中间态不编译；三个任务全部完成、`swift build` + `swift test` 通过后一次性提交。

- [ ] **Step 1: 换 EditPlan 容器**

```swift
/// 唯一事实源：撤销栈快照、磁盘存档、CLI 输入、Agent 生成目标共用此模型。
///
/// v4：扁平 `clips` + 整片 `captions` 换成 `tracks`。主轨由 `primaryTrackID` 显式指向，
/// 不靠「第一条就是主轨」的约定。轨道类型开放（TrackKind 包 String），
/// 元素 payload 由注册的特性模块解释（见 Features/Manifest.swift）。
public struct EditPlan: Codable, Equatable, Sendable {
    public var version: Int
    public var assets: [AssetItem]
    public var tracks: [PlanTrack]
    public var primaryTrackID: UUID
    public var preset: OutputPreset

    public init(version: Int = 4, assets: [AssetItem] = [],
                tracks: [PlanTrack], primaryTrackID: UUID,
                preset: OutputPreset = .reelsAndShorts) {
        self.version = version
        self.assets = assets
        self.tracks = tracks
        self.primaryTrackID = primaryTrackID
        self.preset = preset
    }

    /// 主轨（链式，决定成片时长）。校验器保证它存在且 placement == .chained。
    public var primaryTrack: PlanTrack? { tracks.first { $0.id == primaryTrackID } }

    /// 按 ID 查素材登记项。引擎层/表现层取素材元数据的唯一入口。
    public func asset(withID id: UUID) -> AssetItem? { assets.first { $0.id == id } }
}
```

**同时删除** `CaptionTrack` 与 `CaptionStyle` 两个类型（已被 `CaptionTrackSettings` 取代）。`PlanClipSource` / `SpeedPlan` / `PlanTransition` / `PlanClip` 保留（`PlanClip` 已按 Task 2 改造）。

- [ ] **Step 2: 改 TimelineDuration.swift**

```swift
extension EditPlan {
    /// 渲染输出总时长（实测口径）= 主轨链长 = Σ 元素输出时长 − Σ 转场重叠量。
    /// 样例工程实测锚点：3s@1x + 3s@0.5x + 2s@2x 挂 0.5s dissolve → 9.5s
    /// （≠ Kadr.Video.duration 求和值 10.5s）。e2e 断言基于此属性。
    ///
    /// 多轨不变式：主轨从 0 起连续覆盖 [0, renderedDuration]，其他轨元素不得超出主轨末端
    /// （由 TrackOperations 维持、EditPlanValidator 兜底）。故成片时长恒等于主轨链长。
    public var renderedDuration: TimeInterval {
        guard let track = primaryTrack else { return 0 }
        return track.elements.reduce(0) { total, element in
            var overlap: TimeInterval = 0
            if case .content(let payload) = element.content,
               let clip = payload.value as? PlanClip,
               let transition = clip.transitionAfter {
                overlap = transition.overlapDuration
            }
            return total + element.duration - overlap
        }
    }
}
```

- [ ] **Step 3: 改 EditPlanValidator.swift**

`ValidationIssue` 已在 Task 2 Step 4 加好 `elementID`。`validate(_:)` 整体替换：

```swift
    public func validate(_ plan: EditPlan) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        // 登记表自身一致性：ID 唯一
        var seen: Set<UUID> = []
        for (i, asset) in plan.assets.enumerated() {
            if !seen.insert(asset.id).inserted {
                issues.append(ValidationIssue(path: "assets[\(i)].id", message: "素材 ID 重复: \(asset.id)"))
            }
        }

        // 轨道自身一致性：ID 唯一；kind 必须有注册的特性模块
        var trackIDs: Set<UUID> = []
        for (i, track) in plan.tracks.enumerated() {
            if !trackIDs.insert(track.id).inserted {
                issues.append(ValidationIssue(path: "tracks[\(i)].id", message: "轨道 ID 重复: \(track.id)"))
            }
            if TrackFeatureRegistry.feature(for: track.kind) == nil {
                issues.append(ValidationIssue(path: "tracks[\(i)].kind",
                                              message: "未注册的轨道类型 '\(track.kind.rawValue)'"))
            }
        }

        // 主轨：必须存在、链式、非空
        guard let primary = plan.primaryTrack else {
            issues.append(ValidationIssue(path: "primaryTrackID", message: "主轨不存在: \(plan.primaryTrackID)"))
            return issues
        }
        if primary.placement != .chained {
            issues.append(ValidationIssue(path: "primaryTrackID", message: "主轨必须是链式（.chained）"))
        }
        if primary.elements.isEmpty {
            issues.append(ValidationIssue(path: "tracks[\(primary.id)].elements", message: "主轨至少需要一个元素"))
        }

        // 逐轨分派给特性模块。
        // mainTrackEnd 必须是 renderedDuration（扣过转场重叠的成片时长），
        // 不能用 primary.span——链式轨的 span 是 Σ 元素时长，样例工程两者差 0.5s。
        let context = TrackValidationContext(assets: plan.assets,
                                             mainTrackEnd: plan.renderedDuration,
                                             tracks: plan.tracks)
        for track in plan.tracks {
            if let feature = TrackFeatureRegistry.feature(for: track.kind) {
                issues.append(contentsOf: feature.validate(track: track, context: context))
            }
        }

        // 核心不变式兜底：任何轨的元素不得超出主轨末端。
        // 用 renderedDuration 而非 primary.span——链式轨的 span 不含转场重叠。
        let mainEnd = plan.renderedDuration
        for track in plan.tracks where track.id != primary.id {
            for (i, element) in track.elements.enumerated() {
                let end = (element.at ?? 0) + element.duration
                if end > mainEnd + Self.durationTolerance {
                    issues.append(ValidationIssue(
                        path: "tracks[\(track.id)].elements[\(i)].at", elementID: element.id,
                        message: "元素末端 \(end)s 超出主轨末端 \(mainEnd)s"))
                }
            }
        }

        return issues
    }
```

`validateAssets` 不变。

- [ ] **Step 4: 改 EngineBridge.swift**

```swift
    public static func makeComposition(from plan: EditPlan, resolver: AssetResolver,
                                       options: ExportOptions = .default) async throws -> Kadr.Video {
        let preset: Kadr.Preset
        switch plan.preset {
        case .reelsAndShorts:
            preset = options.hdrPassthrough
                ? .reelsAndShorts
                : .custom(width: 1080, height: 1920, frameRate: 30, codec: .h264)
        }

        guard let primary = plan.primaryTrack else { throw MissingPrimaryTrackError() }

        // 主轨：链式。gap 映射成纯黑 ImageClip，链保持连续（转场路径不受影响）。
        var elements: [any Kadr.Clip] = []
        for element in primary.elements {
            switch element.content {
            case .gap(let duration):
                elements.append(Kadr.ImageClip.color(PlatformColor.black, duration: duration))
            case .content(let payload):
                guard let clip = payload.value as? PlanClip else {
                    throw UnknownPayloadError(kind: primary.kind, payloadType: payload.payloadType)
                }
                guard let asset = plan.asset(withID: clip.assetID) else {
                    throw MissingAssetError(assetID: clip.assetID)
                }
                let sourceURL = resolver.resolve(asset)
                switch clip.source {
                case .video(let range):
                    var videoClip = Kadr.VideoClip(url: sourceURL).trimmed(to: range)
                    if clip.speed.rate != 1.0 {
                        videoClip = videoClip.speed(.flat(clip.speed.rate))
                    }
                    elements.append(videoClip)
                case .still(let duration):
                    guard let image = StillImagePreparer.prepare(url: sourceURL, canvas: preset.resolution) else {
                        throw ImageDecodeError(assetID: clip.assetID)
                    }
                    elements.append(Kadr.ImageClip(image, duration: duration / clip.speed.rate))
                }
                if let transition = clip.transitionAfter {
                    elements.append(kadrTransition(transition))
                }
            }
        }

        // 叠加视频轨 → Kadr.Track。Track 本身是 Clip，直接进 builder 数组
        // （Kadr.Video 没有 track(_:) modifier）。声明顺序 = 绘制顺序，后面的盖前面的。
        for track in plan.tracks where track.id != primary.id && track.kind == .video {
            elements.append(try await VideoEngine.makeParallelTrack(track: track, plan: plan,
                                                                    resolver: resolver, preset: preset))
        }

        var video = Kadr.Video {
            for element in elements { element }
        }.preset(preset)

        // 字幕轨（可能多条，accumulate）
        for track in plan.tracks where track.kind == .caption {
            let cues = CaptionEngine.makeCues(track: track)
            guard !cues.isEmpty else { continue }
            video = video.captions(cues)
            for cue in cues {
                video = video.overlay(captionOverlay(cue, style: CaptionFeature.settings(of: track)))
            }
        }
        return video
    }
```

`captionOverlay` 签名改为吃 `CaptionTrackSettings`：

```swift
    /// 字幕烧录 overlay：预渲染图片而非 Kadr.TextOverlay。
    /// 原因（实测隔离，详见 CaptionImageRenderer 注释）：macOS headless 导出中
    /// AVVideoCompositionCoreAnimationTool 不绘制 CATextLayer 文字，TextOverlay 全部隐形；
    /// ImageOverlay（CGImage contents）则稳定可见。
    static func captionOverlay(_ cue: Kadr.Caption, style: CaptionTrackSettings) -> Kadr.ImageOverlay {
        let image = CaptionImageRenderer.render(cue.text, fontSize: style.fontSize, isBold: style.isBold)
        return Kadr.ImageOverlay(image)
            .position(.normalized(x: 0.5, y: 0.92))
            .anchor(.bottom)
            .visible(during: cue.timeRange)
    }
```

新增错误类型：

```swift
    /// plan 的 primaryTrackID 指向的轨道不存在。
    public struct MissingPrimaryTrackError: Error, CustomStringConvertible {
        public var description: String { "plan 没有主轨（primaryTrackID 指向的轨道不存在）" }
    }

    /// 轨道类型与 payload 类型对不上（如视频轨里塞了字幕 cue）。
    public struct UnknownPayloadError: Error, CustomStringConvertible {
        public let kind: TrackKind
        public let payloadType: String
        public var description: String { "轨道类型 \(kind.rawValue) 不认识 payload 类型 '\(payloadType)'" }
    }
```

- [ ] **Step 5: 改 PlanLoader.swift**

```swift
public enum PlanLoader {

    /// - Parameter assetsDirectory: 提供时，v3 及更早的 plan 会就地迁移（含 SRT 展开）。
    public static func load(from url: URL, assetsDirectory: URL? = nil) throws -> EditPlan {
        let data = try Data(contentsOf: url)
        return try decode(data, assetsDirectory: assetsDirectory)
    }

    static func decode(_ data: Data, assetsDirectory: URL?) throws -> EditPlan {
        let probe: VersionProbe
        do {
            probe = try JSONDecoder().decode(VersionProbe.self, from: data)
        } catch let error as DecodingError {
            let (path, message) = describe(error)
            throw PlanLoaderError.decodingFailed(path: path, message: message)
        }

        if (probe.version ?? 4) >= 4 {
            do {
                return try JSONDecoder().decode(EditPlan.self, from: data)
            } catch let error as DecodingError {
                let (path, message) = describe(error)
                throw PlanLoaderError.decodingFailed(path: path, message: message)
            }
        }

        let legacy: LegacyPlanV3
        do {
            legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: data)
        } catch let error as DecodingError {
            let (path, message) = describe(error)
            throw PlanLoaderError.decodingFailed(path: path, message: message)
        }
        let parts = PlanMigration.migrate(legacy, assetsDirectory: assetsDirectory)
        return EditPlan(version: 4, assets: parts.assets, tracks: parts.tracks,
                        primaryTrackID: parts.primaryTrackID, preset: parts.preset)
    }

    struct VersionProbe: Decodable { let version: Int? }

    // describe / pathString 不变
}
```

- [ ] **Step 6: 改 L2 基础设施**

`ProjectStore.swift`：

```swift
    public static let currentSchemaVersion = 4
```

`loadProject` 与 `migrateLegacyLayoutIfNeeded` 里的 load 加素材目录：

```swift
        let plan = try PlanLoader.load(from: url, assetsDirectory: assetsDir)
```

其中 `assetsDir` = `root.appendingPathComponent(AssetLibrary.assetsDirName, isDirectory: true)`。

`createProject`：

```swift
    public func createProject(name: String) throws -> ProjectSummary {
        let id = UUID()
        let dir = projectDirectory(id: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try saveMeta(ProjectMeta(id: id, name: name))
        let primary = PlanTrack(kind: .video, placement: .chained)
        try saveProject(id: id, plan: EditPlan(tracks: [primary], primaryTrackID: primary.id))
        return try summary(for: id)
    }
```

`summary(for:)` 的 `clipCount`：

```swift
                              clipCount: plan.primaryTrack?.elements.count ?? 0,
```

`ProjectPackage.swift` / `ReferenceScanner.swift` / `CoverGenerator.swift`：把 `plan.clips` 的遍历换成 `plan.primaryTrack?.elements ?? []`，`plan.captions` 换成 `plan.tracks.first { $0.kind == .caption }`。逐个编译错误点改。

`PreviewBridge.swift`：**无需改动**——它只调 `EngineBridge.makeComposition` 和读 `video.captions`。若编译报错说明改漏了别处。

- [ ] **Step 7: 改 SamplePlan.swift**

```swift
    public static func make() -> EditPlan {
        let primary = PlanTrack(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                                kind: .video, placement: .chained, elements: [
            PlanElement(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                        content: .content(TrackPayload(PlanClip(
                            assetID: assetID1, source: .video(0...3), speed: .flat(1.0),
                            transitionAfter: .dissolve(duration: 0.5))))),
            PlanElement(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                        content: .content(TrackPayload(PlanClip(
                            assetID: assetID2, source: .video(0...3), speed: .flat(0.5))))),
            PlanElement(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                        content: .content(TrackPayload(PlanClip(
                            assetID: assetID3, source: .video(0...2), speed: .flat(2.0))))),
        ])

        let captionTrack = PlanTrack(id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                                     kind: .caption, placement: .absolute,
                                     settings: TrackPayload(CaptionTrackSettings(
                                        fontSize: 48, isBold: true, isEnabled: true,
                                        sourceAssetID: captionAssetID)),
                                     elements: captionElements())

        return EditPlan(assets: [/* 4 条 AssetItem，不变 */],
                        tracks: [primary, captionTrack], primaryTrackID: primary.id)
    }

    /// 与 AssetSynthesizer 产出的 sample.srt 一一对应。
    /// 实现时读 `AssetSynthesizer.srtFileName` 的内容核对文案与时间点。
    private static func captionElements() -> [PlanElement] {
        [
            PlanElement(id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
                        at: 0, content: .content(TrackPayload(
                            CaptionCuePayload(text: "第一段：开场", duration: 2.5)))),
            PlanElement(id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
                        at: 2.5, content: .content(TrackPayload(
                            CaptionCuePayload(text: "第二段：中景", duration: 2.5)))),
        ]
    }
```

> **必须与 `AssetSynthesizer` 实际生成的 sample.srt 一致**——`ExportEndToEndTests` 的像素级断言锚在「t=1.0 有字幕、t=2.8 无字幕」。实现时先 `cat` 生成的 sample.srt 核对。

- [ ] **Step 8: 改 jangy-cli**

`JangyCLI.swift` 的 `loadValidatedPlan`：

```swift
    let plan: EditPlan
    do {
        plan = try PlanLoader.load(from: URL(fileURLWithPath: path),
                                   assetsDirectory: URL(fileURLWithPath: assets))
    } catch let error as PlanLoaderError {
        CLIError.stderr("\(error)")
        throw ExitCode(1)
    }
```

其余子命令无需改动（都经 `loadValidatedPlan` 或 `SamplePlan`）。

- [ ] **Step 9: 改 AgentTools.swift 让它编译（行为等价，签名改造留 Task 12）**

`AgentToolCommon.clipIndex` → 全轨定位：

```swift
    /// 元素定位：elementID → (轨道下标, 元素下标)。
    struct ElementLocation { let trackIndex: Int; let elementIndex: Int }

    static func locate(_ plan: EditPlan, elementID: String) -> Result<ElementLocation, LookupError> {
        guard let uuid = UUID(uuidString: elementID) else {
            return .failure(LookupError(message: ToolEnvelope.error("无效的元素 ID: \(elementID)")))
        }
        for (ti, track) in plan.tracks.enumerated() {
            if let ei = track.elements.firstIndex(where: { $0.id == uuid }) {
                return .success(ElementLocation(trackIndex: ti, elementIndex: ei))
            }
        }
        return .failure(LookupError(message: ToolEnvelope.error(
            "找不到元素 \(elementID)，请先用 get_plan 获取当前元素 ID")))
    }

    /// 主轨下标（`add_clip` 等主轨操作仍按主轨定位）。
    static func primaryTrackIndex(_ plan: EditPlan) -> Int? {
        plan.tracks.firstIndex { $0.id == plan.primaryTrackID }
    }
```

各工具的写入侧改为：

```swift
            let result = store.apply { plan in
                guard let ti = AgentToolCommon.primaryTrackIndex(plan) else { return }
                plan.tracks[ti].elements.append(
                    PlanElement(content: .content(TrackPayload(clip))))
            }
```

读取/改写侧（`split_clip` / `trim_clip` / `set_speed` / `set_transition` / `remove_clip`）统一用「定位 → 解包 → 改 → 装回」：

```swift
            let location: AgentToolCommon.ElementLocation
            switch AgentToolCommon.locate(store.plan, elementID: args.clipID) {
            case .success(let found): location = found
            case .failure(let error): return error.message
            }

            let result = store.apply { plan in
                guard case .content(let payload) = plan.tracks[location.trackIndex]
                        .elements[location.elementIndex].content,
                      var clip = payload.value as? PlanClip else { return }
                // ↓ 各工具在这里改 clip 的某个字段
                clip.speed = .flat(args.rate)
                plan.tracks[location.trackIndex].elements[location.elementIndex].content =
                    .content(TrackPayload(clip))
            }
```

`remove_clip` 例外——它不走解包/装回，直接调核心操作：

```swift
            let result = store.apply { plan in
                TrackOperations.removeElement(elementID, in: &plan)
            }
```

`SetCaptionsTool`：找到或新建 caption 轨，写 `settings` 与 cue 元素（**Task 12 会再改签名**，本步保证等价行为）。

- [ ] **Step 10: 构建通过**

Run: `cd Packages/JangyCore && swift build`
Expected: `Build complete!`

- [ ] **Step 11: 提交（Task 6 + 7 + 8 一起）**

见 Task 8 Step 5。

---

## Task 7: 测试与脚手架适配

**Files:**
- Create: `Packages/JangyCore/Tests/JangyCoreTests/PlanTestSupport.swift`
- Modify: `Packages/JangyCore/Tests/JangyCoreTests/*.swift`
- Modify: `Packages/JangyCore/Tests/JangyAgentTests/*.swift`

- [ ] **Step 1: 建测试脚手架**

`Tests/JangyCoreTests/PlanTestSupport.swift`：

```swift
import Foundation
@testable import JangyCore

/// 老测试的最常见形状是「一组 clip 的扁平 plan」，这里收敛它的构造与读取。
enum PlanTestSupport {

    static func plan(assets: [AssetItem] = [], clips: [PlanClip],
                     captionSettings: CaptionTrackSettings? = nil,
                     cues: [PlanElement] = []) -> EditPlan {
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: clips.map { PlanElement(content: .content(TrackPayload($0))) })
        var tracks = [primary]
        if let captionSettings {
            tracks.append(PlanTrack(kind: .caption, placement: .absolute,
                                    settings: TrackPayload(captionSettings), elements: cues))
        }
        return EditPlan(assets: assets, tracks: tracks, primaryTrackID: primary.id)
    }

    /// 主轨第 i 个元素解出的 clip。
    static func clip(_ plan: EditPlan, _ i: Int) -> PlanClip? {
        plan.primaryTrack?.elements[i].content.clipPayload
    }
}

extension ElementContent {
    /// 内容是视频 clip 时解出来，否则 nil（gap / 别的 payload）。
    var clipPayload: PlanClip? {
        guard case .content(let payload) = self else { return nil }
        return payload.value as? PlanClip
    }
}
```

- [ ] **Step 2: 跑测试看失败面**

Run: `cd Packages/JangyCore && swift test 2>&1 | head -60`
Expected: 编译失败，列出所有用旧 API 的测试文件。

- [ ] **Step 3: 逐文件改**

机械替换规则：

| 旧 | 新 |
|---|---|
| `plan.clips`（读 clip） | `plan.primaryTrack!.elements.compactMap(\.content.clipPayload)` |
| `plan.clips`（读元素/下标） | `plan.primaryTrack!.elements` |
| `plan.clips[i].speed = x` | 取元素 → 解 payload → 改 → 写回 `plan.primaryTrack` 对应元素 |
| `clip.id` | `element.id` |
| `EditPlan(clips: [...])` | `PlanTestSupport.plan(clips: [...])` |
| `plan.captions` | `plan.tracks.first { $0.kind == .caption }` |
| `CaptionTrack(assetID:isEnabled:style:)` | `CaptionTrackSettings(fontSize:isBold:isEnabled:sourceAssetID:)` |

`EditStore.apply` 闭包里的下标写入示例：

```swift
        store.apply { plan in
            guard let ti = plan.tracks.firstIndex(where: { $0.id == plan.primaryTrackID }),
                  case .content(let payload) = plan.tracks[ti].elements[0].content,
                  let clip = payload.value as? PlanClip else { return }
            var updated = clip
            updated.speed = .flat(0.5)
            plan.tracks[ti].elements[0].content = .content(TrackPayload(updated))
        }
```

> 这个「解包 → 改 → 装回」的模式会重复出现。**在 `PlanTestSupport.swift` 里加一个 helper 收敛它**：

```swift
extension EditPlan {
    /// 在主轨上就地改某个元素的 payload（测试用）。
    mutating func updateClip(at index: Int, _ mutate: (inout PlanClip) -> Void) {
        guard let ti = tracks.firstIndex(where: { $0.id == primaryTrackID }),
              case .content(let payload) = tracks[ti].elements[index].content,
              var clip = payload.value as? PlanClip else { return }
        mutate(&clip)
        tracks[ti].elements[index].content = .content(TrackPayload(clip))
    }
}
```

- [ ] **Step 4: 测试全绿**

Run: `cd Packages/JangyCore && swift test`
Expected: 全部通过（既有 176 个用例的等价改写 + Task 1–5 新增用例）

- [ ] **Step 5: 提交（连同 Task 6、Task 8）**

```bash
git add -A Packages/JangyCore
git commit -m "Core: EditPlan 切换到多轨 v4 模型（clips/captions → tracks）"
```

---

## Task 8: App 最小适配（保证编译）

**Files:**
- Modify: `Jangy/AppModel.swift`
- Modify: `Jangy/TimelineView.swift`
- Modify: `Jangy/EditorView.swift`
- Modify: `Jangy/AgentController.swift`
- Modify: `Jangy/ProjectListModel.swift` / `Jangy/LibraryModel.swift`（若引用 `plan.clips`）

> 只保证 **App 编译通过 + 行为与今天一致**。时间线 UI 的真正改造属阶段②。

- [ ] **Step 1: 改 AppModel**

`appendAssetToTimeline` / `appendImageToTimeline` 的追加改成往主轨写：

```swift
    /// 往主轨追加一个元素（本文件三处上轨入口共用）。
    private static func appendClip(_ clip: PlanClip, to plan: inout EditPlan) {
        guard let index = plan.tracks.firstIndex(where: { $0.id == plan.primaryTrackID }) else { return }
        plan.tracks[index].elements.append(PlanElement(content: .content(TrackPayload(clip))))
    }
```

三处调用点改为 `Self.appendClip(PlanClip(...), to: &plan)`。

- [ ] **Step 2: 改 TimelineView / EditorView**

- `model.store.plan.clips` → `model.store.plan.primaryTrack?.elements ?? []`
- `model.store.plan.clips.isEmpty` → `model.store.plan.primaryTrack?.elements.isEmpty ?? true`
- 字幕开关：`model.store.plan.captions?.isEnabled` → 读字幕轨 settings

`TimelineView` 的四个私有方法逐个改写。`delete` 改成把元素换成等长 gap（与阶段①的删除语义一致）：

```swift
    private func delete(_ index: Int) {
        model.edit { plan in
            guard let ti = plan.tracks.firstIndex(where: { $0.id == plan.primaryTrackID }) else { return }
            let element = plan.tracks[ti].elements[index]
            plan.tracks[ti].elements[index] = PlanElement(id: element.id,
                                                          content: .gap(duration: element.duration))
        }
    }
```

`toggleTrim` / `cycleSpeed` / `toggleTransition` 用 `plan.updateClip(at:)` 同款模式改写（把 `PlanTestSupport.swift` 里的 `updateClip` helper 提到 JangyCore 里作为 `EditPlan` 的公开便利方法，App 与测试共用——**这是本任务唯一允许的新增公开 API**）：

```swift
extension EditPlan {
    /// 在主轨上就地改某个元素的 payload。取不到（下标越界 / 是 gap / payload 类型不对）时是 no-op。
    public mutating func updatePrimaryClip(at index: Int, _ mutate: (inout PlanClip) -> Void) {
        guard let ti = tracks.firstIndex(where: { $0.id == primaryTrackID }),
              case .content(let payload) = tracks[ti].elements[index].content,
              var clip = payload.value as? PlanClip else { return }
        mutate(&clip)
        tracks[ti].elements[index].content = .content(TrackPayload(clip))
    }
}
```

- [ ] **Step 3: App 构建通过**

Run:
```bash
xcodebuild -project Jangy.xcodeproj -scheme Jangy \
  -destination 'generic/platform=iOS Simulator' build
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: CLI 冒烟**

Run:
```bash
cd Packages/JangyCore
swift run jangy-cli genassets --to /tmp/jangy-assets
swift run jangy-cli sample > /tmp/jangy-draft.json
swift run jangy-cli validate /tmp/jangy-draft.json --assets /tmp/jangy-assets
swift run jangy-cli export /tmp/jangy-draft.json -o /tmp/jangy-out.mp4 --assets /tmp/jangy-assets
```
Expected: `validate` 输出 `{"valid":true}`；`export` 输出 progress/done JSONL 且退出码 0

- [ ] **Step 5: 提交（Task 6 + 7 + 8 一起）**

```bash
git add -A Packages/JangyCore Jangy
git commit -m "Core: EditPlan 切换到多轨 v4 模型（clips/captions → tracks）"
```

---

## Task 9: gap 核心操作与两条不变式

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/TrackOperations.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/TrackOperationsTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import JangyCore

final class TrackOperationsTests: XCTestCase {

    private func makePlan(mainSeconds: [TimeInterval],
                          captionEnds: [TimeInterval] = []) -> EditPlan {
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: mainSeconds.map { PlanElement(content: .gap(duration: $0)) })
        var tracks = [primary]
        if !captionEnds.isEmpty {
            tracks.append(PlanTrack(kind: .caption, placement: .absolute,
                                    elements: captionEnds.map {
                PlanElement(at: $0 - 1, content: .content(TrackPayload(
                    CaptionCuePayload(text: "x", duration: 1))))
            }))
        }
        return EditPlan(tracks: tracks, primaryTrackID: primary.id)
    }

    func testRemovingMiddleElementReplacesItWithGap() {
        var plan = makePlan(mainSeconds: [3, 3, 3])
        TrackOperations.removeElement(plan.primaryTrack!.elements[1].id, in: &plan)

        XCTAssertEqual(plan.primaryTrack!.elements.count, 3, "元素位保留")
        XCTAssertEqual(plan.renderedDuration, 9, accuracy: 0.001, "时长不变")
        guard case .gap(let d) = plan.primaryTrack!.elements[1].content else {
            return XCTFail("中间元素应被换成 gap")
        }
        XCTAssertEqual(d, 3, accuracy: 0.001)
    }

    func testRemovingLastElementPadsTailWhenOtherTrackExtends() {
        var plan = makePlan(mainSeconds: [3, 3], captionEnds: [5])
        TrackOperations.removeElement(plan.primaryTrack!.elements[1].id, in: &plan)

        XCTAssertEqual(plan.primaryTrack!.span, 5, accuracy: 0.001, "主轨补到字幕轨末端")
        XCTAssertEqual(plan.renderedDuration, 5, accuracy: 0.001)
    }

    func testRemovingLastElementShrinksWhenNothingExtends() {
        var plan = makePlan(mainSeconds: [3, 3])
        TrackOperations.removeElement(plan.primaryTrack!.elements[1].id, in: &plan)

        XCTAssertEqual(plan.primaryTrack!.elements.count, 1)
        XCTAssertEqual(plan.renderedDuration, 3, accuracy: 0.001)
    }

    func testMovingElementBeyondMainEndPadsTailGap() {
        var plan = makePlan(mainSeconds: [3, 3])
        let cue = PlanElement(at: 6, content: .content(TrackPayload(
            CaptionCuePayload(text: "越界", duration: 2))))
        plan.tracks.append(PlanTrack(kind: .caption, placement: .absolute, elements: [cue]))

        TrackOperations.maintainInvariants(in: &plan)
        XCTAssertEqual(plan.primaryTrack!.span, 8, accuracy: 0.001, "主轨尾部补 gap 到 8s")
        XCTAssertEqual(plan.renderedDuration, 8, accuracy: 0.001)
    }

    func testClosingGapShiftsFollowingElementsEarlier() {
        var plan = makePlan(mainSeconds: [3, 3, 3])
        let middle = plan.primaryTrack!.elements[1].id
        TrackOperations.removeElement(middle, in: &plan)   // → gap
        TrackOperations.removeElement(middle, in: &plan)   // → 合上

        XCTAssertEqual(plan.primaryTrack!.elements.count, 2)
        XCTAssertEqual(plan.renderedDuration, 6, accuracy: 0.001)
    }

    func testRemovingElementFromAbsoluteTrackJustRemoves() {
        var plan = makePlan(mainSeconds: [10], captionEnds: [3, 6])
        let captionTrack = plan.tracks[1]
        TrackOperations.removeElement(captionTrack.elements[0].id, in: &plan)

        XCTAssertEqual(plan.tracks[1].elements.count, 1)
        XCTAssertEqual(plan.tracks[1].elements[0].at, 5, accuracy: 0.001, "绝对轨元素不被挪动")
        XCTAssertEqual(plan.primaryTrack!.span, 10, accuracy: 0.001, "主轨不受影响")
    }

    func testMaintainingInvariantsAccountsForTransitionOverlap() {
        // 主轨带转场：span(6) ≠ renderedDuration(5.5)。
        // 字幕轨末端 5.7s → 主轨必须补到 5.7s；按 span 算会得出「不用补」，漏掉 0.2s。
        let a = PlanClip(assetID: UUID(), source: .video(0...3),
                         transitionAfter: .dissolve(duration: 0.5))
        let b = PlanClip(assetID: UUID(), source: .video(0...3))
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(a))),
            PlanElement(content: .content(TrackPayload(b))),
        ])
        var plan = EditPlan(tracks: [primary], primaryTrackID: primary.id)
        XCTAssertEqual(plan.renderedDuration, 5.5, accuracy: 0.001)
        XCTAssertEqual(plan.primaryTrack!.span, 6, accuracy: 0.001)

        plan.tracks.append(PlanTrack(kind: .caption, placement: .absolute, elements: [
            PlanElement(at: 4.7, content: .content(TrackPayload(
                CaptionCuePayload(text: "x", duration: 1)))),   // 末端 5.7
        ]))

        TrackOperations.maintainInvariants(in: &plan)
        XCTAssertEqual(plan.renderedDuration, 5.7, accuracy: 0.01,
                       "主轨应补到字幕轨末端 5.7s（差额按 renderedDuration 算，不是 span）")
    }

    func testMaintainingInvariantsIsIdempotent() {
        var plan = makePlan(mainSeconds: [3, 3], captionEnds: [9])
        TrackOperations.maintainInvariants(in: &plan)
        let after = plan.primaryTrack!.elements.count
        TrackOperations.maintainInvariants(in: &plan)
        XCTAssertEqual(plan.primaryTrack!.elements.count, after, "重复调用不再追加 gap")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/JangyCore && swift test --filter TrackOperationsTests`
Expected: 编译失败 —— `cannot find 'TrackOperations' in scope`

- [ ] **Step 3: 实现**

`TrackOperations.swift`：

```swift
import Foundation

/// 轨级原子操作：**唯一**维持两条主轨不变式的地方。
/// 不变式由操作维持、校验器只做兜底（公约 §2.1 的形状）。
///
/// 1. 主轨从 0 起连续覆盖 [0, renderedDuration]，无隐式空洞
/// 2. 任何轨的元素不得超出主轨末端
public enum TrackOperations {

    /// 移除元素。
    /// - 链式轨的中间元素 → 原地换成等长 gap（内容消失、时长保留）
    /// - 链式轨的末尾元素 → 真正移除；若其他轨更靠后，随后由 maintainInvariants 补尾部 gap
    /// - 绝对轨元素 → 直接移除（主轨长度不受影响）
    public static func removeElement(_ elementID: UUID, in plan: inout EditPlan) {
        for (ti, track) in plan.tracks.enumerated() {
            guard let ei = track.elements.firstIndex(where: { $0.id == elementID }) else { continue }
            let element = track.elements[ei]
            if track.placement == .chained, ei < track.elements.count - 1 {
                plan.tracks[ti].elements[ei] = PlanElement(id: element.id,
                                                           content: .gap(duration: element.duration))
            } else {
                plan.tracks[ti].elements.remove(at: ei)
            }
            maintainInvariants(in: &plan)
            return
        }
    }

    /// 把元素放到绝对时间 `at`（仅绝对定位轨有意义）。
    public static func moveElement(_ elementID: UUID, to at: TimeInterval, in plan: inout EditPlan) {
        for (ti, track) in plan.tracks.enumerated() {
            guard let ei = track.elements.firstIndex(where: { $0.id == elementID }) else { continue }
            plan.tracks[ti].elements[ei].at = at
            maintainInvariants(in: &plan)
            return
        }
    }

    /// 维持两条不变式。任何改动主轨长度或绝对轨元素位置的编辑之后都要调一次。
    /// 幂等：满足条件时不追加任何元素。
    public static func maintainInvariants(in plan: inout EditPlan) {
        guard let pi = plan.tracks.firstIndex(where: { $0.id == plan.primaryTrackID }) else { return }

        // 主轨的「末端」是成片时长 renderedDuration（已扣转场重叠），不是它的 span。
        // 用 span 会少补：样例工程 span 10 vs renderedDuration 9.5，差额 0.5 会漏掉。
        let mainEnd = plan.renderedDuration
        var required = mainEnd
        for track in plan.tracks where track.id != plan.primaryTrackID {
            required = max(required, track.span)
        }

        let deficit = required - mainEnd
        if deficit > EditPlanValidator.durationTolerance {
            plan.tracks[pi].elements.append(PlanElement(content: .gap(duration: deficit)))
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd Packages/JangyCore && swift test --filter TrackOperationsTests`
Expected: PASS（8 个用例）

- [ ] **Step 5: 提交**

```bash
git add Packages/JangyCore/Sources/JangyCore/TrackOperations.swift \
        Packages/JangyCore/Tests/JangyCoreTests/TrackOperationsTests.swift
git commit -m "Core: gap 核心操作与主轨两条不变式（操作维持 + 校验器兜底）"
```

---

## Task 10: 引擎多轨映射（L3 特性片 + e2e）

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/Features/Video/VideoEngine.swift`
- Create: `Packages/JangyCore/Sources/JangyCore/Features/Caption/CaptionEngine.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/MultiTrackExportEndToEndTests.swift`

**已核实的事实（不要再重新验证）：** `Kadr.Video` **没有** `track(_:)` modifier——叠加轨要直接进 `Kadr.Video { }` 的 builder 数组（`Track` 本身是 `Clip`，见 Task 6 Step 4）。`Kadr.Track(name:content:)` 从 `.zero` 开始，元素用 `.at(time:)` 绝对定位。`Kadr.Preset.resolution` 存在。

- [ ] **Step 1: 写失败的 e2e 测试**

```swift
import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
@testable import JangyCore
@testable import JangyTestSupport

/// 多轨导出端到端：主轨 + 叠加视频轨（画中画）、主轨带 gap。
/// 素材为纯色视频（clip1 红 / clip2 绿 / clip3 蓝），像素级断言因此可行。
final class MultiTrackExportEndToEndTests: XCTestCase {
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

    private func videoAsset(_ name: String) -> AssetItem {
        AssetItem(kind: .video, fileName: name, origin: .synthesized,
                  duration: 4.0, pixelWidth: 1280, pixelHeight: 720, hasAudio: false)
    }

    private func export(_ plan: EditPlan, to name: String) async throws -> URL {
        let out = assetsDir.appendingPathComponent(name)
        for try await _ in ExportRunner.export(plan: plan, resolver: resolver, to: out) {}
        return out
    }

    /// 抽帧 → 指定相对矩形内的平均 RGB（0–255）。矩形按图像坐标，y 从顶部起算。
    private func meanColor(_ asset: AVAsset, at seconds: Double,
                           in rect: CGRect) throws -> (red: Double, green: Double, blue: Double) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let cg = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)

        let x0 = Int(rect.minX * Double(cg.width)), x1 = Int(rect.maxX * Double(cg.width))
        let y0 = Int(rect.minY * Double(cg.height)), y1 = Int(rect.maxY * Double(cg.height))
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let o = (y * w + x) * 4
                r += Double(buf[o]); g += Double(buf[o + 1]); b += Double(buf[o + 2]); n += 1
            }
        }
        return (r / n, g / n, b / n)
    }

    func testGapRendersAsBlackAndPreservesDuration() async throws {
        let a = videoAsset("clip1.mp4")
        let b = videoAsset("clip2.mp4")
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: a.id, source: .video(0...2))))),
            PlanElement(content: .gap(duration: 1.0)),
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: b.id, source: .video(0...2))))),
        ])
        let plan = EditPlan(assets: [a, b], tracks: [primary], primaryTrackID: primary.id)

        let out = try await export(plan, to: "gap.mp4")
        let asset = AVURLAsset(url: out)
        let duration = try await CMTimeGetSeconds(asset.load(.duration))
        XCTAssertEqual(duration, plan.renderedDuration, accuracy: 0.2)
        XCTAssertEqual(plan.renderedDuration, 5.0, accuracy: 0.001)

        // 主轨空洞处（2.0–3.0s）应为黑帧
        let color = try meanColor(asset, at: 2.5, in: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
        XCTAssertLessThan(color.red + color.green + color.blue, 36,
                          "gap 区间应为黑场，实测 RGB \(color)")
    }

    func testOverlayTrackRendersPictureInPicture() async throws {
        let a = videoAsset("clip1.mp4")   // 红
        let b = videoAsset("clip2.mp4")   // 绿
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: a.id, source: .video(0...3))))),
        ])
        let overlay = PlanTrack(kind: .video, placement: .absolute, elements: [
            PlanElement(at: 0.5, content: .content(TrackPayload(
                PlanClip(assetID: b.id, source: .video(0...2))))),
        ])
        let plan = EditPlan(assets: [a, b], tracks: [primary, overlay], primaryTrackID: primary.id)

        let out = try await export(plan, to: "pip.mp4")
        let asset = AVURLAsset(url: out)

        // 叠加轨全幅覆盖主轨 → 叠加生效时段内整帧应是绿
        let during = try meanColor(asset, at: 1.0, in: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
        XCTAssertGreaterThan(during.green, during.red, "叠加时段内应看到叠加轨的绿")

        // 叠加轨结束（0.5+2=2.5s）之后，应回到主轨的红
        let after = try meanColor(asset, at: 2.8, in: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
        XCTAssertGreaterThan(after.red, after.green, "叠加结束后应回到主轨的红")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/JangyCore && swift test --filter MultiTrackExportEndToEndTests`
Expected: 编译失败 —— `cannot find 'VideoEngine' / 'CaptionEngine' in scope`

- [ ] **Step 3: 实现两个引擎片**

`Features/Video/VideoEngine.swift`：

```swift
import AVFoundation
import CoreGraphics
import Foundation
import Kadr

/// 视频轨特性（L3 片）：叠加视频轨 → Kadr.Track。
/// 主轨的映射在 EngineBridge 内联（它要跟转场交错构建，且必须是顶层链式 clip）；
/// 本文件只管非主轨的视频轨。
public enum VideoEngine {

    /// 叠加视频轨 → 一个并行子时间线。
    /// 元素用 `.at(time:)` 绝对定位（与 .absolute 轨语义一致）；
    /// Track 的声明顺序 = 绘制顺序（后面的盖前面的）。
    static func makeParallelTrack(track: PlanTrack, plan: EditPlan,
                                  resolver: AssetResolver,
                                  preset: Kadr.Preset) async throws -> Kadr.Track {
        var elements: [any Kadr.Clip] = []

        for element in track.elements {
            let start = element.at ?? 0
            switch element.content {
            case .gap(let duration):
                elements.append(Kadr.ImageClip.color(PlatformColor.black, duration: duration)
                    .at(time: start))

            case .content(let payload):
                guard let clip = payload.value as? PlanClip else {
                    throw EngineBridge.UnknownPayloadError(kind: track.kind,
                                                           payloadType: payload.payloadType)
                }
                guard let asset = plan.asset(withID: clip.assetID) else {
                    throw EngineBridge.MissingAssetError(assetID: clip.assetID)
                }
                let url = resolver.resolve(asset)

                switch clip.source {
                case .still(let duration):
                    guard let image = StillImagePreparer.prepare(url: url, canvas: preset.resolution) else {
                        throw EngineBridge.ImageDecodeError(assetID: clip.assetID)
                    }
                    elements.append(Kadr.ImageClip(image, duration: duration / clip.speed.rate)
                        .at(time: start))

                case .video(let range):
                    var videoClip = Kadr.VideoClip(url: url).trimmed(to: range)
                    if clip.speed.rate != 1.0 {
                        videoClip = videoClip.speed(.flat(clip.speed.rate))
                    }
                    elements.append(videoClip.at(time: start))
                }
            }
        }

        return Kadr.Track(name: track.name) {
            for element in elements { element }
        }
    }
}
```

`Features/Caption/CaptionEngine.swift`：

```swift
import CoreMedia
import Foundation
import Kadr

/// 字幕轨特性（L3 片）：字幕轨 → Kadr.Caption 数组。
/// 不再从文件读——cue 的文本与时间都在 plan 里（位置以 PlanElement.at 为权威）。
public enum CaptionEngine {

    static func makeCues(track: PlanTrack) -> [Kadr.Caption] {
        guard CaptionFeature.settings(of: track).isEnabled else { return [] }
        return track.elements.compactMap { element in
            guard case .content(let payload) = element.content,
                  let cue = payload.value as? CaptionCuePayload,
                  let at = element.at else { return nil }
            let start = CMTime(seconds: at, preferredTimescale: 1000)
            let duration = CMTime(seconds: cue.duration, preferredTimescale: 1000)
            return Kadr.Caption(text: cue.text, timeRange: CMTimeRange(start: start, duration: duration))
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd Packages/JangyCore && swift test --filter MultiTrackExportEndToEndTests`
Expected: PASS（2 个用例）

> 若 `testOverlayTrackRendersPictureInPicture` 的「叠加时段内是绿」不成立，说明 Kadr 的并行轨层序与预期相反——把 `plan.tracks` 的遍历顺序倒过来再试，并把结论写进 Task 14 的公约条目（轨道顺序 = 绘制顺序，谁在上面）。

- [ ] **Step 5: 回填 spec 的实测结论**

`docs/superpowers/specs/2026-10-15-timeline-tracks-design.md` 的「待验证 / 未决」节：

- 把「主轨结束后的画面行为」一条改为**已实测**：主轨 gap 区间渲染为黑场（`MultiTrackExportEndToEndTests.testGapRendersAsBlackAndPreservesDuration` 锚定）。
- 把「视频轨的 z 序」一条改为**已实测**：`plan.tracks` 数组顺序 = 绘制顺序（结论以本步实测为准）。

- [ ] **Step 6: 提交**

```bash
git add Packages/JangyCore/Sources/JangyCore/Features/Video/VideoEngine.swift \
        Packages/JangyCore/Sources/JangyCore/Features/Caption/CaptionEngine.swift \
        Packages/JangyCore/Tests/JangyCoreTests/MultiTrackExportEndToEndTests.swift \
        docs/superpowers/specs/2026-10-15-timeline-tracks-design.md
git commit -m "Core: 引擎多轨映射（叠加轨 → Kadr.Track，gap → 黑 ImageClip）+ e2e"
```

---

## Task 11: 字幕逐句化接线

**Files:**
- Test: `Packages/JangyCore/Tests/JangyCoreTests/CaptionTimelineTests.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/PreviewBridge.swift`（仅注释）

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import JangyCore

final class CaptionTimelineTests: XCTestCase {

    private func plan(cueAt: TimeInterval, duration: TimeInterval,
                      enabled: Bool = true) -> EditPlan {
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: [PlanElement(content: .gap(duration: 10))])
        let captionTrack = PlanTrack(
            kind: .caption, placement: .absolute,
            settings: TrackPayload(CaptionTrackSettings(isEnabled: enabled)),
            elements: [PlanElement(at: cueAt, content: .content(TrackPayload(
                CaptionCuePayload(text: "你好", duration: duration))))])
        return EditPlan(tracks: [primary, captionTrack], primaryTrackID: primary.id)
    }

    func testCuePositionComesFromElementAt() {
        let plan = plan(cueAt: 3, duration: 2)
        let track = plan.tracks.first { $0.kind == .caption }!
        let cues = CaptionEngine.makeCues(track: track)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues.first?.timeRange.start.seconds, 3, accuracy: 0.001)
        XCTAssertEqual(cues.first?.timeRange.duration.seconds, 2, accuracy: 0.001)
    }

    func testDisabledCaptionTrackYieldsNoCues() {
        let plan = plan(cueAt: 0, duration: 1, enabled: false)
        let track = plan.tracks.first { $0.kind == .caption }!
        XCTAssertTrue(CaptionEngine.makeCues(track: track).isEmpty)
    }

    func testCueWithoutAtIsSkipped() {
        let track = PlanTrack(kind: .caption, placement: .absolute, elements: [
            PlanElement(content: .content(TrackPayload(CaptionCuePayload(text: "x", duration: 1)))),
        ])
        XCTAssertTrue(CaptionEngine.makeCues(track: track).isEmpty, "绝对轨元素缺 at 时跳过，不崩")
    }

    func testCueTextIsEditableThroughPlan() {
        var plan = plan(cueAt: 1, duration: 1)
        let ti = plan.tracks.firstIndex { $0.kind == .caption }!
        guard case .content(let payload) = plan.tracks[ti].elements[0].content,
              let cue = payload.value as? CaptionCuePayload else { return XCTFail("payload 类型不对") }
        plan.tracks[ti].elements[0].content = .content(
            TrackPayload(CaptionCuePayload(text: "改过的", duration: cue.duration)))

        let cues = CaptionEngine.makeCues(track: plan.tracks[ti])
        XCTAssertEqual(cues.first?.text, "改过的")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/JangyCore && swift test --filter CaptionTimelineTests`
Expected: PASS 或 FAIL——Task 10 已实现 `CaptionEngine`，此处应直接通过。若有失败，说明 `CaptionEngine` 的位置口径写错了。

- [ ] **Step 3: 更新 PreviewBridge 注释**

`PreviewBridge.swift` 的类注释改为说明 cue 来源已变：

```swift
/// 预览包：AVPlayerItem + 字幕 cue 列表。
/// 注意：Kadr 的 overlay（烧录字幕）不进入预览（AVFoundation 限制，export-only），
/// 表现层需用 SwiftUI 原生叠加层按播放器时间显示 cues。
/// cues 来自 plan 的字幕轨元素（`CaptionEngine.makeCues`），不再来自 SRT 文件解析。
```

- [ ] **Step 4: 运行确认通过**

Run: `cd Packages/JangyCore && swift test --filter CaptionTimelineTests`
Expected: PASS（4 个用例）

- [ ] **Step 5: 提交**

```bash
git add Packages/JangyCore/Tests/JangyCoreTests/CaptionTimelineTests.swift \
        Packages/JangyCore/Sources/JangyCore/PreviewBridge.swift
git commit -m "Core: 字幕逐句化接线（位置以 element.at 为准，预览不再解析 SRT）"
```

---

## Task 12: Agent 工具改造

**Files:**
- Modify: `Packages/JangyCore/Sources/JangyAgent/AgentTools.swift`
- Modify: `Packages/JangyCore/Sources/JangyAgent/AgentPromptBuilder.swift`
- Test: `Packages/JangyCore/Tests/JangyAgentTests/AgentTrackToolsTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
import JangyCore
import JangyTestSupport
@testable import JangyAgent

/// 复用 AgentToolsTests 的 context 构造辅助（同一 target）。
final class AgentTrackToolsTests: XCTestCase {

    private func makeContext() throws -> AgentRunContext {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let resolver = try AssetSynthesizer.synthesize(into: dir)
        return AgentRunContext(plan: SamplePlan.make(), resolver: resolver, framesDirectory: dir)
    }

    func testGetPlanExposesFlatElementView() async throws {
        let context = try makeContext()
        let result = try await GetPlanTool(context: context).call(parsed: .init())
        XCTAssertTrue(result.contains("\"elementID\""), "get_plan 应给出扁平元素视图")
        XCTAssertTrue(result.contains("\"trackID\""))
        XCTAssertTrue(result.contains("\"payloadType\""))
    }

    func testMoveElementIsIDBased() async throws {
        let context = try makeContext()
        let plan = await context.plan
        let first = plan.primaryTrack!.elements[0].id
        let last = plan.primaryTrack!.elements[2].id

        let result = try await MoveElementTool(context: context).call(parsed: .init(
            elementID: first.uuidString, toTrackID: nil,
            beforeElementID: last.uuidString, at: nil))
        XCTAssertTrue(result.contains("\"status\":\"ok\""))

        let after = await context.plan
        XCTAssertEqual(after.primaryTrack!.elements[1].id, first)
    }

    func testAddTrackCreatesOverlayVideoTrack() async throws {
        let context = try makeContext()
        let result = try await AddTrackTool(context: context).call(parsed: .init(
            kind: "video", placement: "absolute", name: nil))
        XCTAssertTrue(result.contains("\"status\":\"ok\""))
        let plan = await context.plan
        XCTAssertEqual(plan.tracks.filter { $0.kind == .video }.count, 2)
    }

    func testAddClipToOverlayTrackRequiresAt() async throws {
        let context = try makeContext()
        _ = try await AddTrackTool(context: context).call(parsed: .init(
            kind: "video", placement: "absolute", name: nil))
        let plan = await context.plan
        let overlayID = plan.tracks.filter { $0.kind == .video }[1].id

        let missingAt = try await AddClipTool(context: context).call(parsed: .init(
            fileName: "clip1.mp4", rangeStart: 0, rangeEnd: 2, speed: nil, duration: nil,
            trackID: overlayID.uuidString, at: nil))
        XCTAssertTrue(missingAt.contains("\"status\":\"error\""), "绝对轨必须给 at")
        XCTAssertTrue(missingAt.contains("at"))

        let withAt = try await AddClipTool(context: context).call(parsed: .init(
            fileName: "clip1.mp4", rangeStart: 0, rangeEnd: 2, speed: nil, duration: nil,
            trackID: overlayID.uuidString, at: 1.0))
        XCTAssertTrue(withAt.contains("\"status\":\"ok\""))
    }

    func testAddClipWithoutTrackIDGoesToPrimary() async throws {
        let context = try makeContext()
        let result = try await AddClipTool(context: context).call(parsed: .init(
            fileName: "clip1.mp4", rangeStart: 0, rangeEnd: 2, speed: nil, duration: nil,
            trackID: nil, at: nil))
        XCTAssertTrue(result.contains("\"status\":\"ok\""))
        let plan = await context.plan
        XCTAssertEqual(plan.primaryTrack!.elements.count, 4)
    }

    func testRemoveClipLeavesGapAndKeepsDuration() async throws {
        let context = try makeContext()
        let before = await context.plan.renderedDuration
        let middle = await context.plan.primaryTrack!.elements[1].id

        let result = try await RemoveClipTool(context: context).call(parsed: .init(
            elementID: middle.uuidString))
        XCTAssertTrue(result.contains("\"status\":\"ok\""))

        let after = await context.plan
        XCTAssertEqual(after.renderedDuration, before, accuracy: 0.001, "删除不缩短成片")
        guard case .gap = after.primaryTrack!.elements[1].content else {
            return XCTFail("中间元素应变成 gap")
        }
    }

    func testSetCaptionTextUpdatesCue() async throws {
        let context = try makeContext()
        let plan = await context.plan
        let cueID = plan.tracks.first { $0.kind == .caption }!.elements[0].id

        let result = try await SetCaptionTextTool(context: context).call(parsed: .init(
            elementID: cueID.uuidString, text: "改过的字幕"))
        XCTAssertTrue(result.contains("\"status\":\"ok\""))

        let after = await context.plan
        let cue = after.tracks.first { $0.kind == .caption }!.elements[0]
        guard case .content(let payload) = cue.content,
              let value = payload.value as? CaptionCuePayload else { return XCTFail("payload 类型不对") }
        XCTAssertEqual(value.text, "改过的字幕")
    }

    func testValidationIssuesCarryElementID() async throws {
        let context = try makeContext()
        let plan = await context.plan
        let clipID = plan.primaryTrack!.elements[0].id

        let result = try await SetSpeedTool(context: context).call(parsed: .init(
            elementID: clipID.uuidString, rate: 99))
        XCTAssertTrue(result.contains("\"status\":\"error\""))
        XCTAssertTrue(result.contains(clipID.uuidString), "issues 应带出出错的元素 ID")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/JangyCore && swift test --filter AgentTrackToolsTests`
Expected: 编译失败 —— `cannot find 'MoveElementTool' in scope`

- [ ] **Step 3: 改造工具集**

`AgentTools.swift` 的改动清单：

**3a. `GetPlanTool.Payload` 增加扁平视图**（模型不必自己遍历嵌套结构）：

```swift
    struct Payload: Encodable {
        struct ElementView: Encodable {
            let elementID: String
            let trackID: String
            let trackKind: String
            let at: TimeInterval?
            let duration: TimeInterval
            let payloadType: String?
            let text: String?          // 字幕 cue 的文本，便于模型直接读
        }
        let renderedDuration: TimeInterval
        let primaryTrackID: String
        let elements: [ElementView]    // 扁平视图
        let plan: EditPlan             // 原始 JSON 另开字段
    }

    func call(parsed _: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        let plan = await context.plan
        let views = plan.tracks.flatMap { track in
            track.elements.map { element -> Payload.ElementView in
                var payloadType: String?
                var text: String?
                if case .content(let payload) = element.content {
                    payloadType = payload.payloadType
                    text = (payload.value as? CaptionCuePayload)?.text
                }
                return Payload.ElementView(elementID: element.id.uuidString,
                                           trackID: track.id.uuidString,
                                           trackKind: track.kind.rawValue,
                                           at: element.at,
                                           duration: element.duration,
                                           payloadType: payloadType,
                                           text: text)
            }
        }
        return ToolEnvelope.ok(Payload(renderedDuration: plan.renderedDuration,
                                       primaryTrackID: plan.primaryTrackID.uuidString,
                                       elements: views, plan: plan))
    }
```

**3b. `AddClipTool`** 加 `trackID` / `at`：

```swift
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
        @Guide(description: "目标轨道 ID，缺省 = 主轨（追加到末尾）")
        let trackID: String?
        @Guide(description: "绝对定位轨上的起点（秒）。目标是绝对定位轨时必填；主轨忽略。")
        let at: Double?
    }
```

`call` 的目标轨解析与写入：

```swift
        // 目标轨：缺省主轨；显式指定时必须是已存在的轨
        let targetTrackID: UUID
        if let raw = args.trackID {
            guard let uuid = UUID(uuidString: raw),
                  let track = currentPlan.tracks.first(where: { $0.id == uuid }) else {
                return ToolEnvelope.error("找不到轨道 \(raw)，请先用 get_plan 获取当前轨道 ID")
            }
            targetTrackID = track.id
            if track.placement == .absolute, args.at == nil {
                return ToolEnvelope.error("轨道 \(raw) 是绝对定位轨，必须提供 at（起点秒数）")
            }
        } else {
            targetTrackID = currentPlan.primaryTrackID
        }
```

写入侧：

```swift
            return await context.withStore { store in
                let result = store.apply { plan in
                    let assetID: UUID
                    if let registered = plan.assets.first(where: { $0.fileName == asset.fileName }) {
                        assetID = registered.id
                    } else {
                        plan.assets.append(asset)
                        assetID = asset.id
                    }
                    let clip: PlanClip = asset.kind == .image
                        ? PlanClip(assetID: assetID, source: .still(duration: args.duration ?? 3.0),
                                   speed: .flat(rate))
                        : PlanClip(assetID: assetID, source: .video(args.rangeStart!...args.rangeEnd!),
                                   speed: .flat(rate))
                    guard let ti = plan.tracks.firstIndex(where: { $0.id == targetTrackID }) else { return }
                    plan.tracks[ti].elements.append(PlanElement(at: args.at,
                                                                content: .content(TrackPayload(clip))))
                    TrackOperations.maintainInvariants(in: &plan)
                }
                return ToolEnvelope.applied(result) { plan in
                    let track = plan.tracks.first { $0.id == targetTrackID }!
                    let element = track.elements.last!
                    let registered = plan.assets.first { $0.fileName == asset.fileName }!
                    return Payload(clipID: element.id.uuidString,
                                   assetID: registered.id.uuidString,
                                   registeredNewAsset: !existingFileNames.contains(asset.fileName),
                                   renderedDuration: plan.renderedDuration)
                }
            }
```

**3c. `MoveClipTool` → `MoveElementTool`**（纯 ID，废除 `toIndex`）：

```swift
struct MoveElementTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "move_element"
    let description = "移动元素。给 beforeElementID = 插到该元素之前（同轨内相对定位）；给 at = 放到该绝对时间（仅绝对定位轨）；给 toTrackID = 换轨。至少给一个。"

    @Generable
    struct Args {
        @Guide(description: "要移动的元素 ID")
        let elementID: String
        @Guide(description: "目标轨道 ID；缺省 = 不换轨")
        let toTrackID: String?
        @Guide(description: "插到这个元素之前（同轨内的相对定位）")
        let beforeElementID: String?
        @Guide(description: "放到这个绝对时间（秒），仅绝对定位轨")
        let at: Double?
    }

    struct Payload: Encodable {
        let elementID: String
        let trackID: String
        let renderedDuration: TimeInterval
    }

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        guard args.toTrackID != nil || args.beforeElementID != nil || args.at != nil else {
            return ToolEnvelope.error("至少要给 toTrackID / beforeElementID / at 其中之一")
        }

        return await context.withStore { store in
            let location: AgentToolCommon.ElementLocation
            switch AgentToolCommon.locate(store.plan, elementID: args.elementID) {
            case .success(let found): location = found
            case .failure(let error): return error.message
            }

            let beforeLocation: AgentToolCommon.ElementLocation?
            if let raw = args.beforeElementID {
                switch AgentToolCommon.locate(store.plan, elementID: raw) {
                case .success(let found): beforeLocation = found
                case .failure(let error): return error.message
                }
            } else {
                beforeLocation = nil
            }

            let targetTrackID: UUID?
            if let raw = args.toTrackID {
                guard let uuid = UUID(uuidString: raw),
                      store.plan.tracks.contains(where: { $0.id == uuid }) else {
                    return ToolEnvelope.error("找不到轨道 \(raw)，请先用 get_plan 获取当前轨道 ID")
                }
                targetTrackID = uuid
            } else {
                targetTrackID = nil
            }

            let result = store.apply { plan in
                // 先取出元素
                let element = plan.tracks[location.trackIndex].elements.remove(at: location.elementIndex)

                // 换轨：插到目标轨末尾（绝对定位轨随后由 at 或 maintainInvariants 定位置）
                let destination = targetTrackID.flatMap { id in
                    plan.tracks.firstIndex { $0.id == id }
                } ?? location.trackIndex

                // 同轨内相对定位：插到 beforeElementID 之前
                if let before = beforeLocation, targetTrackID == nil {
                    let anchor = plan.tracks[destination].elements.firstIndex { $0.id ==
                        plan.tracks[before.trackIndex].elements[before.elementIndex].id }
                    plan.tracks[destination].elements.insert(element, at: anchor ?? plan.tracks[destination].elements.count)
                } else {
                    plan.tracks[destination].elements.append(element)
                }

                // 绝对时间：覆盖 at
                if let at = args.at {
                    let inserted = plan.tracks[destination].elements.firstIndex { $0.id == element.id }!
                    plan.tracks[destination].elements[inserted].at = at
                }

                TrackOperations.maintainInvariants(in: &plan)
            }

            return ToolEnvelope.applied(result) { plan in
                let track = plan.tracks.first { $0.elements.contains { $0.id ==
                    location.elementIndex < $0.elements.count ? false : false } } ?? plan.tracks[0]
                return Payload(elementID: args.elementID, trackID: track.id.uuidString,
                               renderedDuration: plan.renderedDuration)
            }
        }
    }
}
```

> 上面 Payload 里找轨道那段写法绕。**实现时简化**：在 `store.apply` 闭包内把最终所在轨道 id 记到一个局部 `var` 里，闭包外用 `ToolEnvelope.applied` 的 payload 闭包读回来即可（`applied` 的 payload 闭包拿到的是 apply 后的 plan，按 `elementID` 找一次最直接）：

```swift
            return ToolEnvelope.applied(result) { plan in
                let trackID = plan.tracks.first { track in
                    track.elements.contains { $0.id == UUID(uuidString: args.elementID) }
                }?.id.uuidString ?? ""
                return Payload(elementID: args.elementID, trackID: trackID,
                               renderedDuration: plan.renderedDuration)
            }
```

**3d. 其余工具**：`clipID` 参数名统一改成 `elementID`；各工具 `Payload` 里返回给模型的字段名同步改成 `elementID` / `firstElementID` / `secondElementID`（模型读到的标识符应与它下次回传的参数名一致，否则它会照抄旧名再报错）；内部按 Task 6 Step 9 的「定位 → 解包 → 改 → 装回」模式；`RemoveClipTool` 改调 `TrackOperations.removeElement`（保持「删除 = 留 gap」语义）。

`SplitClipTool` 的改法是唯一需要多想一步的——它要在链式轨里把元素一分为二，且两段都要保留原 payload 的属性：

```swift
            let result = store.apply { plan in
                guard case .content(let payload) = plan.tracks[location.trackIndex]
                        .elements[location.elementIndex].content,
                      let clip = payload.value as? PlanClip else { return }

                switch clip.source {
                case .video(let range):
                    var first = clip
                    var second = clip
                    first.source = .video(range.lowerBound...args.at)
                    first.transitionAfter = nil
                    second.source = .video(args.at...range.upperBound)
                    plan.tracks[location.trackIndex].elements.replaceSubrange(
                        location.elementIndex...location.elementIndex,
                        with: [PlanElement(content: .content(TrackPayload(first))),
                               PlanElement(content: .content(TrackPayload(second)))])
                case .still(let duration):
                    var first = clip
                    var second = clip
                    first.source = .still(duration: args.at)
                    first.transitionAfter = nil
                    second.source = .still(duration: duration - args.at)
                    plan.tracks[location.trackIndex].elements.replaceSubrange(
                        location.elementIndex...location.elementIndex,
                        with: [PlanElement(content: .content(TrackPayload(first))),
                               PlanElement(content: .content(TrackPayload(second)))])
                }
            }
```

注意后半段拿到的是**新的元素 id**（`PlanElement()` 默认生成），前半段也换了新 id——原 id 不再存在。**这正是「ID 寻址」优于下标寻址的地方**：Payload 必须把两个新 id 都返回给模型（沿用现有 `firstClipID` / `secondClipID` 字段名，或改成 `firstElementID` / `secondElementID`）。

`SetTransitionTool` 的「最后一段不能挂转场」检查要改成「紧邻下一个元素不能是 gap 或不存在」——直接依赖 `EditPlanValidator` 的报错回喂即可，工具层不必自己判（校验失败会以 issues 信封回喂）。

**3e. 新增轨工具**：`AddTrackTool(kind, placement, name)` / `RemoveTrackTool(trackID)` / `MoveTrackTool(trackID, toIndex)` / `SetTrackFlagsTool(trackID, muted, hidden, locked)`。`RemoveTrackTool` 必须拒绝删主轨。

**3f. `SetCaptionsTool` → `SetCaptionTrackTool`**：导入 SRT → `SRTParser.parse` → 建/替换 caption 轨（cue 元素 + `CaptionTrackSettings`）。**新增 `SetCaptionTextTool(elementID, text)`**。

**3g. `AgentToolSet.make`** 注册全部新工具。

- [ ] **Step 4: 改提示词**

`AgentPromptBuilder.instructions` 的「领域规则」段整体替换：

```swift
        # 时间线结构
        - 时间线由多条轨道组成。主轨（get_plan 返回的 primaryTrackID）是链式：片段首尾相接、顺序有意义、转场挂在片段尾部。
        - 叠加轨是绝对定位：每个元素自带 at（在成片时间轴上的起点），互不相邻、可以覆盖主轨。
        - 主轨删除片段 = 原地留一段黑（空档 gap），成片时长不变；要缩短必须再删掉那个空档。
        - 主轨从 0 起连续覆盖整条时间线；任何轨的元素都不能超出主轨末端——超出时主轨会自动补黑。
        - 元素一律用 get_plan 返回的 elementID 寻址，不要用下标（下标会随编辑漂移）。
        - 片段区间是相对素材自身时间轴的源区间（秒），不是成片时间轴。
        - 变速倍率范围 0.25–4.0；输出时长 = 源区间长度 ÷ 倍率。
        - 转场挂在片段尾部，只对紧邻的下一段生效；最后一段不能挂转场；转场不能跨过空档。dissolve 与相邻片段全额重叠（会扣总时长），fade 不重叠。
        - 渲染总时长一律以 get_plan 返回的 renderedDuration 为准，不要用各段时长自行求和。
        - 字幕是独立轨上的一条条 cue（set_caption_track 导入 SRT 展开；set_caption_text 改单句文本），不随视频片段联动。
```

- [ ] **Step 5: 运行确认通过**

Run: `cd Packages/JangyCore && swift test --filter AgentTrackToolsTests`
Expected: PASS（8 个用例）

- [ ] **Step 6: 全量测试**

Run: `cd Packages/JangyCore && swift test`
Expected: 全部通过

- [ ] **Step 7: 提交**

```bash
git add Packages/JangyAgent Packages/JangyCore/Tests/JangyAgentTests
git commit -m "Agent: 工具改造为 ID 寻址 + 轨工具 + 字幕逐句（新增绝对时间放置原语）"
```

---

## Task 13: 可插拔性验收测试

**Files:**
- Test: `Packages/JangyCore/Tests/JangyCoreTests/TrackFeaturePluggabilityTests.swift`

**背景：** 公约 §4.6 的可插拔性验收同款写法——加一类轨，断言核心的条件分支零改动。注册表提供了 `testOnlyFeatures` 注入点（Task 1 已建），生产清单不受影响。

- [ ] **Step 1: 写测试**

```swift
import XCTest
@testable import JangyCore

/// 第四类轨（贴纸轨空壳）。它只存在于本测试文件里——payload + 特性片 + 一次注入，
/// 核心的编解码、校验分派、不变式就全部正确工作。
/// 这就是注册表的验收标准：**加一类轨不需要改核心的任何 switch / if 分支**。
struct StickerPayload: Codable, Equatable, Sendable, TrackElementPayload {
    static let payloadType = "sticker"
    var imageName: String
    var duration: TimeInterval
}

enum StickerFeature: TrackFeature {
    static let kind = TrackKind(rawValue: "sticker")
    static let payloadTypes: [any TrackElementPayload.Type] = [StickerPayload.self]

    static func validate(track: PlanTrack, context: TrackValidationContext) -> [ValidationIssue] {
        track.elements.compactMap { element in
            guard case .content(let payload) = element.content,
                  let sticker = payload.value as? StickerPayload,
                  sticker.imageName.isEmpty else { return nil }
            return ValidationIssue(path: "tracks[\(track.id)]", elementID: element.id,
                                   message: "贴纸缺图片名")
        }
    }
}

final class TrackFeaturePluggabilityTests: XCTestCase {

    override func tearDown() {
        TrackFeatureRegistry.testOnlyFeatures = []
        super.tearDown()
    }

    func testFourthTrackKindRoundTripsWithoutCoreChanges() throws {
        TrackFeatureRegistry.testOnlyFeatures = [StickerFeature.self]

        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: [PlanElement(content: .gap(duration: 5))])
        let stickerTrack = PlanTrack(kind: StickerFeature.kind, placement: .absolute, elements: [
            PlanElement(at: 1, content: .content(TrackPayload(
                StickerPayload(imageName: "star.png", duration: 2)))),
        ])
        let plan = EditPlan(tracks: [primary, stickerTrack], primaryTrackID: primary.id)

        // 编解码：核心不知道 sticker 是什么，仍能往返
        let data = try JSONEncoder().encode(plan)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"sticker\""))
        let decoded = try JSONDecoder().decode(EditPlan.self, from: data)
        XCTAssertEqual(decoded, plan)
    }

    func testValidatorDispatchesUnknownKindToItsFeature() throws {
        TrackFeatureRegistry.testOnlyFeatures = [StickerFeature.self]

        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: [PlanElement(content: .gap(duration: 5))])
        let badSticker = PlanTrack(kind: StickerFeature.kind, placement: .absolute, elements: [
            PlanElement(at: 1, content: .content(TrackPayload(
                StickerPayload(imageName: "", duration: 2)))),
        ])
        let plan = EditPlan(tracks: [primary, badSticker], primaryTrackID: primary.id)

        let issues = EditPlanValidator().validate(plan)
        XCTAssertTrue(issues.contains { $0.message.contains("贴纸缺图片名") },
                      "校验应分派给 StickerFeature，核心不需要认识 sticker")
    }

    func testCoreInvariantsApplyToUnknownKind() throws {
        TrackFeatureRegistry.testOnlyFeatures = [StickerFeature.self]

        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: [PlanElement(content: .gap(duration: 3))])
        let stickerTrack = PlanTrack(kind: StickerFeature.kind, placement: .absolute, elements: [
            PlanElement(at: 6, content: .content(TrackPayload(
                StickerPayload(imageName: "star.png", duration: 2)))),
        ])
        var plan = EditPlan(tracks: [primary, stickerTrack], primaryTrackID: primary.id)

        TrackOperations.maintainInvariants(in: &plan)
        XCTAssertEqual(plan.primaryTrack!.span, 8, accuracy: 0.001,
                       "核心用通用规则处理未知轨：主轨自动补到 8s")
    }

    func testUnregisteredTrackKindIsRejectedByValidator() {
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: [PlanElement(content: .gap(duration: 5))])
        let orphan = PlanTrack(kind: TrackKind(rawValue: "no-such-kind"), placement: .absolute)
        let plan = EditPlan(tracks: [primary, orphan], primaryTrackID: primary.id)

        let issues = EditPlanValidator().validate(plan)
        XCTAssertTrue(issues.contains { $0.message.contains("未注册的轨道类型") })
    }

    func testUnregisteredPayloadTypeIsRejectedByDecoder() {
        // 未注册的 payload 在解码期就报错（不静默丢弃）
        let json = #"{"type":"sticker","imageName":"a.png","duration":1}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(TrackPayload.self, from: json))
    }
}
```

- [ ] **Step 2: 运行确认通过**

Run: `cd Packages/JangyCore && swift test --filter TrackFeaturePluggabilityTests`
Expected: PASS（5 个用例）

- [ ] **Step 3: 提交**

```bash
git add Packages/JangyCore/Tests/JangyCoreTests/TrackFeaturePluggabilityTests.swift
git commit -m "Core: 特性注册表可插拔性验收（第四类轨空壳，核心零分支改动）"
```

---

## Task 14: 公约修订与文档同步

**Files:**
- Modify: `docs/architecture-covenant.md`
- Modify: `docs/roadmap-path-a.md`
- Modify: `AGENTS.md`
- Modify: `README.md`（若列了时间线能力）

- [ ] **Step 1: 按 spec 的「公约修订清单」逐条改 `architecture-covenant.md`**

1. **§3.3 时间口径**：公式不变，补两条不变式——主轨从 0 起连续覆盖 `[0, renderedDuration]`；任何轨的元素不得超出主轨末端（由 `TrackOperations` 维持、校验器兜底）。
2. **§3.2 素材引用**：字幕 cue 的文本进 plan、不再引用素材；SRT 文件退化为导入源（轨 `settings.sourceAssetID` 保留引用保护）。
3. **§1 现有代码落位表**：补记 L2 特性注册表（`TrackFeatureRegistry` / `Features/`）、L3 轨道引擎映射（`VideoEngine` / `CaptionEngine`）。L1 Interaction 层仍标「待建」（阶段②）。
4. **§4 已知联动清单**：删除「分割点横跨字幕 → 字幕裂为两条」——字幕是独立绝对轨，不随视频片段联动。
5. **新增章节「轨道模型」**：`TrackKind`（开放）/ `TrackPlacement`（结构）/ `ElementContent(gap)` / 特性注册表按层切三片 / `Manifest` 是唯一注册点 / 静态装配（headless 可用）。
6. **新增条目「删除语义 = lift 而非 ripple」**：删除主轨元素 = 内容消失、时长保留；缩短需显式合上。业界依据：Premiere/FCP/DaVinci/Avid 的 lift 默认；与手机端主流（剪映默认 ripple）的偏离理由 = 轨间解耦。
7. **§6.4 降级登记表**：按实现情况补登。

- [ ] **Step 2: 改 roadmap**

「已完成」加一条：

```markdown
- [x] **时间线多轨 · 阶段①（模型 + 引擎）**（✅ 2026-XX-XX；spec：[timeline-tracks-design](superpowers/specs/2026-10-15-timeline-tracks-design.md)，plan：[timeline-tracks-model-engine](superpowers/plans/2026-10-15-timeline-tracks-model-engine.md)）
  - 要点：EditPlan v4（tracks + primaryTrackID）、特性注册表（核心不认识具体轨类型，可插拔性有测试锚定）、gap 语义与主轨两条不变式（成片时长恒等于主轨链长）、引擎多轨映射（叠加轨 → Kadr.Track，gap → 黑 ImageClip）、字幕逐句化（cue 进 plan，SRT 退化为导入源）、Agent 工具 ID 寻址改造、v3 → v4 迁移
  - 验收：N 测试全绿 + 多轨 e2e（画中画 / gap 黑段）+ App 构建通过 + CLI 冒烟
```

「待办」加一条：

```markdown
- [ ] **时间线多轨 · 阶段②（时间线 UI）**（`agent` 执行）：L1 Interaction 层（TimelineViewportState / GestureRouter / DragSession / SnapEngine）、可拖分界布局、轨道头（钉左无底图标）、标尺与播放头（固定居中，滚动即擦洗）、双指缩放、缩略图（L3 TimelineThumbnailer，含 ThumbnailLoader 从 L0 收口）、选中与 trim、长按拖动与轨道重排
```

- [ ] **Step 3: 同步 AGENTS.md 的测试数**

```bash
cd Packages/JangyCore && swift test 2>&1 | tail -5
```
取实际用例数，更新 AGENTS.md 里的「176 个」。

- [ ] **Step 4: 全量验证**

```bash
cd Packages/JangyCore && swift test
cd Packages/JangyCore && swift run jangy-cli genassets --to /tmp/jangy-assets
swift run jangy-cli sample > /tmp/jangy-draft.json
swift run jangy-cli validate /tmp/jangy-draft.json --assets /tmp/jangy-assets
swift run jangy-cli export /tmp/jangy-draft.json -o /tmp/jangy-out.mp4 --assets /tmp/jangy-assets
swift run jangy-cli snapshot /tmp/jangy-draft.json --at 1.0 --assets /tmp/jangy-assets -o /tmp/jangy-frames
xcodebuild -project Jangy.xcodeproj -scheme Jangy -destination 'generic/platform=iOS Simulator' build
```
Expected: 测试全绿；`validate` → `{"valid":true}`；`export`/`snapshot` 退出码 0；`BUILD SUCCEEDED`

- [ ] **Step 5: 提交**

```bash
git add docs AGENTS.md README.md
git commit -m "docs: 时间线多轨阶段①收口——公约修订、roadmap、测试数同步"
```

---

## 自审记录

**Spec 覆盖检查：**

| Spec 条目 | 对应任务 |
|---|---|
| 数据模型（EditPlan v4 / PlanTrack / PlanElement / ElementContent / TrackPayload） | Task 1, 2, 6 |
| 特性注册表（三层切片 / Manifest / 静态装配） | Task 1, 2, 3, 10, 13 |
| 主轨两条不变式 + 核心操作维持 | Task 6（兜底）, 9 |
| 删除语义 = lift | Task 9, 8, 12 |
| 自动补 gap | Task 9, 12 |
| 成片时长 = 主轨链长 | Task 6 |
| 引擎映射（主轨 / 叠加轨 / gap / 字幕） | Task 6, 10 |
| 字幕逐句化（cue 进 plan / SRT 退化 / 位置以 at 为准） | Task 3, 6, 10, 11, 12 |
| v3 → v4 迁移（含 SRT 缺失分支） | Task 5 |
| Agent 四条硬约束（静态装配 / ID 寻址 / issue 带 elementID / 绝对时间新原语） | Task 1, 2, 12 |
| ValidationIssue.elementID | Task 2, 12 |
| 可插拔性验收 | Task 13 |
| 公约修订清单 | Task 14 |
| 待验证：主轨空洞处画面、视频轨 z 序 | Task 10 Step 5 |

**未覆盖（有意排除，属阶段②）：** 时间线 UI、L1 Interaction 层、L0 lane 呈现器、`TimelineThumbnailer` 收口、缩略图、手势。spec 的「分期」节已声明。

**执行顺序约束（务必遵守）：**
1. Task 5（迁移）必须在 Task 6（`EditPlan` 切换）**之前**完成——Task 6 的 `PlanLoader` 要接线到它，且 `Fixtures/plan-v3.json` 必须在切换前用 `jangy-cli sample` 生成。
2. Task 2 的 `PlanClip` 去 id 会让代码库进入红色区间；Task 2 / 6 / 7 / 8 的改动攒到 Task 8 末尾一次性提交。
3. Task 10 的 z 序结论（叠加轨谁盖谁）以实测为准，需回填 spec 与 Task 14 的公约条目。
