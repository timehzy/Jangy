import JangyCore
import SwiftUI

/// 时间线：可拖分界下方的多轨视图（容器骨架）。水平位置由 `viewport.scrollOffset` 驱动
/// （非 ScrollView 横向滚动）——单指横向拖 = 滚动 = 擦洗（同一手势）；纵向拖交给车道 ScrollView。
/// 车道内容走注册表（`TrackLaneView` + `TrackLaneRegistry`，不 switch 具体轨类型），
/// 轨道头钉视口左缘。选择 / trim / 长按移动 / 轨道重排都在**容器层**做——
/// 几何命中归 L0（`GestureRouter` 只把「命中了什么」翻成会话，见其注释），
/// 车道保持纯呈现（只读 `LaneContext`）。
struct TimelineView: View {
    let model: AppModel
    /// 由分界拖动决定的窗格高度。
    var height: CGFloat
    /// 选中元素 id（纯 L0 局部态，不进 plan）。由 `EditorView` 持有——选中操作条也要读它。
    @Binding var selection: UUID?
    var onAdd: () -> Void

    /// 起手播放头（手势开始时捕获一次）。@GestureState 在手势结束**或取消**时自动复位，
    /// 因此不需要在 .onEnded 里手动清理——取消也不会残留脏基准。
    @GestureState private var scrubBase: TimeInterval?

    /// 双指捏合的起手基准（pps + 累计 magnification，手势开始时捕获一次）。
    /// 同样用 @GestureState：结束**或取消**自动复位，杜绝上一手势残留导致下一手势首帧跳变。
    @GestureState private var magnifyBase: MagnifyBase?

    /// 当前拖拽会话（trim / 移动 / 轨道重排）。同样用 @GestureState——结束**或取消**自动复位，
    /// 拖动途中只由它驱动局部瞬态呈现（元素浮起/伸缩、选中框位移），**EditPlan 一个字节不动**
    /// （公约 §6.5 高频分界）。擦洗据此让位：会话活跃时不做擦洗。
    @GestureState private var drag: DragSession?

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

    /// 车道呈现上下文（plan / 视口 / 解析器 / 缩略图器 / 拖动会话）——车道呈现器只读这里。
    /// `drag` 每帧传入，被拖元素据此做局部浮起；plan 引用不变。
    private var laneContext: LaneContext {
        LaneContext(plan: model.store.plan, viewport: viewport,
                    resolver: model.resolver, thumbnailer: model.thumbnailer, drag: drag)
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

    /// 一行 = 车道（横向平移）+ 元素交互层 + 轨道头（钉视口左缘）；整行裁到视口宽。
    /// 轨道头是车道**偏移之外**的兄弟 —— 横向平移只作用于车道，轨道头不动，行内纵向自然对齐。
    /// 交互层夹在车道与轨道头之间：铺满整行（承接空白点选），但轨道头在最上层，其按钮/长按优先。
    private func laneRow(track: PlanTrack, number: Int,
                         viewportWidth: CGFloat, totalWidth: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            TrackLaneView(track: track, context: laneContext)
                .frame(width: totalWidth, height: LaneMetrics.height, alignment: .topLeading)
                .offset(x: -viewport.scrollOffset)
            elementInteractionLayer(track: track, viewportWidth: viewportWidth)
            TrackCap(track: track, number: number,
                     isPrimary: track.id == model.store.plan.primaryTrackID,
                     onToggleMute: { setTrackFlag(track.id) { $0.isMuted.toggle() } },
                     onToggleHidden: { setTrackFlag(track.id) { $0.isHidden.toggle() } })
                .offset(y: reorderCapOffset(for: track.id))
                .zIndex(reorderCapOffset(for: track.id) == 0 ? 0 : 1)
                .gesture(reorderGesture(trackID: track.id))
        }
        .frame(width: viewportWidth, height: LaneMetrics.height, alignment: .leading)
        .clipped()
    }

    // MARK: 元素交互层（点选 / trim 手柄 / 长按移动）

