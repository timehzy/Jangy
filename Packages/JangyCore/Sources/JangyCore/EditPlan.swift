import Foundation

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

/// 视频轨的元素 payload。`type` 判别字段由 TrackPayload box 注入，这里不写。
/// **纯 payload**：无 id——寻址一律走 `PlanElement.id`（位置/标识归元素层）。
/// 转场挂在片段尾部（`transitionAfter`），与 Kadr DSL 中 Transition 作为时间线一等元素的位置一一对应。
public struct PlanClip: Codable, Equatable, Sendable, TrackElementPayload {
    public static let payloadType = "clip"

    /// 素材引用：指向 EditPlan.assets 中的条目（v2 起替代文件名直引）。
    public var assetID: UUID
    /// 片段来源：视频源区间 / 静态素材时长。
    public var source: PlanClipSource
    public var speed: SpeedPlan
    public var transitionAfter: PlanTransition?
    /// 元素在成片画布上的布局变换；`nil` = 全屏（恒等）。见 ClipTransform。
    public var transform: ClipTransform?

    public init(assetID: UUID, source: PlanClipSource,
                speed: SpeedPlan = .flat(1.0), transitionAfter: PlanTransition? = nil,
                transform: ClipTransform? = nil) {
        self.assetID = assetID
        self.source = source
        self.speed = speed
        self.transitionAfter = transitionAfter
        self.transform = transform
    }

    /// payload 时长 = 输出时长（源区间长 / 倍速）。
    public var duration: TimeInterval { source.length / speed.rate }

    private enum CodingKeys: String, CodingKey {
        case assetID, source, speed, transitionAfter, transform
    }

    /// v2 旧字段：向后兼容解码（无 source 时回落到 .video(range)）。
    private enum LegacyKeys: String, CodingKey {
        case range
    }

    /// Agent 友好的宽容解码：`source` 缺省时回落 v2 旧 `range`。
    /// 编码走合成实现（只写 source，不写 range）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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
        transform = try container.decodeIfPresent(ClipTransform.self, forKey: .transform)
    }
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

public enum OutputPreset: String, Codable, Sendable {
    case reelsAndShorts
}
