import CoreGraphics
import Foundation

/// 时间线横向滚动的惯性（L1 纯算术，可测）。
///
/// 总行程由调用方给（L0 取 `DragGesture` 的 `predictedEndTranslation − translation`，
/// 即「系统按当前速度预测还会滑多远」），随后按**指数衰减**推进：
/// 位移 `x(t) = D·(1 − e^(−t/τ))`，τ 越小停得越快。
///
/// 调用方按帧 `advance(by:)`，把返回的点数换算成时间落到播放头上——
/// 走的是与擦洗同一条路径，所以松手后预览跟着滚，而不是跳到终点。
public struct TimelineFling {
    /// 时间常数 τ（秒）：越小停得越快。0.4 ≈ UIScrollView 常规手感。
    public static let timeConstant: TimeInterval = 0.4
    /// 剩余行程小于此值（点）即视为停稳。
    public static let restThreshold: CGFloat = 0.5
    /// 行程小于此值（点）不值得起惯性——轻放一下不该继续滑。
    public static let minDistance: CGFloat = 8

    /// 总行程（点，带符号，与手指位移同号）。
    public let distance: CGFloat
    private var elapsed: TimeInterval = 0

    public init(distance: CGFloat) {
        self.distance = distance
    }

    /// 是否值得起惯性。
    public var isFling: Bool { abs(distance) >= Self.minDistance }

    /// 推进 dt 秒，返回**这一拍应平移的点数**（与 `distance` 同号，绝对值递减）。
    public mutating func advance(by dt: TimeInterval) -> CGFloat {
        let before = travelled(at: elapsed)
        elapsed += max(0, dt)
        return travelled(at: elapsed) - before
    }

    /// 剩余行程（点）。
    public var remaining: CGFloat { distance - travelled(at: elapsed) }

    /// 是否已停稳。
    public var isAtRest: Bool { abs(remaining) <= Self.restThreshold }

    private func travelled(at t: TimeInterval) -> CGFloat {
        distance * (1 - exp(-t / Self.timeConstant))
    }
}
