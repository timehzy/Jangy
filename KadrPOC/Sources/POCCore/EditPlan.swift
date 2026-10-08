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

    private enum CodingKeys: String, CodingKey {
        case version, clips, captions, preset
    }

    /// Agent 友好的宽容解码：仅 `clips` 必填，其余缺省落回默认值。编码仍为合成实现。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        clips = try container.decode([PlanClip].self, forKey: .clips)
        captions = try container.decodeIfPresent(CaptionTrack.self, forKey: .captions)
        preset = try container.decodeIfPresent(OutputPreset.self, forKey: .preset) ?? .reelsAndShorts
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

    private enum CodingKeys: String, CodingKey {
        case id, source, range, speed, transitionAfter
    }

    /// Agent 友好的宽容解码：仅 `source`/`range` 必填；`id` 缺省时随机生成。编码仍为合成实现。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source = try container.decode(MediaRef.self, forKey: .source)
        range = try container.decode(ClosedRange<TimeInterval>.self, forKey: .range)
        speed = try container.decodeIfPresent(SpeedPlan.self, forKey: .speed) ?? .flat(1.0)
        transitionAfter = try container.decodeIfPresent(PlanTransition.self, forKey: .transitionAfter)
    }
}

/// 素材引用：素材目录中的文件名；以 "/" 开头则视为绝对路径（CLI 喂 4K HDR 素材用）。
public struct MediaRef: Codable, Equatable, Sendable {
    public var fileName: String
    public init(fileName: String) { self.fileName = fileName }
}

/// POC 只做恒定变速；曲线变速（.curved）留待正式版。
/// JSON 采用 tagged 格式 `{"type":"flat","rate":0.5}`，避免合成的 `_0` 位置键泄漏给 Agent。
public enum SpeedPlan: Codable, Equatable, Sendable {
    case flat(Double)

    public var rate: Double {
        switch self { case .flat(let r): return r }
    }

    private enum CodingKeys: String, CodingKey {
        case type, rate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "flat":
            self = .flat(try container.decode(Double.self, forKey: .rate))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "未知的 SpeedPlan 类型 '\(type)'；支持的类型：flat")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .flat(let rate):
            try container.encode("flat", forKey: .type)
            try container.encode(rate, forKey: .rate)
        }
    }
}

/// JSON 采用 tagged 格式 `{"type":"dissolve","duration":0.5}`，便于 Agent 读写。
public enum PlanTransition: Codable, Equatable, Sendable {
    case dissolve(duration: TimeInterval)
    case fade(duration: TimeInterval)

    public var duration: TimeInterval {
        switch self {
        case .dissolve(let d): return d
        case .fade(let d): return d
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, duration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let duration = try container.decode(TimeInterval.self, forKey: .duration)
        switch type {
        case "dissolve":
            self = .dissolve(duration: duration)
        case "fade":
            self = .fade(duration: duration)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "未知的 PlanTransition 类型 '\(type)'；支持的类型：dissolve, fade")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .dissolve(let duration):
            try container.encode("dissolve", forKey: .type)
            try container.encode(duration, forKey: .duration)
        case .fade(let duration):
            try container.encode("fade", forKey: .type)
            try container.encode(duration, forKey: .duration)
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
