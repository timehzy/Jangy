import JangyCore
import SwiftUI

/// 时间线：可拖分界下方的多轨视图（容器骨架）。水平位置由 `viewport.scrollOffset` 驱动
/// （非 ScrollView 横向滚动）——单指横向拖 = 滚动 = 擦洗（同一手势）；纵向拖交给车道 ScrollView。
/// 车道内容走注册表（`TrackLaneView` + `TrackLaneRegistry`，不 switch 具体轨类型），
/// 轨道头钉视口左缘。选择 / trim / 长按移动 / 轨道重排都在**容器层**做——
/// 几何命中归 L0（`GestureRouter` 只把「命中了什么」翻成会话，见其注释），
/// 车道保持纯呈现（只读 `LaneContext`）。
///
/// **高频量只由叶子视图读取**（`ScrollingOffset` / `PlayheadOverlay` / `PlaybackFollow`）：
/// `@Observable` 的依赖按「body 作用域里读到的 stored 属性」注册（计算属性只是转调 stored getter，
/// 照常注册），本容器 body 一旦读 `scrollOffset` / `playheadTime` / `player.currentTime`，
/// 就会在滚动或播放的每一帧整棵树重建。加新的高频读取前先想清楚它该落在哪个叶子里。
///
/// **内容坐标是唯一约定**：车道内容与元素交互层都在 `contentX(forTime:)` 这套坐标里
/// （其值只依赖 pps + 视口宽，**不依赖播放头**），横向平移统一由 `ScrollingOffset` 施加。
/// 视口坐标（`viewportX(forTime:)`）只留给手势命中判定用（擦洗起手点、trim 手柄区）。
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

    /// 本手势**锁定**的滚动轴：起手那一下的方向定轴，全程不再改（`.updating` 里定一次，
    /// 结束或取消自动复位）。四向解锁会让一次拖拽中途从滚动变成擦洗（或反之），手感很飘。
    /// 它也用来在横向锁定时关掉纵向 ScrollView——否则横拖时纵向仍能被带着滚。
    @GestureState private var scrubAxis: Axis?

    /// 本手势是否真的擦洗过。`onEnded` 靠它判断要不要补 seek / 起惯性——
    /// `@GestureState` 到那时可能已复位，而轴锁成垂直的手势不该有任何副作用。
    @State private var didScrub = false

    /// 双指捏合的起手基准（pps + 累计 magnification，手势开始时捕获一次）。
    /// 同样用 @GestureState：结束**或取消**自动复位，杜绝上一手势残留导致下一手势首帧跳变。
    @GestureState private var magnifyBase: MagnifyBase?

    /// 当前拖拽会话（trim / 移动 / 轨道重排）。同样用 @GestureState——结束**或取消**自动复位，
    /// 拖动途中只由它驱动局部瞬态呈现（元素浮起/伸缩、选中框位移），**EditPlan 一个字节不动**
    /// （公约 §6.5 高频分界）。擦洗据此让位：会话活跃时不做擦洗。
    @GestureState private var drag: DragSession?

    /// 当前惯性推进任务（抬手后按衰减曲线继续滚动）。同一时刻至多一个。
    @State private var flingTask: Task<Void, Never>?

    /// 选中元素所在**行**在 `timeline` 命名坐标系里的 frame（由选中行上报）。
    /// 擦洗结构性让位按「行 Y 带 + 两处 trim 手柄的窄 X 带」判定——只挡选中元素的两处手柄，
    /// 元素体与其它轨的擦洗照常放行。
    @State private var selectedRowFrame: CGRect?

    private var viewport: TimelineViewportState { model.viewport }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                contentLayer(viewportWidth: geo.size.width, viewportHeight: geo.size.height)
                PlayheadOverlay(viewport: viewport)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            // 固定为视口尺寸：内容层比视口宽，靠它兜住 ZStack 尺寸，
            // 否则 maxWidth: .infinity 会居中到「内容宽度」而非视口中央。
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            // 命名坐标系：行上报交互区、擦洗读起手点，都在这一套坐标里（见 canScrub）。
            .coordinateSpace(name: "timeline")
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(scrubGesture)
            .simultaneousGesture(magnifyGesture)
            .overlay(alignment: .bottomTrailing) { bottomControls }
            .background { PlaybackFollow(player: model.player, viewport: viewport) }
            .onAppear { viewport.viewportWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, w in viewport.viewportWidth = w }
            .onDisappear { cancelFling() }
        }
        .frame(height: height)
    }

    /// 车道呈现上下文（plan / 视口 / 解析器 / 缩略图器 / 拖动会话）——车道呈现器只读这里。
    /// `drag` 每帧传入，被拖元素据此做局部浮起；plan 引用不变。
    private var laneContext: LaneContext {
        LaneContext(plan: model.store.plan, viewport: viewport,
                    resolver: model.resolver, thumbnailer: model.thumbnailer, drag: drag)
    }

    /// 内容层：标尺 + 轨道行。横向位置由 `-scrollOffset` 驱动，但**只作用于标尺与车道内容**
    /// （每处各自套 `ScrollingOffset` 叶子）；轨道头钉在视口左缘（不参与横向平移，见 `laneRow` / `TrackCap`）。
    /// 标尺与车道的局部坐标原点都落在「内容坐标 x=0」——都按 `contentX(forTime:)` 定位，故对齐。
    private func contentLayer(viewportWidth: CGFloat, viewportHeight: CGFloat) -> some View {
        let totalWidth = viewportWidth + contentWidth
        return VStack(spacing: 0) {
            // 标尺：竖向钉顶；横向整体平移后裁到视口宽。
            ScrollingOffset(viewport: viewport) {
                RulerView(viewport: viewport)
                    .frame(width: totalWidth, height: Self.rulerHeight, alignment: .leading)
            }
            .frame(width: viewportWidth, height: Self.rulerHeight, alignment: .leading)
            .clipped()
            ScrollView(.vertical) {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(Array(model.store.plan.tracks.enumerated()), id: \.element.id) { index, track in
                        laneRow(track: track, number: index + 1, viewportWidth: viewportWidth,
                                totalWidth: totalWidth)
                    }
                }
            }
            // 轴锁定：本手势锁成横向时关掉纵向滚动，否则横拖仍会被带着上下跑（见 `scrubAxis`）。
            // 另外**装得下就不滚**——纵向 ScrollView 即使内容不溢出也会吸走纵向手势，
            // 让「拖上去没反应、也擦洗不了」。
            .scrollDisabled(scrubAxis == .horizontal
                            || !needsVerticalScroll(viewportHeight: viewportHeight))
        }
        .frame(width: viewportWidth, alignment: .leading)
    }

    /// 一行 = 内容层（车道 + 空白点选 + 元素交互，**统一内容坐标**，横向平移由 `ScrollingOffset` 承载）
    /// + 轨道头（钉视口左缘，是内容层**偏移之外**的兄弟，故不随横向平移）。
    /// 交互层夹在车道与轨道头之间：铺满整行（承接空白点选），但轨道头在最上层，其按钮/长按优先。
    private func laneRow(track: PlanTrack, number: Int,
                         viewportWidth: CGFloat, totalWidth: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ScrollingOffset(viewport: viewport) {
                ZStack(alignment: .topLeading) {
                    TrackLaneView(track: track, context: laneContext)
                        .frame(width: totalWidth, height: LaneMetrics.height, alignment: .topLeading)
                    // 空白点选层：点它 = 取消选择。铺满内容宽（恒覆盖视口），在元素命中层之下。
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: totalWidth, height: LaneMetrics.height)
                        .onTapGesture { selection = nil }
                    elementInteractionLayer(track: track, totalWidth: totalWidth)
                }
                .frame(width: totalWidth, height: LaneMetrics.height, alignment: .topLeading)
            }
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
        .background { selectionRowProbe(track: track) }
    }

    /// 只有**含选中元素的行**才上报它的 frame（在 `timeline` 命名坐标系里）；上报后
    /// `selectedRowFrame` 给出该行的 Y 带。用 `.background` 探测不改变既有布局。
    @ViewBuilder
    private func selectionRowProbe(track: PlanTrack) -> some View {
        if track.elements.contains(where: { $0.id == selection }) {
            GeometryReader { geo in
                let frame = geo.frame(in: .named("timeline"))
                Color.clear
                    .onAppear { reportRowFrame(frame) }
                    .onChange(of: frame) { _, newFrame in reportRowFrame(newFrame) }
            }
        }
    }

    private func reportRowFrame(_ frame: CGRect) {
        if selectedRowFrame != frame { selectedRowFrame = frame }
    }

    // MARK: 元素交互层（点选 / trim 手柄 / 长按移动）

    /// 元素交互层：铺在车道内容之上、轨道头之下，与车道**同一套内容坐标**（同在外层 `ScrollingOffset` 里）。
    /// 每个**内容**元素上盖一个透明命中层：点它选中、长按拖动移动（gap 不参与，点它即视为空白）；
    /// 选中元素再叠加边框与 trim 手柄。所有层都只读 `drag` / `selection` 做瞬时呈现，不改 plan。
    private func elementInteractionLayer(track: PlanTrack, totalWidth: CGFloat) -> some View {
        let starts = track.elementOutputStarts()
        return ZStack(alignment: .topLeading) {
            ForEach(Array(track.elements.enumerated()), id: \.element.id) { index, element in
                if case .content = element.content {
                    elementInteraction(element: element,
                                       start: index < starts.count ? starts[index] : 0)
                }
            }
        }
        .frame(width: totalWidth, height: LaneMetrics.height, alignment: .topLeading)
    }

    /// 单个元素的交互层：透明命中层（点选 + 长按移动，跟随拖动态位移到手指下）+ 选中框 + trim 手柄。
    /// 位置由 `contentX(forTime:)` + 拖动瞬态几何推出，与车道内容同源换算（同一内容坐标）。
    /// 选中框 / trim 手柄只给**可裁剪的片段**（payload 为 `PlanClip`）——字幕 cue 可选中/移动，但无 trim。
    private func elementInteraction(element: PlanElement, start: TimeInterval) -> some View {
        let geometry = TransientGeometry.make(elementID: element.id, drag: drag)
        let baseWidth = LaneMetrics.width(forDuration: element.duration, viewport: viewport)
        let width = max(1, baseWidth - geometry.leadingDelta + geometry.trailingDelta)
        let x = viewport.contentX(forTime: start) + geometry.leadingDelta + geometry.offsetX
        let isClip = Self.hasClipPayload(element)
        return ZStack(alignment: .leading) {
            Color.clear
                .frame(width: width, height: LaneMetrics.height)
                .contentShape(Rectangle())
                .onTapGesture { selection = element.id }
                .gesture(moveGesture(element: element))
            if isClip, selection == element.id {
                RoundedRectangle(cornerRadius: LaneMetrics.cornerRadius)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: width, height: LaneMetrics.height)
                    .allowsHitTesting(false)
                trimHandle(elementID: element.id, edge: .leading)
                    .offset(x: -Self.trimHandleHalfWidth)
                trimHandle(elementID: element.id, edge: .trailing)
                    .offset(x: width - Self.trimHandleHalfWidth)
            }
        }
        .frame(width: width, height: LaneMetrics.height, alignment: .leading)
        .offset(x: x, y: geometry.offsetY)
    }

    /// 元素的 payload 是否是片段（可 trim 的唯一类型）。字幕等其它 payload 不产生 trim 手柄。
    private static func hasClipPayload(_ element: PlanElement) -> Bool {
        guard case .content(let payload) = element.content else { return false }
        return payload.value is PlanClip
    }

    /// trim 手柄：竖条 + 内侧白条，命中区比视觉略宽（`frame(width: 16)`）。
    private func trimHandle(elementID: UUID, edge: DragSession.Edge) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor)
            .frame(width: Self.trimHandleWidth, height: LaneMetrics.height)
            .overlay(Capsule().foregroundStyle(.white).frame(width: 2, height: 18))
            .contentShape(Rectangle())
            .highPriorityGesture(trimGesture(elementID: elementID, edge: edge))
    }

    // MARK: 手势 → 会话 → 原子编辑

    /// 长按元素浮起后拖动 = 移动 / 换轨。`LongPressGesture` 成功即浮起（translation 0），
    /// 随后 `DragGesture` 累计位移；抬手 `resolve` → 一个原子编辑。
    /// 拖动全程只写 `@GestureState drag`（经 `.updating`），plan 不动。
    private func moveGesture(element: PlanElement) -> some Gesture {
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

    /// 标尺高度、轨道行间距（内容层与「是否要纵向滚动」共用同一口径）。
    private static let rulerHeight: CGFloat = 24
    private static let rowSpacing: CGFloat = 2

    /// 纵向是否需要滚动：轨道总高（含行距）超过「视口高 − 标尺」才需要。
    /// 不需要时**关掉纵向 ScrollView**——它即使内容不溢出也会吸走纵向手势，
    /// 让「拖上去没反应、也擦洗不了」。
    ///
    /// 前提：时间线窗格**不压底部安全区**（`EditorView` 是安全区内布局的 VStack）。
    /// 若日后让窗格伸进不安全区，ScrollView 会给内容加底部 inset，而这里仍按
    /// `viewportHeight − 标尺` 估 → 高估可用高 → 误判「装得下」→ 末行够不到。
    private func needsVerticalScroll(viewportHeight: CGFloat) -> Bool {
        let rows = CGFloat(model.store.plan.tracks.count)
        guard rows > 0 else { return false }
        let content = rows * LaneMetrics.height + (rows - 1) * Self.rowSpacing
        return content > max(0, viewportHeight - Self.rulerHeight)
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
    /// 抬手按预测行程起**惯性**（`startFling`），所以甩一下会继续滑、预览跟着滚。
    /// **让位有两层**：① `drag/magnifyBase` 非空（编辑拖拽/缩放进行中）；
    /// ② **结构性**：起手点落在选中元素的**两处 trim 手柄区**内就不擦洗——这不依赖
    /// `drag` 的写入时序，故快速甩动一帧越过 trim 与擦洗两个阈值也不会误擦。
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("timeline"))
            .updating($scrubBase) { _, state, _ in
                if state == nil { state = viewport.playheadTime }
            }
            .updating($scrubAxis) { value, state, _ in
                // 起手那一下（刚过 8pt 阈值）定轴，之后无论怎么拐都不改。
                if state == nil {
                    state = abs(value.translation.width) >= abs(value.translation.height)
                        ? .horizontal : .vertical
                }
            }
            .onChanged { value in
                // 三种「本手势不擦洗」的情形都要**顺手清 didScrub / 停惯性**：
                // 上一手势若被取消（不走 onEnded）标志会残留 true，只有在这里清才能保证
                // onEnded 的判定不误用上一手势的结论；而抓住画面（哪怕纵向）本就该止住惯性。
                guard scrubAxis == .horizontal, canScrub(from: value.startLocation) else {
                    if didScrub { didScrub = false }
                    cancelFling()
                    return
                }
                guard let base = scrubBase else { return }
                cancelFling()   // 手指再动 → 立刻接管惯性
                if !didScrub { didScrub = true }
                let target = base - TimeInterval(value.translation.width / viewport.pointsPerSecond)
                viewport.setPlayhead(target)
                model.scrubTo(viewport.playheadTime)
            }
            .onEnded { value in
                guard didScrub else { return }
                didScrub = false
                // 惯性行程 = 系统按当前速度预测的终点位移 − 已走位移。
                // 向右甩（正）= 时间往前 = 播放头时间减少，与拖拽同号约定。
                let fling = TimelineFling(
                    distance: value.predictedEndTranslation.width - value.translation.width)
                if fling.isFling { startFling(fling) } else { model.scrubEnded() }
            }
    }

    /// 抬手惯性：按衰减曲线继续推进播放头，并（节流）让预览跟随——与擦洗**同一条路径**。
    /// 之所以推进播放头而不是只动 offset：预览要跟着滚，否则松手瞬间预览会跳到终点。
    private func startFling(_ fling: TimelineFling) {
        cancelFling()
        flingTask = Task { @MainActor in
            var decay = fling
            var last = Date()
            while !Task.isCancelled, !decay.isAtRest {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                let now = Date()
                let dt = now.timeIntervalSince(last)
                last = now
                let step = decay.advance(by: dt)
                let before = viewport.playheadTime
                model.scrubTo(before - TimeInterval(step / viewport.pointsPerSecond))
                guard viewport.playheadTime != before else { break }   // 撞到内容边界，停
            }
            guard !Task.isCancelled else { return }
            model.scrubEnded()   // 停稳后补一次精确 seek
        }
    }

    /// 停掉在途惯性。**必须有非空 guard**：本函数在擦洗手势 `onChanged` 里每帧都被调用，
    /// 而 `@State` 写即失效视图（`Task?` 又非 Equatable，赋同值照样通知）——
    /// 无条件写会让擦洗期间容器 body 每帧重建，把「高频量只由叶子读」的隔离白做。
    private func cancelFling() {
        guard flingTask != nil else { return }
        flingTask?.cancel()
        flingTask = nil
    }

    /// 擦洗是否放行：编辑拖拽/缩放进行中、或起手落在**选中元素的 trim 手柄区**内——都不擦洗。
    /// 元素**体上**无拖拽手势（横拖本应擦洗），故体不挡；只有两处手柄区把擦洗让给 trim。
    /// Y 由选中行上报在 `timeline` 命名坐标系里的 frame 给出（见 `selectionRowProbe`）。
    private func canScrub(from startLocation: CGPoint) -> Bool {
        guard drag == nil, magnifyBase == nil else { return false }
        return !isInSelectedTrimHandle(startLocation)
    }

    /// 起手点是否落在选中元素的 trim 手柄区（选中行 Y 带 × 两处手柄 X 带）。
    /// 缺任一半（无选中 / 行 frame 未上报）时返回 false（放行）。
    private func isInSelectedTrimHandle(_ location: CGPoint) -> Bool {
        guard let id = selection, let rowFrame = selectedRowFrame else { return false }
        guard (rowFrame.minY ... rowFrame.maxY).contains(location.y) else { return false }
        for track in model.store.plan.tracks {
            guard let index = track.elements.firstIndex(where: { $0.id == id }) else { continue }
            // 只有片段才画 trim 手柄；字幕 cue 无手柄，故其边缘不得挡擦洗（与呈现路径一致）。
            guard Self.hasClipPayload(track.elements[index]) else { return false }
            let starts = track.elementOutputStarts()
            let start = index < starts.count ? starts[index] : 0
            let leadingX = viewport.viewportX(forTime: start)
            let trailingX = leadingX
                + LaneMetrics.width(forDuration: track.elements[index].duration, viewport: viewport)
            let half = Self.trimHandleHalfWidth
            return (leadingX - half ... leadingX + half).contains(location.x)
                || (trailingX - half ... trailingX + half).contains(location.x)
        }
        return false
    }

    /// trim 手柄宽度（点）及其相对元素边缘的居中偏移——手柄区判定与手柄呈现共用，避免两处对不上。
    private static let trimHandleWidth: CGFloat = 16
    private static var trimHandleHalfWidth: CGFloat { trimHandleWidth / 2 }

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

