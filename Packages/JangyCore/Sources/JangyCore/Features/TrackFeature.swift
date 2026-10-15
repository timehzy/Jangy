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