    /// 元素交互层：铺在车道内容之上、轨道头之下。
    /// - 底部全行透明层承载「点空白 = 取消选择」（点中元素由上层命中层接管，不会落到这里）；
    /// - 每个**内容**元素上盖一个透明命中层：点它选中、长按拖动移动（gap 不参与，点它即视为空白）；
    /// - 选中元素再叠加边框与 trim 手柄。
    /// 所有层都只读 `drag` / `selection` 做瞬时呈现，不改 plan。
    private func elementInteractionLayer(track: PlanTrack, viewportWidth: CGFloat) -> some View {
        let starts = track.elementOutputStarts()
        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { selection = nil }
            ForEach(Array(track.elements.enumerated()), id: \.element.id) { index, element in
                if case .content = element.content {
                    elementInteraction(element: element, track: track,
                                       start: index < starts.count ? starts[index] : 0)
                }
            }
        }
        .frame(width: viewportWidth, height: LaneMetrics.height, alignment: .topLeading)
    }

    /// 单个元素的交互层：透明命中层（点选 + 长按移动，跟随拖动态位移到手指下）+ 选中框 + trim 手柄。
    /// 位置由 `viewportX(forTime:)` + 拖动瞬态几何推出，与车道内容同源换算。
    private func elementInteraction(element: PlanElement, track: PlanTrack,
                                    start: TimeInterval) -> some View {
        let geometry = TransientGeometry.make(elementID: element.id, drag: drag)
        let baseWidth = LaneMetrics.width(forDuration: element.duration, viewport: viewport)
        let width = max(1, baseWidth - geometry.leadingDelta + geometry.trailingDelta)
        let x = viewport.viewportX(forTime: start) + geometry.leadingDelta + geometry.offsetX
        return ZStack(alignment: .leading) {
            Color.clear
                .frame(width: width, height: LaneMetrics.height)
                .contentShape(Rectangle())
                .onTapGesture { selection = element.id }
                .gesture(moveGesture(element: element, track: track))
            if selection == element.id {
                RoundedRectangle(cornerRadius: LaneMetrics.cornerRadius)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: width, height: LaneMetrics.height)
                    .allowsHitTesting(false)
                trimHandle(elementID: element.id, edge: .leading)
                    .offset(x: -8)
                trimHandle(elementID: element.id, edge: .trailing)
                    .offset(x: width - 8)
            }
        }
        .frame(width: width, height: LaneMetrics.height, alignment: .leading)
        .offset(x: x, y: geometry.offsetY)
    }

    /// trim 手柄：竖条 + 内侧白条，命中区比视觉略宽（`frame(width: 16)`）。
    private func trimHandle(elementID: UUID, edge: DragSession.Edge) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor)
            .frame(width: 16, height: LaneMetrics.height)
            .overlay(Capsule().foregroundStyle(.white).frame(width: 2, height: 18))
            .contentShape(Rectangle())
            .highPriorityGesture(trimGesture(elementID: elementID, edge: edge))
    }

    // MARK: 手势 → 会话 → 原子编辑

    /// 长按元素浮起后拖动 = 移动 / 换轨。`LongPressGesture` 成功即浮起（translation 0），
    /// 随后 `DragGesture` 累计位移；抬手 `resolve` → 一个原子编辑。
    /// 拖动全程只写 `@GestureState drag`（经 `.updating`），plan 不动。
    private func moveGesture(element: PlanElement, track: PlanTrack) -> some Gesture {
        let kind = GestureRouter.liftSession(for: .element(id: element.id), plan: model.store.plan)?.kind
        return LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($drag) { value, state, _ in
                guard let kind else { return }
                switch value {
                case .first(true):
                    state = DragSession(kind: kind)
                case .second(true, let dragValue):
                    state = DragSession(kind: kind).translated(to: dragValue?.translation ?? .zero)
                default:
                    break
                }
            }
            .onChanged { value in
                // 浮起即选中（拖动中的元素高亮，操作条同步）。
                if case .second(true, _) = value { selection = element.id }
            }
            .onEnded { value in
                guard let kind, case .second(true, let dragValue) = value else { return }
                resolveAndApply(DragSession(kind: kind).translated(to: dragValue?.translation ?? .zero))
            }
    }

    /// 拖 trim 手柄 = 伸缩片段。`minimumDistance` 取 1（< 擦洗的 8）——手柄先起手并写 `drag`，
    /// 擦洗的 onChanged 首帧即读到 drag 非空而让位，杜绝「先擦一下再 trim」的抢跑。
    private func trimGesture(elementID: UUID, edge: DragSession.Edge) -> some Gesture {
        let kind = GestureRouter.trimSession(for: .trimHandle(elementID: elementID, edge: edge))?.kind
        return DragGesture(minimumDistance: 1)
            .updating($drag) { value, state, _ in
                guard let kind else { return }
                state = DragSession(kind: kind).translated(to: value.translation)
            }
            .onEnded { value in
                guard let kind else { return }
                resolveAndApply(DragSession(kind: kind).translated(to: value.translation))
            }
    }

    /// 长按轨道头上下拖 = 轨道重排。与元素移动同构。
    private func reorderGesture(trackID: UUID) -> some Gesture {
        let kind = GestureRouter.liftSession(for: .trackCap(trackID: trackID), plan: model.store.plan)?.kind
        return LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($drag) { value, state, _ in
                guard let kind else { return }
                switch value {
                case .first(true):
                    state = DragSession(kind: kind)
                case .second(true, let dragValue):
                    state = DragSession(kind: kind).translated(to: dragValue?.translation ?? .zero)
                default:
                    break
                }
            }
            .onEnded { value in
                guard let kind, case .second(true, let dragValue) = value else { return }
                resolveAndApply(DragSession(kind: kind).translated(to: dragValue?.translation ?? .zero))
            }
    }

    /// 抬手解析：会话 → 原子编辑（nil = 净变化为零）→ 落一次 `EditStore.apply`（单撤销步）。
    private func resolveAndApply(_ session: DragSession) {
        guard let edit = session.resolve(in: makeDragContext()) else { return }
        model.applyTimelineEdit(edit)
    }

    /// 拖拽解析上下文：全部取自当前 plan + 视口。吸附容差按屏上 8 点折成秒（随缩放变）。
    private func makeDragContext() -> DragContext {
        let pps = viewport.pointsPerSecond
        return DragContext(plan: model.store.plan,
                           pointsPerSecond: pps,
                           snapPoints: SnapEngine.snapPoints(in: model.store.plan),
                           snapTolerance: TimeInterval(8 / max(1, pps)),
                           trackRowHeight: LaneMetrics.height + 2,
                           minElementDuration: 0.2)
    }

    /// 轨道重排时轨道头的纵向跟手感（横向不跟）；未重排本轨时为 0。
    private func reorderCapOffset(for trackID: UUID) -> CGFloat {
        guard let drag, case .reorderTrack(let id) = drag.kind, id == trackID else { return 0 }
        return drag.translation.height
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
            // 角标可见性由捏合活跃态驱动：手势态非空 = 捏合中。
            ZoomBadge(viewport: viewport, isZooming: magnifyBase != nil)
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
    /// **拖拽会话或双指缩放进行中一律让位**：元素 trim / 移动、轨道重排都不该顺带擦洗。
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($scrubBase) { _, state, _ in
                if state == nil { state = viewport.playheadTime }
            }
            .onChanged { value in
                guard drag == nil, magnifyBase == nil else { return }   // 编辑拖拽/缩放期间不擦洗
                guard let base = scrubBase else { return }
                guard abs(value.translation.width) >= abs(value.translation.height) else { return }
                let target = base - TimeInterval(value.translation.width / viewport.pointsPerSecond)
                viewport.setPlayhead(target)
                model.scrubTo(viewport.playheadTime)
            }
            .onEnded { _ in
                guard drag == nil, magnifyBase == nil else { return }   // 编辑拖拽/缩放中不做收尾 seek
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
