import JangyCore
import SwiftUI

/// 时间线：可拖分界下方的多轨视图（容器骨架）。水平位置由 `viewport.scrollOffset` 驱动
/// （非 ScrollView 横向滚动）——单指横向拖 = 滚动 = 擦洗（同一手势）；纵向拖交给车道 ScrollView。
/// 车道内容（缩略图 / 片段块 / 选择）留给 Task 8（TrackLaneView），本步用占位块。
struct TimelineView: View {
    let model: AppModel
    /// 由分界拖动决定的窗格高度。
    var height: CGFloat
    var onAdd: () -> Void

    /// 起手播放头（手势开始时捕获一次）。@GestureState 在手势结束**或取消**时自动复位，
    /// 因此不需要在 .onEnded 里手动清理——取消也不会残留脏基准。
    @GestureState private var scrubBase: TimeInterval?

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
            .overlay(alignment: .bottomTrailing) { addButton }
            .onAppear { viewport.viewportWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, w in viewport.viewportWidth = w }
        }
        .frame(height: height)
        // 只有播放推进才回写播放头；擦洗时 player 是暂停的（rate 0），不会回跳。
        .onChange(of: model.player.currentTime) { _, t in
            if model.player.isPlaying { viewport.setPlayhead(t) }
        }
    }

    /// 内容层：标尺 + 车道，整体按 `-scrollOffset` 平移，宽度 = 视口宽 + 内容宽。
    private func contentLayer(viewportWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            RulerView(viewport: viewport).frame(height: 24)
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    // Task 8 换成 TrackLaneView；本步每条轨一条占位带（按内容宽铺满，验证滚动/擦洗）。
                    ForEach(model.store.plan.tracks) { _ in
                        Color(.secondarySystemFill)
                            .frame(width: contentWidth, height: 56)
                    }
                }
                .padding(.leading, viewportWidth / 2)   // 半视口留白，让 t=0 落在视口中央
                .padding(.trailing, viewportWidth / 2)
            }
        }
        .frame(width: viewportWidth + contentWidth, alignment: .leading)
        .offset(x: -viewport.scrollOffset)
    }

    /// 内容带宽度（点）= 时长 × px/s。
    private var contentWidth: CGFloat {
        CGFloat(viewport.contentDuration) * viewport.pointsPerSecond
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
        .padding(8)
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
                guard let base = scrubBase else { return }
                guard abs(value.translation.width) >= abs(value.translation.height) else { return }
                let target = base - TimeInterval(value.translation.width / viewport.pointsPerSecond)
                viewport.setPlayhead(target)
                model.scrubTo(viewport.playheadTime)
            }
            .onEnded { _ in
                model.scrubEnded()   // 补最终 seek；player 仍暂停，不会回跳
            }
    }
}
