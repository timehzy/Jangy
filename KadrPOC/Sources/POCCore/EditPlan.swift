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
