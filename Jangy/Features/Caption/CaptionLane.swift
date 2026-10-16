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

    var body: some View {
        let starts = track.elementOutputStarts()
        let visible = context.viewport.visibleTimeRange
        ZStack(alignment: .topLeading) {
            ForEach(Array(track.elements.enumerated()), id: \.element.id) { index, element in
                let start = index < starts.count ? starts[index] : 0
                if visible.upperBound > start, visible.lowerBound < start + element.duration {
                    cueBar(element: element, start: start)
                }
            }
        }
    }

    @ViewBuilder
    private func cueBar(element: PlanElement, start: TimeInterval) -> some View {
        let width = LaneMetrics.width(forDuration: element.duration, viewport: context.viewport)
        let barHeight: CGFloat = 28
        let text: String? = {
            if case .content(let payload) = element.content,
               let cue = payload.value as? CaptionCuePayload { return cue.text }
            return nil
        }()
        RoundedRectangle(cornerRadius: LaneMetrics.cornerRadius)
            .fill(Color.accentColor.opacity(0.8))
            .frame(width: width, height: barHeight)
            .overlay(alignment: .leading) {
                if let text {
                    Text(text)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                }
            }
            .offset(x: context.viewport.contentX(forTime: start),
                    y: (LaneMetrics.height - barHeight) / 2)
    }
}
