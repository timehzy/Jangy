import SwiftUI
import JangyCore

/// 视频轨 L0 呈现片：注册进 `TrackLaneRegistry`。元素按其输出起点 / 时长定位；
/// 视频元素铺**帧格胶片条**（格宽 = 车道高 × 素材宽高比，屏幕上恒定），
/// 图片元素整条铺一张（图片没有源区间，切成多格只会重复同一帧），`.gap` → 黑条。
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
        // 裁剪用 `cullRange`（存储 + 量化）而非 `visibleTimeRange`：后者转调 `playheadTime`，
        // 会让本视图在滚动 / 播放的**每一帧**重建。位置一律走 `contentX(forTime:)`（不依赖播放头），
        // 横向平移交给外层 `ScrollingOffset` 叶子（见 `TimelineView` 的类注释）。
        let window = context.viewport.cullRange
        ZStack(alignment: .topLeading) {
            ForEach(Array(track.elements.enumerated()), id: \.element.id) { index, element in
                let start = index < starts.count ? starts[index] : 0
                elementView(element: element, start: start, window: window)
            }
        }
    }

    @ViewBuilder
    private func elementView(element: PlanElement, start: TimeInterval,
                            window: ClosedRange<TimeInterval>) -> some View {
        // 拖动瞬态几何：trim 时伸缩内容宽度、move 时整体浮起（见末尾 modifier）。
        let geometry = TransientGeometry.make(elementID: element.id, drag: context.drag)
        let end = start + element.duration
        // 只渲染窗口内：元素输出区间与裁剪窗口不相交（离屏）→ 完全不建视图。
        if window.upperBound > start, window.lowerBound < end {
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
                        VideoElementStrip(clip: clip, asset: asset, element: element,
                                          start: start, window: window, context: context, geometry: geometry)
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

/// 单段元素的胶片条（视频与图片同一条路径）。格**布局**身份 = 元素 id + 全局格索引，
/// 与可见区 / 播放头无关——所以横向滚动与播放期间既不重建、也不重取（格索引只在裁剪窗口跨屏时才变）。
/// 帧的复用靠 `FrameKey`（见其注释）。图片没有源区间：任一格都是同一张图。
private struct VideoElementStrip: View {
    let clip: PlanClip
    let asset: AssetItem
    let element: PlanElement
    let start: TimeInterval
    let window: ClosedRange<TimeInterval>
    let context: LaneContext
    /// 拖动瞬态几何（trim 时伸缩本条宽度，与选中框同源）。
    let geometry: TransientGeometry

    @Environment(\.displayScale) private var displayScale
    /// 已取到的帧，键 = **帧身份**（见 `FrameKey`），不是格索引。
    /// 用格索引当键会在映射变化后错位：索引 → 源时间的映射依赖 `cellDuration`（即 pps）与 clip 源区间，
    /// 缩放（pps 变）或 trim / 变速（源区间变）之后同一索引指向了另一帧，而已取到的旧帧不会被重取。
    @State private var frames: [FrameKey: CGImage] = [:]
    /// 已采纳的格宽比例：从抽到的图里认出「元数据方向不对」时**定住**，不再回退。
    /// **必须独立于 `frames`**——`frames` 会被 `load` 按 `wanted` 裁掉，而 `wanted` 由格宽推出：
    /// 若格宽直接读 `frames`，裁剪把它清空的瞬间格宽会退回元数据、下一轮又变回来，形成振荡
    /// （旧竖拍素材会一直在「横带裁切 ↔ 灰底」之间闪）。
    @State private var adoptedAspect: AdoptedAspect?

    var body: some View {
        filmStrip
            .offset(x: context.viewport.contentX(forTime: start) + geometry.leadingDelta)
    }

    // MARK: 帧格胶片条

    private var filmStrip: some View {
        let cellWidth = TimelineFilmstrip.cellWidth(laneHeight: LaneMetrics.height,
                                                   aspectRatio: cellAspect)
        let cells = TimelineFilmstrip.cells(start: start, duration: element.duration,
                                            pointsPerSecond: context.viewport.pointsPerSecond,
                                            cellWidth: cellWidth, window: window)
        let maxPixel = Self.maxPixel(displayScale: displayScale)
        // 抽帧范围比渲染范围更宽：帧在被看见之前就抽好（见 `fetchWindow`）。
        let wanted = wantedFrames(cellWidth: cellWidth, maxPixel: maxPixel)
        let stripWidth = max(1, LaneMetrics.width(forDuration: element.duration, viewport: context.viewport)
                                - geometry.leadingDelta + geometry.trailingDelta)
        return ZStack(alignment: .topLeading) {
            ForEach(cells, id: \.index) { cell in
                let key = frameKey(for: cell, maxPixel: maxPixel)
                Group {
                    // 自己的帧还没抽好时用**最近已抽好的帧**顶替，不留灰底——
                    // 否则滚动时能看到「空白 → 缩略图」的跳变（降级登记见架构公约 §6.4）。
                    if let image = frames[key] ?? nearbyLoadedFrame(to: key.time, cellWidth: cellWidth) {
                        Image(decorative: image, scale: displayScale)
                            .resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color(.secondarySystemFill)
                    }
                }
                .frame(width: cell.width, height: LaneMetrics.height)
                .clipped()
                // 格相对**条**起点定位（`i·cellWidth`）。前缘 trim 的位移已由整条的 offset 施加，
                // 这里再加一次会让胶片条比选中框多平移一个 leadingDelta。
                .offset(x: cell.x)
            }
        }
        .frame(width: stripWidth, height: LaneMetrics.height, alignment: .topLeading)
        .clipped()   // 末格越过元素尾部时裁掉
        // 键就是「要抽哪些帧」：映射（pps / clip 源区间 / 素材 / 像素档）一变就换键、任务重启，
        // 已取到的旧帧同时被裁掉——不会出现「键没变、帧却已不是那一帧」的错位。
        .task(id: wanted.keys.sorted { $0.time < $1.time }) {
            // 先用**缓存里已有的**帧铺一遍（不抽帧、不等 debounce）：元素被裁剪窗移出时视图连同
            // `@State` 一起销毁，滚回来重建时若直接等 debounce，整条会先空白一下再出现。
            await load(wanted: wanted, cacheOnly: true)
            // debounce：捏合缩放时格的时间间距连续变、会不断重启本任务，睡一小会儿把中间态吃掉。
            // 抽帧范围比可见区宽 1 屏以上，正常滚动 / 播放期间这段延迟落在离屏期，不影响观感。
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            await load(wanted: wanted)
        }
    }

    /// 抽帧窗：比渲染窗（`window`）前后各多半屏（`window` 本身是 2~4 屏宽，故实际余量 0.5~1 屏）。
    /// 渲染仍只建 `window` 内的格——这里只用来**提前抽帧**，让帧在进入可见区之前就已就绪。
    private var fetchWindow: ClosedRange<TimeInterval> {
        let half = (window.upperBound - window.lowerBound) / 4
        return (window.lowerBound - half)...(window.upperBound + half)
    }

    /// 格宽用的宽高比：**已采纳的图比例**优先，其次素材元数据。
    /// 元数据是**未应用方向**的原始尺寸（视频 `naturalSize` 未过 `preferredTransform`、
    /// 图片未过 EXIF orientation），竖拍素材会因此算成横屏格宽、把画面重新裁成横带；
    /// 图比例由抽帧器摆正，故以它为准（采纳时机见 `load`）。
    private var cellAspect: CGFloat? {
        if let adoptedAspect, adoptedAspect.assetID == asset.id { return adoptedAspect.aspect }
        return Self.aspectRatio(of: asset)
    }

    /// 格 → 帧身份。图片没有源区间（`sourceTime` 为 nil）→ 统一用源时间 0，
    /// 与 `TimelineThumbnailer` 的单帧缓存口径一致，于是所有格共用同一张图。
    private func frameKey(for cell: TimelineFilmstrip.Cell, maxPixel: Int) -> FrameKey {
        FrameKey(assetID: asset.id, maxPixel: maxPixel,
                 time: clip.sourceTime(forOutputOffset: cell.outputOffset) ?? 0)
    }

    /// 已取到的帧里离 `time` 最近的那张，**只在两个格宽以内才顶替**。
    /// 上限是必要的：裁剪窗整块跳走时（点选远跳 / Agent 编辑 / 长甩），`frames` 里剩的还是旧窗口的帧，
    /// 无上限地顶替会闪出一帧几屏之外的内容——那不如留灰底诚实。
    /// 同距时按键的时间定序，避免字典遍历顺序带来的抖动。
    private func nearbyLoadedFrame(to time: TimeInterval, cellWidth: CGFloat) -> CGImage? {
        // 帧键是**源时间**，相邻格在源时间上隔 rate × 格时长（不是格时长本身）。
        let limit = 2 * TimeInterval(cellWidth / context.viewport.pointsPerSecond) * clip.speed.rate
        let nearest = frames.min { a, b in
            let da = abs(a.key.time - time), db = abs(b.key.time - time)
            return da == db ? a.key.time < b.key.time : da < db
        }
        guard let nearest, nearest.key.assetID == asset.id,
              abs(nearest.key.time - time) <= limit else { return nil }
        return nearest.value
    }

    /// 抽帧窗要取的帧：**帧身份 → 该帧对应的输出偏移**（同一帧的多个格共用一个键）。
    private func wantedFrames(cellWidth: CGFloat, maxPixel: Int) -> [FrameKey: TimeInterval] {
        let cells = TimelineFilmstrip.cells(start: start, duration: element.duration,
                                            pointsPerSecond: context.viewport.pointsPerSecond,
                                            cellWidth: cellWidth, window: fetchWindow)
        var wanted: [FrameKey: TimeInterval] = [:]
        for cell in cells {
            let key = frameKey(for: cell, maxPixel: maxPixel)
            if wanted[key] == nil { wanted[key] = cell.outputOffset }
        }
        return wanted
    }

    /// 取帧并合并。`cacheOnly` = 只查缓存、不抽帧（重建时先铺一遍，见 `.task`）。
    /// 只请求缺失的帧；同时把抽帧窗外的旧帧裁掉（否则随滚动无界增长）。
    @MainActor
    private func load(wanted: [FrameKey: TimeInterval], cacheOnly: Bool = false) async {
        if !frames.keys.allSatisfy(wanted.keys.contains) {
            frames = frames.filter { wanted.keys.contains($0.key) }
        }
        let missing = wanted.filter { frames[$0.key] == nil }.sorted { $0.key.time < $1.key.time }
        guard !missing.isEmpty else { return }
        // 本条所有帧身份共用同一像素档（同一次 body 求出），取任一即可。
        let maxPixel = missing[0].key.maxPixel
        let offsets = missing.map { $0.value }
        let images = cacheOnly
            ? await context.thumbnailer.cachedFrames(asset: asset, clip: clip, maxPixel: maxPixel,
                                                     outputOffsets: offsets)
            : await context.thumbnailer.frames(asset: asset, clip: clip, maxPixel: maxPixel,
                                               outputOffsets: offsets)
        guard !Task.isCancelled else { return }
        // 重新读 `frames` 再合并：await 期间可能已有别的加载写入，基于旧值写会丢更新。
        var next = frames
        for (entry, image) in zip(missing, images) {
            if let image { next[entry.key] = image }
        }
        frames = next
        adoptAspectIfNeeded(from: images)
    }

    /// 从抽到的图里认出方向：**只在图比例与元数据差到方向级别**（相对差 > 5%）时采纳。
    /// 元数据方向错是 2~3 倍量级的差，而抽帧尺寸取整只有千分之几——后者不该改格宽，
    /// 否则每个元素都会在首帧到达后重算格宽、白重抽一轮。
    /// 采纳后**定住**（见 `adoptedAspect`），所以最多只多一轮重排。
    private func adoptAspectIfNeeded(from images: [CGImage?]) {
        guard let image = images.compactMap({ $0 }).first, image.height > 0,
              let metadata = Self.aspectRatio(of: asset), metadata > 0 else { return }
        let actual = CGFloat(image.width) / CGFloat(image.height)
        guard abs(actual - metadata) / metadata > 0.05 else { return }
        guard adoptedAspect?.assetID != asset.id || adoptedAspect?.aspect != actual else { return }
        adoptedAspect = AdoptedAspect(assetID: asset.id, aspect: actual)
    }

    // MARK: 尺寸

    /// 素材宽高比；探测失败（nil / 非正）→ nil，由 `TimelineFilmstrip` 兜底 16:9。
    private static func aspectRatio(of asset: AssetItem) -> CGFloat? {
        guard let w = asset.pixelWidth, let h = asset.pixelHeight, w > 0, h > 0 else { return nil }
        return CGFloat(w) / CGFloat(h)
    }

    /// 抽帧像素高 = 车道高的物理像素，**量化到 64 的倍数**——连续值会把缩略图缓存碎成大量条目、命中率崩。
    static func maxPixel(displayScale: CGFloat) -> Int {
        let raw = LaneMetrics.height * max(1, displayScale)
        return max(64, Int((raw / 64).rounded(.up)) * 64)
    }
}

/// **帧身份**：素材 + 像素档 + 源时间。三者任一变了就是另一帧，缓存键与 `.task(id:)` 都用它——
/// 元素 id 是稳定的（原地更新），所以不能只靠元素身份判断「帧还是那一帧」。
private struct FrameKey: Hashable {
    let assetID: UUID
    let maxPixel: Int
    let time: TimeInterval
}

/// 已采纳的格宽比例（连同它属于哪个素材——元素原地换素材时不能沿用旧比例）。
private struct AdoptedAspect: Equatable {
    let assetID: UUID
    let aspect: CGFloat
}