/// 横向滚动的**叶子**：全时间线唯一读 `viewport.scrollOffset` 的地方。
/// `scrollOffset` 每帧都变（擦洗逐帧、播放每 tick），放这里读就只有这一层 body 重算——
/// 被包裹的 `content` 是已建好的视图值，透传不重建（见 `TimelineView` 的类注释）。
private struct ScrollingOffset<Content: View>: View {
    let viewport: TimelineViewportState
    private let content: Content

    init(viewport: TimelineViewportState, @ViewBuilder content: () -> Content) {
        self.viewport = viewport
        self.content = content()
    }

    var body: some View {
        content.offset(x: -viewport.scrollOffset)
    }
}

/// 播放跟随的**叶子**：只在这里读 `player.currentTime`（每 tick 变）。
/// 用**重定向线性动画**下发——内容由动画系统插值成连续滚动（不是每 100ms 跳一格），
/// 而 SwiftUI 每秒只做 10 次「改一个 offset」的极小更新。
/// 事实源仍是播放器时钟（每次都取真实时间重定目标），故不漂移、播放头时间标签也正确；
/// 擦洗时 player 是暂停的（rate 0），不会回跳。
private struct PlaybackFollow: View {
    let player: PlayerController
    let viewport: TimelineViewportState

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: player.currentTime) { _, t in
                guard player.isPlaying else { return }
                withAnimation(.linear(duration: Self.retargetDuration)) {
                    viewport.setPlayhead(t)
                }
            }
    }

    /// 重定目标间隔略长于轮询间隔（100ms），保证下一拍到来前动画已到目标、无停顿感。
    private static let retargetDuration: TimeInterval = 0.12
}
