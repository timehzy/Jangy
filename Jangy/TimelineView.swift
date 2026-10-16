import JangyCore
import SwiftUI

/// 时间线：可拖分界下方的多轨视图（容器骨架）。水平位置由 `viewport.scrollOffset` 驱动
/// （非 ScrollView 横向滚动）——单指横向拖 = 滚动 = 擦洗（同一手势）；纵向拖交给车道 ScrollView。
/// 车道内容走注册表（`TrackLaneView` + `TrackLaneRegistry`，不 switch 具体轨类型），
/// 轨道头钉视口左缘；选择/trim/移动留给后续任务。
struct TimelineView: View {
    let model: AppModel
    /// 由分界拖动决定的窗格高度。
    var height: CGFloat
    var onAdd: () -> Void

    /// 起手播放头（手势开始时捕获一次）。@GestureState 在手势结束**或取消**时自动复位，
    /// 因此不需要在 .onEnded 里手动清理——取消也不会残留脏基准。
    @GestureState private var scrubBase: TimeInterval?

    /// 双指捏合的起手基准（pps + 累计 magnification，手势开始时捕获一次）。
    /// 同样用 @GestureState：结束**或取消**自动复位，杜绝上一手势残留导致下一手势首帧跳变。
    @GestureState private var magnifyBase: MagnifyBase?

