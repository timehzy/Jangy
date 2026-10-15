import Foundation

/// 吸附：把候选时间吸到阈值内最近的吸附点。纯函数、无状态。
public enum SnapEngine {

    /// 收集吸附点：0、成片时长、以及所有轨的元素边界（起点 / 终点）。
    /// 链式轨的起点按前缀和（扣转场重叠）算，与输出时间轴一致——直接复用
    /// `PlanTrack.elementOutputStarts()`，不另起一份前缀和走法。
    public static func snapPoints(in plan: EditPlan) -> [TimeInterval] {
        var points: Set<TimeInterval> = [0, plan.renderedDuration]
        for track in plan.tracks {
            let starts = track.elementOutputStarts()
            for (i, element) in track.elements.enumerated() {
                points.insert(starts[i])
                points.insert(starts[i] + element.duration)
            }
        }
        return points.sorted()
    }

    /// 把 candidate 吸到 tolerance 内最近的点；无命中则原样返回。
    /// 平局（两点等距）时**后遍历到**的点胜出；`snapPoints` 的输出是升序，
    /// 故等价于「取较大时间」。调用方若传入未排序的点，平局结果会不同。
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
