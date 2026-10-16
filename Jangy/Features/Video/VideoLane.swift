import SwiftUI
import UIKit
import JangyCore

/// 视频轨 L0 呈现片：注册进 `TrackLaneRegistry`。元素按其输出起点 / 时长定位，铺缩略图条
/// （`.gap` → 黑条；图片 `.still` → 单帧铺满；视频 → 源素材抽帧胶片条）。
enum VideoLaneProvider: TrackLaneProvider {
    static let kind = TrackKind.video
    static var icon: String { "film" }

    @MainActor static func makeLane(track: PlanTrack, context: LaneContext) -> AnyView {
        AnyView(VideoLane(track: track, context: context))
    }
}

struct VideoLane: View {
    let track: PlanTrack
    let context: LaneContext

    var body: some View {
        let starts = track.elementOutputStarts()
        let visible = context.viewport.visibleTimeRange
        ZStack(alignment: .topLeading) {
            ForEach(Array(track.elements.enumerated()), id: \.element.id) { index, element in
                let start = index < starts.count ? starts[index] : 0
                elementView(element: element, start: start, visible: visible)
            }
        }
    }

    @ViewBuilder
    private func elementView(element: PlanElement, start: TimeInterval,
                            visible: ClosedRange<TimeInterval>) -> some View {
        let end = start + element.duration
        switch element.content {
        case .gap:
            // 空档：纯黑占位条（链保持连续）。
            Rectangle().fill(.black)
                .frame(width: elementWidth(element), height: LaneMetrics.height)
                .offset(x: context.viewport.contentX(forTime: start))
        case .content(let payload):
            if let clip = payload.value as? PlanClip,
               let asset = context.plan.asset(withID: clip.assetID) {
                if visible.upperBound > start, visible.lowerBound < end {
                    // 可见：铺缩略图条。`.task(id:)` 只在档位变时重取，缩放期间旧帧被拉伸。
                    // 该子视图仅在可见时存在 → 滚入可见时重新起任务、滚出时任务取消。
                    VideoElementStrip(clip: clip, asset: asset, element: element,
                                      start: start, visible: visible, context: context)
                } else {
                    placeholder(element: element, start: start)
                }
            } else {
                // 素材未登记 / payload 类型不符：灰条兜底，不崩。
                placeholder(element: element, start: start)
            }
        }
    }

    /// 元素宽（点）= 输出时长 × px/s。
    private func elementWidth(_ element: PlanElement) -> CGFloat {
        max(1, CGFloat(element.duration) * context.viewport.pointsPerSecond)
    }

    private func placeholder(element: PlanElement, start: TimeInterval) -> some View {
        RoundedRectangle(cornerRadius: LaneMetrics.cornerRadius)
            .fill(Color(.secondarySystemFill))
            .frame(width: elementWidth(element), height: LaneMetrics.height)
            .offset(x: context.viewport.contentX(forTime: start))
    }
}

/// 单段视频元素的缩略图条：只铺「元素与可见区的交集」子区间，缩略图从源素材抽帧。
/// 载荷对应的素材必须是视频；图片元素由调用方走 `thumbnail(for:maxPixel:)` 分支（见 `load`）。
private struct VideoElementStrip: View {
    let clip: PlanClip
    let asset: AssetItem
    let element: PlanElement
    let start: TimeInterval
    let visible: ClosedRange<TimeInterval>
    let context: LaneContext

    @State private var images: [Image?] = []

    var body: some View {
        let pps = context.viewport.pointsPerSecond
        // 元素内可见子区间（输出偏移，秒）：把视口可见区夹到本元素区间。
        let lower = max(0, visible.lowerBound - start)
        let upper = min(element.duration, visible.upperBound - start)
        let stripWidth = max(1, CGFloat(max(0, upper - lower)) * pps)
        let level = ThumbnailLevel.level(forPointsPerSecond: pps)

        HStack(spacing: 0) {
            if images.isEmpty {
                Color(.secondarySystemFill)
            } else {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    Group {
                        if let image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.black   // 未取到的帧位置留黑
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .clipped()
                }
            }
        }
        .frame(width: stripWidth, height: LaneMetrics.height)
        .clipped()
        .offset(x: context.viewport.contentX(forTime: start + lower))
        .task(id: StripTaskID(elementID: element.id, level: level)) {
            await load(lower: lower, upper: upper, level: level)
        }
    }

    /// 抽帧：视频按可见宽度铺 N 帧；图片无源区间（`frames` 恒 nil）→ 单帧降采样图铺满。
    @MainActor
    private func load(lower: TimeInterval, upper: TimeInterval, level: ThumbnailLevel) async {
        let pps = context.viewport.pointsPerSecond
        let stripWidth = max(1, CGFloat(max(0, upper - lower)) * pps)
        switch clip.source {
        case .video:
            let count = max(1, Int(stripWidth / CGFloat(level.rawValue)))
            let span = max(0, upper - lower)
            // 各帧取所在切片中点，避免全部落在同一时间桶。
            let offsets = (0..<count).map { i in lower + span * (Double(i) + 0.5) / Double(count) }
            let cgImages = await context.thumbnailer.frames(asset: asset, clip: clip, level: level,
                                                            outputOffsets: offsets)
            images = cgImages.map { $0.map { Image(decorative: $0, scale: UIScreen.main.scale) } }
        case .still:
            let single = await context.thumbnailer.thumbnail(for: asset, maxPixel: level.rawValue * 2)
            images = [single.map { Image(decorative: $0, scale: UIScreen.main.scale) }]
        }
    }
}

/// `.task(id:)` 的键：元素 id + 档位。缩放（pps）不停变化，但档位是离散的——
/// 只在跨档时重取，档位内的缩放沿用旧帧（被拉伸）。
private struct StripTaskID: Equatable {
    let elementID: UUID
    let level: ThumbnailLevel
}
