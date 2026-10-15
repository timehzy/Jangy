import Foundation

/// 吸附：把候选时间吸到阈值内最近的吸附点。纯函数、无状态。
public enum SnapEngine {

    /// 收集吸附点：0、成片时长、以及所有轨的元素边界（起点 / 终点）。
    /// 链式轨的起点按前缀和（扣转场重叠）算，与输出时间轴一致。
    public static func snapPoints(in plan: EditPlan) -> [TimeInterval] {
        var points: Set<TimeInterval> = [0, plan.renderedDuration]
        for track in plan.tracks {
            var cursor: TimeInterval = 0
            for element in track.elements {
                let start = element.at ?? cursor
                let end = start + element.duration
                points.insert(start)
                points.insert(end)
                cursor = end - element.trailingOverlap
            }
        }
        return points.sorted()
    }

    /// 把 candidate 吸到 tolerance 内最近的点；无命中则原样返回。
    public static func snap(_ candidate: TimeInterval, to points: [TimeInterval],
                            within tolerance: TimeInterval) -> TimeInterval {
        var best: TimeInterval?
        var bestDistance = tolerance
        for point in points {
            let distance = abs(point - candidate)
            if distance <= bestDistance {
                bestDistance = distance
                best = point
            }
        }
        return best ?? candidate
    }
}
