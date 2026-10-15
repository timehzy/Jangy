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
