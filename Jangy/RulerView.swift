import JangyCore
import SwiftUI

/// 时间线标尺：按 `viewport` 推导的间隔画刻度 + 时间标签。
/// 位置一律走 `contentX(forTime:)`（含半视口留白）——与内容车道同一坐标系，
/// 由外层整体 `.offset(x: -scrollOffset)` 驱动滚动；播放头恒在视口中央。
struct RulerView: View {
    let viewport: TimelineViewportState

    var body: some View {
        // 在 body 求值期读出依赖量：@Observable 的依赖追踪发生在 body，而非 Canvas 取值闭包，
        // 放这里才能保证 pps / playhead 变化时标尺重绘。
        let pps = viewport.pointsPerSecond
        let range = viewport.visibleTimeRange
        let interval = Self.tickInterval(pointsPerSecond: pps)

        return Canvas { context, size in
            guard pps > 0 else { return }
            // 内容从 t=0 起，负时间不画（否则左缘会出现一排 0:00）
            let start = max(0, (range.lowerBound / interval).rounded(.down) * interval)
            var t = start
            // 多画一个 interval 的余量，避免右缘刻度被切一半
            while t <= range.upperBound + interval {
                let x = viewport.contentX(forTime: t)

                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height))
                tick.addLine(to: CGPoint(x: x, y: size.height * 0.45))
                context.stroke(tick, with: .color(.secondary.opacity(0.6)), lineWidth: 1)

                context.draw(
                    Text(Self.label(t))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary),
                    at: CGPoint(x: x, y: size.height * 0.18),
                    anchor: .center
                )
                t += interval
            }
        }
    }

    /// 选一个让相邻刻度间隔 ≥ ~50pt 的档位（1/2/5/10/30/60/120 秒）。
    static func tickInterval(pointsPerSecond pps: CGFloat) -> TimeInterval {
        let candidates: [TimeInterval] = [1, 2, 5, 10, 30, 60, 120]
        for c in candidates where CGFloat(c) * pps >= 50 { return c }
        return candidates.last!
    }

    /// 刻度标签：`m:ss`。
    static func label(_ t: TimeInterval) -> String {
        let total = Int(max(0, t).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
