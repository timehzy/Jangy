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
        didSet {
            let clamped = min(playheadTime, max(0, contentDuration))
            if clamped != playheadTime { playheadTime = clamped }
            refreshCullRange()
        }
    }
    /// 视口宽度（点）。由 L0 的 GeometryReader 回填，缩放锚点换算要用。
    public var viewportWidth: CGFloat = 0 {
        didSet { if viewportWidth != oldValue { refreshCullRange() } }
    }

    /// 车道 / 标尺用的**粗粒度**裁剪窗口：内容只建这个区间内的东西。
    ///
    /// 存在的理由：`playheadTime` 是每帧都变的高频量，而车道要按可见区裁掉离屏元素。
    /// 若车道直接读 `visibleTimeRange`（计算属性，转调 `playheadTime` 的 stored getter），
    /// 依赖追踪会把每个车道 body 都注册成 `playheadTime` 的依赖者 → 滚动一帧重建全部内容。
    /// 这里把它换成**存储且量化**的量：只有跨「一屏」栅格时才写，读它的视图也就只在跨屏时重建。
    ///
    /// 注意这只解决「建哪些内容」，**不解决「平移多少」**——连续平移必须留在只读
    /// `scrollOffset` 的叶子视图里，否则滚动会跳步。
    public private(set) var cullRange: ClosedRange<TimeInterval> = 0...0

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

    /// 直接落播放头（播放推进 / 点选定位）。夹在 [0, contentDuration]。
    /// 同值不写：`@Observable` 的 setter 不做相等判断，同值写也会通知依赖者。
    public func setPlayhead(_ t: TimeInterval) {
        let clamped = min(max(0, t), max(0, contentDuration))
        if clamped != playheadTime { playheadTime = clamped }
        refreshCullRange()
    }

    /// 重算裁剪窗口：可见区前后各外扩半屏，再**向外吸附到「一屏」栅格**。
    /// 外扩 + 向外吸附保证窗口恒包含可见区（直接取 `[bucket−0.5, bucket+1.5]` 不够——
    /// 可见区上界可落到 `(bucket+2) 屏`），且只在跨屏时才变。
    private func refreshCullRange() {
        let span = pointsPerSecond > 0 ? viewportWidth / pointsPerSecond : 0
        let next: ClosedRange<TimeInterval>
        if span <= 0 {
            // 视口宽度尚未回填（首帧）：退化为「全部内容」。用 0...0 会让车道在首帧全空。
            next = 0...max(0, contentDuration)
        } else {
            let visible = visibleTimeRange
            let lo = (visible.lowerBound - span / 2) / span
            let hi = (visible.upperBound + span / 2) / span
            next = (lo.rounded(.down) * span)...(hi.rounded(.up) * span)
        }
        if next != cullRange { cullRange = next }
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
