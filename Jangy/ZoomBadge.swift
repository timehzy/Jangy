import JangyCore
import SwiftUI

/// 缩放档位角标：时间线右下角，显示当前 px/s（如「60 px/s」）。
/// 可见性由**捏合手势的活跃态** `isZooming` 驱动——捏合期间全程可见，手势结束 1s 后淡出。
/// 不挂在 `pointsPerSecond` 的逐帧变化上（那会在长捏合中途闪没、且每帧起任务）；
/// 显示的数字仍读 `pointsPerSecond`（@Observable），随捏合实时刷新。
struct ZoomBadge: View {
    let viewport: TimelineViewportState
    /// 捏合手势是否进行中（由 `TimelineView` 读手势态给出）。
    let isZooming: Bool

    @State private var isVisible = false
    /// 捏合结束后「延时 1s 隐藏」的任务。
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Text("\(Int(viewport.pointsPerSecond.rounded())) px/s")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
            .opacity(isVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: isVisible)
            // 纯展示：不拦截触摸（否则会挡住下方的 ＋ 按钮与时间线手势）。
            .allowsHitTesting(false)
            .onChange(of: isZooming) { _, zooming in
                zooming ? show() : scheduleHide()
            }
            // 离屏时取消未决的隐藏任务（对齐 AssetPreviewView / EditorView 的收尾写法）。
            .onDisappear { hideTask?.cancel() }
    }

    /// 捏合开始：显示角标并取消未决的隐藏。
    private func show() {
        hideTask?.cancel()
        hideTask = nil
        isVisible = true
    }

    /// 捏合结束：1s 后隐藏（期间若重新捏合，`show()` 会取消它）。
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            isVisible = false
        }
    }
}
