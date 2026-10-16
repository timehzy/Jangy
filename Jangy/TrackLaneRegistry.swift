import SwiftUI
import JangyCore

/// 车道呈现上下文：呈现器只读这里的东西（plan / 视口 / 解析器 / 缩略图器）。
struct LaneContext {
    let plan: EditPlan
    let viewport: TimelineViewportState
    let resolver: AssetResolver
    let thumbnailer: TimelineThumbnailer
}

/// 一类轨的 L0 呈现片（与 L2 `Features/<Name>/<Name>Feature.swift`、L3 `<Name>Engine.swift` 同 kind 的三片之一）。
protocol TrackLaneProvider {
    static var kind: TrackKind { get }
    /// 轨道头图标（SF Symbol）。放这里是为了让轨道头也不 switch kind。
    static var icon: String { get }
    @MainActor static func makeLane(track: PlanTrack, context: LaneContext) -> AnyView
}

/// 车道呈现器注册表 —— L0 侧唯一注册点。加一类轨 = 这里加一行 + 新增 `Features/<Name>/<Name>Lane.swift`。
/// **TrackLaneView 不得 switch 具体轨类型**（公约 §1）；不认识 kind 时回落通用车道。
enum TrackLaneRegistry {
    static let providers: [any TrackLaneProvider.Type] = [
        VideoLaneProvider.self,
        CaptionLaneProvider.self,
    ]

    static func provider(for kind: TrackKind) -> (any TrackLaneProvider.Type)? {
        providers.first { $0.kind == kind }
    }

    /// 轨道头图标：命中的呈现片给图标，未知 kind 回落通用符号（同样不 switch kind）。
    static func icon(for kind: TrackKind) -> String {
        provider(for: kind)?.icon ?? "square.stack.3d.up"
    }
}

/// 车道 / 轨道头共用的尺寸常量（同一行内高度对齐靠它）。
enum LaneMetrics {
    static let height: CGFloat = 56
    static let cornerRadius: CGFloat = 4
}
