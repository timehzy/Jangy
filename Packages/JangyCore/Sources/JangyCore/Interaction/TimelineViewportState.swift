import CoreGraphics
import Foundation
import Observation

/// 时间线视口状态：三个高频量（播放头时间 / 缩放 px-per-sec / 滚动偏移）的唯一归宿。
/// **不进 EditStore**（公约 §2.2）——它每帧都变，进 plan 会让整棵 SwiftUI 树重算并污染撤销栈。
///
/// 单一事实源：`playheadTime` + `pointsPerSecond` 是状态，`scrollOffset` 由二者推出。
/// 播放头恒在视口水平中央（内容带半个视口宽的左右留白，故 t=0 / 片尾也能居中）。
/// 于是「滚动」与「擦洗」是同一件事：内容相对播放头平移 = 播放头下的时间改变。
///
/// 推导：内容坐标里，时间 t 的 x = 留白 + t·pps = W/2 + t·pps。
/// 让「t = playheadTime」落在视口中央（视口坐标 x = W/2）所需的内容偏移 =
/// (W/2 + playheadTime·pps) − W/2 = playheadTime·pps。
@MainActor
@Observable
public final class TimelineViewportState {
    /// 播放头时间（秒）= 视口中央那一点对应的时间。范围 [0, contentDuration]。
    public private(set) var playheadTime: TimeInterval = 0
    /// 缩放：每秒占多少点。夹在 [minPointsPerSecond, maxPointsPerSecond]。
    public private(set) var pointsPerSecond: CGFloat = 60
    /// 内容总时长（= `plan.renderedDuration`）。plan 变化后由 App 同步进来。
    /// 收缩（删除片段）时重夹播放头，保住 `playheadTime ∈ [0, contentDuration]` 不变式。
    public var contentDuration: TimeInterval = 0 {
        didSet { playheadTime = min(playheadTime, max(0, contentDuration)) }
    }
    /// 视口宽度（点）。由 L0 的 GeometryReader 回填，缩放锚点换算要用。
    public var viewportWidth: CGFloat = 0

    public static let minPointsPerSecond: CGFloat = 8
    public static let maxPointsPerSecond: CGFloat = 480

    /// 初始缩放可指定（夹在档位边界内）；运行时缩放一律走 `zoom(by:anchorX:)`。
    public init(pointsPerSecond: CGFloat = 60) {
        self.pointsPerSecond = min(max(Self.minPointsPerSecond, pointsPerSecond),
                                   Self.maxPointsPerSecond)
    }

    /// 内容相对视口左缘的偏移（点）。= 播放头时间 × px/s（见类注释推导）。
    public var scrollOffset: CGFloat { CGFloat(playheadTime) * pointsPerSecond }

    /// 视口坐标（相对视口左缘）某点对应的时间。
    public func time(atViewportX x: CGFloat) -> TimeInterval {
        playheadTime + TimeInterval((x - viewportWidth / 2) / pointsPerSecond)
    }

    /// 内容坐标：时间 t 相对内容左缘的 x（含半视口留白）。
    public func contentX(forTime t: TimeInterval) -> CGFloat {
        viewportWidth / 2 + CGFloat(t) * pointsPerSecond
    }

    /// 时间 t 在**视口坐标**（相对视口左缘）的 x。是 `time(atViewportX:)` 的逆。
    public func viewportX(forTime t: TimeInterval) -> CGFloat {
        contentX(forTime: t) - scrollOffset
    }

    /// 单指横向拖拽 = 滚动 = 擦洗。dx 为位移（点，右正）。
    public func scrub(by dx: CGFloat) {
        setPlayhead(playheadTime - TimeInterval(dx / pointsPerSecond))
    }

    /// 直接落播放头（播放推进 / 点选定位）。夹在 [0, contentDuration]。
    public func setPlayhead(_ t: TimeInterval) {
        playheadTime = min(max(0, t), max(0, contentDuration))
    }

    /// 双指捏合：以视口内 anchorX 为锚点缩放 px/s（锚点下的时间保持不动）。
    public func zoom(by factor: CGFloat, anchorX: CGFloat) {
        let anchorTime = time(atViewportX: anchorX)
        let next = min(max(Self.minPointsPerSecond, pointsPerSecond * factor),
                       Self.maxPointsPerSecond)
        guard next != pointsPerSecond else { return }
        pointsPerSecond = next
        // 让 anchorTime 重新落在 anchorX 下：playheadTime = anchorTime − (anchorX − W/2)/pps
        setPlayhead(anchorTime - TimeInterval((anchorX - viewportWidth / 2) / pointsPerSecond))
    }

    /// 当前视口覆盖的时间区间（缩略图只渲可见区用）。
    public var visibleTimeRange: ClosedRange<TimeInterval> {
        let lo = time(atViewportX: 0), hi = time(atViewportX: viewportWidth)
        return min(lo, hi)...max(lo, hi)
    }
}
