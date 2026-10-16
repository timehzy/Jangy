import CoreGraphics
import Foundation

/// 时间线胶片条的纯算术：帧格多宽、给定裁剪窗口要建哪些格。
/// 抽到 L1 是为了可单测——L0 的 `VideoLane` 只负责把结果摆出来。
///
/// 与剪映 / CapCut / iMovie 一致的做法：**格宽在屏幕上恒定**（= 车道高 × 素材宽高比，画面不裁切），
/// 缩放进出的只是「每格代表多少秒」——格变密/变疏，格宽不变。
public enum TimelineFilmstrip {
    /// 格宽下限（点）：竖屏素材按宽高比算出来很窄，夹住避免格子小到看不清。
    public static let minCellWidth: CGFloat = 32
    /// 格宽上限（点）：超宽画幅（21:9）也夹住，避免一屏放不下两格。
    public static let maxCellWidth: CGFloat = 120
    /// 素材宽高比探测失败（`pixelWidth/Height` 为 nil 或非正）时的兜底。
    public static let fallbackAspectRatio: CGFloat = 16.0 / 9.0

    /// 帧格宽度（点）= 车道高 × 素材宽高比，夹在 [minCellWidth, maxCellWidth]。
    public static func cellWidth(laneHeight: CGFloat, aspectRatio: CGFloat?) -> CGFloat {
        let aspect: CGFloat
        if let ratio = aspectRatio, ratio.isFinite, ratio > 0 {
            aspect = ratio
        } else {
            aspect = fallbackAspectRatio
        }
        return min(max(laneHeight * aspect, minCellWidth), maxCellWidth)
    }

    /// 一个帧格。`index` 是**全局格索引**（从元素起点数起，与裁剪窗口无关）——
    /// 窗口平移时同一物理位置的格索引不变，视图身份才稳定、才不会重取缩略图。
    public struct Cell: Equatable, Sendable {
        public let index: Int
        /// 抽帧用的元素内**输出偏移**（秒，格与元素区间的交集中点）。
        public let outputOffset: TimeInterval
        /// 相对元素起点的 x（点）。
        public let x: CGFloat
        public let width: CGFloat
    }

    /// 铺满 `window ∩ 元素区间` 所需的格。窗口之外一律不建（长素材 × 大缩放下格数会很大）。
    /// - Parameters:
    ///   - start: 元素在成片时间轴上的输出起点（秒）
    ///   - duration: 元素时长（秒）
    ///   - window: 裁剪窗口（成片时间轴，秒）
    public static func cells(start: TimeInterval, duration: TimeInterval,
                             pointsPerSecond: CGFloat, cellWidth: CGFloat,
                             window: ClosedRange<TimeInterval>) -> [Cell] {
        guard pointsPerSecond.isFinite, pointsPerSecond > 0,
              cellWidth.isFinite, cellWidth > 0,
              duration.isFinite, duration > 0,
              window.lowerBound.isFinite, window.upperBound.isFinite else { return [] }
        let cellDuration = TimeInterval(cellWidth / pointsPerSecond)
        guard cellDuration > 0 else { return [] }

        let lower = max(0, window.lowerBound - start)
        let upper = min(duration, window.upperBound - start)
        guard upper > lower else { return [] }

        // 格 i 覆盖 [i·cd, (i+1)·cd]；取与 [lower, upper] 相交的那一段。
        let first = max(0, Int((lower / cellDuration).rounded(.down)))
        let lastByWindow = Int((upper / cellDuration).rounded(.up)) - 1
        let lastByElement = Int((duration / cellDuration).rounded(.up)) - 1
        let last = min(lastByWindow, lastByElement)
        guard last >= first else { return [] }

        return (first...last).map { index in
            // 取「格 ∩ 元素区间」的中点：末格可能被元素尾部截断，用整格中点会越过元素末尾
            // （抽帧落到源区间之外）。
            let lo = Double(index) * cellDuration
            let hi = min(Double(index + 1) * cellDuration, duration)
            return Cell(index: index, outputOffset: (lo + hi) / 2,
                        x: CGFloat(index) * cellWidth, width: cellWidth)
        }
    }
}
