import SwiftUI
import JangyCore

/// 字幕轨 L0 呈现片：cue 元素按其 `at` + 时长定位，画圆角条 + 文本。
/// 位置以 `PlanElement.at` 为权威（`elementOutputStarts()` 对绝对轨即各元素的 `at`）。
enum CaptionLaneProvider: TrackLaneProvider {
    static let kind = TrackKind.caption
    static var icon: String { "text.bubble" }

    @MainActor static func makeLane(track: PlanTrack, context: LaneContext) -> AnyView {
        AnyView(CaptionLane(track: track, context: context))
    }
}

struct CaptionLane: View {
    let track: PlanTrack
    let context: LaneContext

    /// 字幕条高度（点）。条在车道内居中，故定位的 y 偏移也由它推出。
    private static let barHeight: CGFloat = 28

    var body: some View {
        let starts = track.elementOutputStarts()
        // 裁剪用 `cullRange`（存储 + 量化）而非 `visibleTimeRange`：后者转调 `playheadTime`，
        // 会让本视图每帧重建。位置一律走 `contentX(forTime:)`（不依赖播放头），平移交给外层叶子。
        let visible = context.viewport.cullRange
        ZStack(alignment: .topLeading) {
            ForEach(Array(track.elements.enumerated()), id: \.element.id) { index, element in
                let start = index < starts.count ? starts[index] : 0
                if visible.upperBound > start, visible.lowerBound < start + element.duration {
                    let geometry = TransientGeometry.make(elementID: element.id, drag: context.drag)
                    cueBar(element: element, geometry: geometry)
                        // 定位与浮起收在这一处（内容块一律不自定位，见 `LaneElementModifier`）。
                        .modifier(LaneElementModifier(
                            geometry: geometry,
                            x: context.viewport.contentX(forTime: start) + geometry.leadingDelta,
                            y: (LaneMetrics.height - Self.barHeight) / 2))
                }
            }
        }
    }

    @ViewBuilder
    private func cueBar(element: PlanElement, geometry: TransientGeometry) -> some View {
        let baseWidth = LaneMetrics.width(forDuration: element.duration, viewport: context.viewport)
        // 字幕不可 trim（无手柄），几何的 leading/trailing 恒 0；move 时浮起由 modifier 处理。
        let width = max(1, baseWidth - geometry.leadingDelta + geometry.trailingDelta)
        let text: String? = {
            if case .content(let payload) = element.content,
               let cue = payload.value as? CaptionCuePayload { return cue.text }
            return nil
        }()
        RoundedRectangle(cornerRadius: LaneMetrics.cornerRadius)
            .fill(Color.accentColor.opacity(0.8))
            .frame(width: width, height: Self.barHeight)
            .overlay(alignment: .leading) {
                if let text {
                    Text(text)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                }
            }
    }
}
