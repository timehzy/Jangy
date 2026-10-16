import SwiftUI
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
        // 拖动瞬态几何：trim 时伸缩内容宽度、move 时整体浮起（见末尾 modifier）。
        let geometry = TransientGeometry.make(elementID: element.id, drag: context.drag)
        let end = start + element.duration
        // 只渲染可见区：元素输出区间与视口不相交（离屏）→ 完全不建视图。
        if visible.upperBound > start, visible.lowerBound < end {
            Group {
                switch element.content {
                case .gap:
                    // 空档：纯黑占位条（链保持连续）。不可拖，几何恒为恒等。
                    Rectangle().fill(.black)
                        .frame(width: LaneMetrics.width(forDuration: element.duration, viewport: context.viewport),
                               height: LaneMetrics.height)
                        .offset(x: context.viewport.contentX(forTime: start))
                case .content(let payload):
                    if let clip = payload.value as? PlanClip,
                       let asset = context.plan.asset(withID: clip.assetID) {
                        // `.task(id:)` 只在「档位 + 可见桶」变化时重取（见 StripTaskID）。
                        VideoElementStrip(clip: clip, asset: asset, element: element,
                                          start: start, visible: visible, context: context, geometry: geometry)
                    } else {
                        // 素材未登记 / payload 类型不符：灰条兜底，不崩。
                        placeholder(element: element, start: start, geometry: geometry)
                    }
                }
            }
            .modifier(ElementLiftModifier(geometry: geometry))
        }
    }

    private func placeholder(element: PlanElement, start: TimeInterval,
                             geometry: TransientGeometry) -> some View {
        let baseWidth = LaneMetrics.width(forDuration: element.duration, viewport: context.viewport)
        return RoundedRectangle(cornerRadius: LaneMetrics.cornerRadius)
            .fill(Color(.secondarySystemFill))
            .frame(width: max(1, baseWidth - geometry.leadingDelta + geometry.trailingDelta),
                   height: LaneMetrics.height)
            .offset(x: context.viewport.contentX(forTime: start) + geometry.leadingDelta)
    }
}

/// 单段视频元素的缩略图条：只铺「元素与可见区的交集」子区间，缩略图从源素材抽帧。
/// 图片元素由 `load` 走 `thumbnail(for:maxPixel:)` 分支（`frames` 对 `.still` 恒 nil）。
private struct VideoElementStrip: View {
    let clip: PlanClip
    let asset: AssetItem
    let element: PlanElement
    let start: TimeInterval
    let visible: ClosedRange<TimeInterval>
    let context: LaneContext
    /// 拖动瞬态几何（trim 时伸缩本条宽度，与选中框同源）。
    let geometry: TransientGeometry

    @Environment(\.displayScale) private var displayScale
    @State private var images: [Image?] = []

    /// 缩略图时间桶（秒）：与 `TimelineThumbnailer` 缓存粒度一致。
    private static let bucket: TimeInterval = 0.5

    var body: some View {
        let pps = context.viewport.pointsPerSecond
        // 元素内可见子区间（输出偏移，秒）：把视口可见区夹到本元素区间。
        let lower = max(0, visible.lowerBound - start)
        let upper = min(element.duration, visible.upperBound - start)
        // trim 预览：按瞬态增量伸缩条宽 / 平移左缘，与选中框一致。
        let stripWidth = max(1, CGFloat(max(0, upper - lower)) * pps
                                - geometry.leadingDelta + geometry.trailingDelta)
        let level = ThumbnailLevel.level(forPointsPerSecond: pps)
        let stripID = StripTaskID(
            elementID: element.id, level: level,
            lowerBucket: Int((lower / Self.bucket).rounded(.down)),
            upperBucket: Int((upper / Self.bucket).rounded(.up)))
        let scale = displayScale

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
        .offset(x: context.viewport.contentX(forTime: start + lower) + geometry.leadingDelta)
        .task(id: stripID) {
            // debounce：手势期间可见桶连续变化会不断重启本任务，睡一小会儿把中间态吃掉。
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await load(lower: lower, upper: upper, level: level, scale: scale)
        }
    }

    /// 抽帧：视频按可见宽度铺 N 帧；图片无源区间（`frames` 恒 nil）→ 单帧降采样图铺满。
    @MainActor
    private func load(lower: TimeInterval, upper: TimeInterval,
                      level: ThumbnailLevel, scale: CGFloat) async {
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
            images = cgImages.map { $0.map { Image(decorative: $0, scale: scale) } }
        case .still:
            let single = await context.thumbnailer.thumbnail(for: asset, maxPixel: level.rawValue * 2)
            images = [single.map { Image(decorative: $0, scale: scale) }]
        }
    }
}

/// `.task(id:)` 的键：元素 id + 档位 + **可见桶范围**（0.5s 桶，和缩略图缓存同粒度）。
/// 档位离散（80/160/320）——缩放跨档才换档；可见桶让滚动/缩放换了可见区后重取，
/// 又因桶量化 + debounce，手势期间的连续变化被合并成一次请求。
private struct StripTaskID: Equatable {
    let elementID: UUID
    let level: ThumbnailLevel
    let lowerBucket: Int
    let upperBucket: Int
}
