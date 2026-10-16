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

    @State private var lastTranslation: CGFloat = 0
    @State private var lastVertical: CGFloat = 0
    @State private var isScrubbing = false

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
        // 播放推进（非擦洗时）驱动播放头；擦洗期间由手势自行更新，避免相互打架。
        .onChange(of: model.player.currentTime) { _, t in
            if !isScrubbing { viewport.setPlayhead(t) }
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
    /// 逐帧比较横/纵位移，**横向为主才算擦洗**，纵向留给 ScrollView，两者互不抢。
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let dx = value.translation.width - lastTranslation
                let dy = value.translation.height - lastVertical
                lastTranslation = value.translation.width
                lastVertical = value.translation.height
                guard abs(dx) >= abs(dy) else { return }
                isScrubbing = true
                viewport.scrub(by: dx)
                model.scrubTo(viewport.playheadTime)
            }
            .onEnded { _ in
                lastTranslation = 0
                lastVertical = 0
                let wasScrubbing = isScrubbing
                isScrubbing = false
                if wasScrubbing { model.scrubEnded() }   // 补最终 seek，防松手回跳
            }
    }
}
