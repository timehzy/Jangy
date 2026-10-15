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
    public var span: TimeInterval {
        switch placement {
        case .chained:
            return elements.reduce(0) { $0 + $1.duration }
        case .absolute:
            return elements.reduce(0) { max($0, ($1.at ?? 0) + $1.duration) }
        }
    }
}
