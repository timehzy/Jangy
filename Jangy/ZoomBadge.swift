import JangyCore
import SwiftUI

/// 缩放档位角标：时间线右下角，显示当前 px/s（如「60 px/s」）。
/// 只读 `TimelineViewportState.pointsPerSecond`（@Observable）——自身不持有缩放手势状态，
/// 「正在缩放」由该值变化驱动：每次变化续期，停手约 1s 后才淡出。
struct ZoomBadge: View {
    let viewport: TimelineViewportState

    @State private var isVisible = false
    /// 「停手后延时隐藏」的续期任务：每次缩放取消上一次、重排一个新的（停手满 1s 才隐藏）。
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
            .onChange(of: viewport.pointsPerSecond) { _, _ in flash() }
    }

    /// 显示角标并续期：取消上一次延时，重排「1s 后隐藏」。
    private func flash() {
        isVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            isVisible = false
        }
    }
}