    private var viewport: TimelineViewportState { model.viewport }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                contentLayer(viewportWidth: geo.size.width)
                PlayheadOverlay(time: viewport.playheadTime)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            // 固定为视口尺寸：内容层比视口宽，靠它兜住 ZStack 尺寸，
            // 否则 maxWidth: .infinity 会居中到「内容宽度」而非视口中央。
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(scrubGesture)
            .simultaneousGesture(magnifyGesture)
            .overlay(alignment: .bottomTrailing) { bottomControls }
            .onAppear { viewport.viewportWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, w in viewport.viewportWidth = w }
        }
        .frame(height: height)
        // 只有播放推进才回写播放头；擦洗时 player 是暂停的（rate 0），不会回跳。
        .onChange(of: model.player.currentTime) { _, t in
            if model.player.isPlaying { viewport.setPlayhead(t) }
        }
    }

    /// 车道呈现上下文（plan / 视口 / 解析器 / 缩略图器）——车道呈现器只读这里。
    private var laneContext: LaneContext {
        LaneContext(plan: model.store.plan, viewport: viewport,
                    resolver: model.resolver, thumbnailer: model.thumbnailer)
    }

    /// 内容层：标尺 + 轨道行。横向位置由 `-scrollOffset` 驱动，但**只作用于标尺与车道内容**；
    /// 轨道头钉在视口左缘（不参与横向平移，见 `laneRow` / `TrackCap`）。
    /// 标尺与车道的局部坐标原点都落在「内容坐标 x=0」——都按 `contentX(forTime:)` 定位，故对齐。
    private func contentLayer(viewportWidth: CGFloat) -> some View {
        let totalWidth = viewportWidth + contentWidth
        return VStack(spacing: 0) {
            // 标尺：竖向钉顶；横向整体平移后裁到视口宽。
            RulerView(viewport: viewport)
                .frame(width: totalWidth, height: 24, alignment: .leading)
                .offset(x: -viewport.scrollOffset)
                .frame(width: viewportWidth, height: 24, alignment: .leading)
                .clipped()
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(Array(model.store.plan.tracks.enumerated()), id: \.element.id) { index, track in
                        laneRow(track: track, number: index + 1, viewportWidth: viewportWidth,
                                totalWidth: totalWidth)
                    }
                }
            }
        }
        .frame(width: viewportWidth, alignment: .leading)
    }

    /// 一行 = 车道（横向平移）+ 轨道头（钉视口左缘）；整行裁到视口宽。
    /// 轨道头是车道**偏移之外**的兄弟 —— 横向平移只作用于车道，轨道头不动，行内纵向自然对齐。
    private func laneRow(track: PlanTrack, number: Int,
                         viewportWidth: CGFloat, totalWidth: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            TrackLaneView(track: track, context: laneContext)
                .frame(width: totalWidth, height: LaneMetrics.height, alignment: .topLeading)
                .offset(x: -viewport.scrollOffset)
            TrackCap(track: track, number: number,
                     isPrimary: track.id == model.store.plan.primaryTrackID,
                     onToggleMute: { setTrackFlag(track.id) { $0.isMuted.toggle() } },
                     onToggleHidden: { setTrackFlag(track.id) { $0.isHidden.toggle() } })
        }
        .frame(width: viewportWidth, height: LaneMetrics.height, alignment: .leading)
        .clipped()
    }

    /// 改某条轨的布尔标记（静音/隐藏）：在内存 plan 里就地改，走统一编辑入口（单撤销步）。
    private func setTrackFlag(_ id: UUID, _ mutate: (inout PlanTrack) -> Void) {
        model.edit { plan in
            guard let i = plan.tracks.firstIndex(where: { $0.id == id }) else { return }
            mutate(&plan.tracks[i])
        }
    }

    /// 内容带宽度（点）= 时长 × px/s。
    private var contentWidth: CGFloat {
        CGFloat(viewport.contentDuration) * viewport.pointsPerSecond
    }

    /// 右下角浮层：缩放档位角标（上）+ ＋ 按钮（下）。锚在视口右下、不随内容横向滚动。
    /// 角标隐去时仍占位（靠 opacity 淡出），＋ 按钮位置稳定不跳。
    private var bottomControls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ZoomBadge(viewport: viewport)
            addButton
        }
        .padding(8)
    }

    private var addButton: some View {
        Button(action: onAdd) {
            Image(systemName: "plus")
                .font(.body.bold())
                .frame(width: 36, height: 36)
                .background(Color.accentColor, in: Circle())
                .foregroundStyle(.white)
                .shadow(radius: 3)
        }
        .buttonStyle(.plain)
        // Agent 运行中禁用：quick-add 上轨会并入 Agent 撤销组
        .disabled(model.agent.isRunning)
    }

    /// 单指横向拖 = 滚动 = 擦洗。与车道纵向 ScrollView 并存（`.simultaneousGesture`）：
    /// 用**累计**位移判断横向为主（逐帧差分会因抖动丢动作），纵向留给 ScrollView。
    /// 播放头 = 起手位置 − 累计横向位移 / pps；起手位置存 `@GestureState`（结束/取消自动复位）。
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($scrubBase) { _, state, _ in
                if state == nil { state = viewport.playheadTime }
            }
            .onChanged { value in
                guard magnifyBase == nil else { return }   // 双指缩放期间不做擦洗（DragGesture 会跟两指质心）
                guard let base = scrubBase else { return }
                guard abs(value.translation.width) >= abs(value.translation.height) else { return }
                let target = base - TimeInterval(value.translation.width / viewport.pointsPerSecond)
                viewport.setPlayhead(target)
                model.scrubTo(viewport.playheadTime)
            }
            .onEnded { _ in
                guard magnifyBase == nil else { return }   // 缩放中不做收尾 seek
                model.scrubEnded()   // 补最终 seek；player 仍暂停，不会回跳
            }
    }

    /// 双指捏合的起手基准：手势开始那一刻的 pps 与累计 magnification。
    /// 存这对值是为了把「**累计** magnification」换算成**绝对**目标 pps——相对起手基准算，
    /// 与逐帧是否读到上一帧无关，故不依赖 `.updating` 与 `.onChanged` 的先后，也不会跨帧累加误差。
    private struct MagnifyBase {
        var pointsPerSecond: CGFloat
        var magnification: CGFloat
    }

    /// 双指捏合 = 缩放 px/s，锚点 = 双指中心（`startAnchor` 是相对视口的 `UnitPoint`，乘视口宽得 anchorX）。
    /// `MagnifyGesture.Value.magnification` 是**整个手势的累计值**（起手 ≈ 1），不是逐帧增量——
    /// 直接喂 `zoom(by:)` 会重复计数，故先按起手基准折成绝对目标，再换算成相对当前 pps 的增量因子。
    /// 起手基准存 `@GestureState`（`.updating` 里捕获一次），手势结束或取消都自动复位，无黏性状态。
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($magnifyBase) { value, state, _ in
                if state == nil {
                    state = MagnifyBase(pointsPerSecond: viewport.pointsPerSecond,
                                        magnification: value.magnification)
                }
            }
            .onChanged { value in
                guard let base = magnifyBase else { return }
                let target = base.pointsPerSecond * (value.magnification / base.magnification)
                viewport.zoom(by: target / viewport.pointsPerSecond,
                              anchorX: value.startAnchor.x * viewport.viewportWidth)
            }
    }
}
