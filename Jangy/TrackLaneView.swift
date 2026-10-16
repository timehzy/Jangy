import SwiftUI
import JangyCore

/// 注册表驱动的车道容器：命中呈现片则调它，未知 kind 回落通用灰条车道。
/// **不得 switch 具体轨类型**（公约 §1）——分派一律走 `TrackLaneRegistry`。
struct TrackLaneView: View {
    let track: PlanTrack
    let context: LaneContext

    var body: some View {
        if let provider = TrackLaneRegistry.provider(for: track.kind) {
            provider.makeLane(track: track, context: context)
        } else {
            GenericLane(track: track, viewport: context.viewport)
        }
    }
}

/// 通用车道：不认识 kind 时只按元素输出区间的时长画灰条，不崩、不 switch kind。
private struct GenericLane: View {
    let track: PlanTrack
    let viewport: TimelineViewportState

    var body: some View {
        let starts = track.elementOutputStarts()
        ZStack(alignment: .topLeading) {
            ForEach(Array(track.elements.enumerated()), id: \.element.id) { index, element in
                let start = index < starts.count ? starts[index] : 0
                RoundedRectangle(cornerRadius: LaneMetrics.cornerRadius)
                    .fill(Color(.secondarySystemFill))
                    .frame(width: max(1, CGFloat(element.duration) * viewport.pointsPerSecond),
                           height: LaneMetrics.height)
                    .offset(x: viewport.contentX(forTime: start))
            }
        }
    }
}
