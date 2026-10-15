import Foundation

/// 轨级原子操作：**唯一**维持两条主轨不变式的地方。
/// 不变式由操作维持、校验器只做兜底（公约 §2.1 的形状）。
///
/// 1. 主轨从 0 起连续覆盖 [0, renderedDuration]，无隐式空洞
/// 2. 任何轨的元素不得超出主轨末端
public enum TrackOperations {

    /// 移除元素。
    /// - 链式轨的中间元素 → 原地换成等长 gap（内容消失、时长保留）
    /// - 链式轨的末尾元素 → 真正移除；若其他轨更靠后，随后由 maintainInvariants 补尾部 gap
    /// - 绝对轨元素 → 直接移除（主轨长度不受影响）
    ///
    /// 不在本函数内维持不变式——`EditStore.apply` 是唯一写入口，外层统一维持。
    public static func removeElement(_ elementID: UUID, in plan: inout EditPlan) {
        for (ti, track) in plan.tracks.enumerated() {
            guard let ei = track.elements.firstIndex(where: { $0.id == elementID }) else { continue }
            let element = track.elements[ei]
            if track.placement == .chained, ei < track.elements.count - 1 {
                plan.tracks[ti].elements[ei] = PlanElement(id: element.id,
                                                           content: .gap(duration: element.duration))
            } else {
                plan.tracks[ti].elements.remove(at: ei)
            }
            return
        }
    }

    /// 把元素放到绝对时间 `at`（仅绝对定位轨有意义）。
    /// 同 `removeElement`：不变式维持交给 `EditStore.apply`。
    public static func moveElement(_ elementID: UUID, to at: TimeInterval, in plan: inout EditPlan) {
        for (ti, track) in plan.tracks.enumerated() {
            guard let ei = track.elements.firstIndex(where: { $0.id == elementID }) else { continue }
            plan.tracks[ti].elements[ei].at = at
            return
        }
    }

    /// 逐轨调特性模块的归一化。与 `maintainInvariants` 一样，只由 `EditStore.apply` 调用。
    public static func normalizePayloads(in plan: inout EditPlan) {
        let context = TrackValidationContext(assets: plan.assets,
                                             mainTrackEnd: plan.renderedDuration,
                                             tracks: plan.tracks)
        for i in plan.tracks.indices {
            guard let feature = TrackFeatureRegistry.feature(for: plan.tracks[i].kind) else { continue }
            feature.normalize(track: &plan.tracks[i], context: context)
        }
    }

    /// 维持两条不变式。任何改动主轨长度或绝对轨元素位置的编辑之后都要调一次。
    /// 幂等：满足条件时不追加任何元素。
    public static func maintainInvariants(in plan: inout EditPlan) {
        guard let pi = plan.tracks.firstIndex(where: { $0.id == plan.primaryTrackID }) else { return }

        // 主轨的「末端」是成片时长 renderedDuration（已扣转场重叠），不是它的 span。
        // 用 span 会少补：样例工程 span 10 vs renderedDuration 9.5，差额 0.5 会漏掉。
        let mainEnd = plan.renderedDuration
        var required = mainEnd
        for track in plan.tracks where track.id != plan.primaryTrackID {
            required = max(required, track.span)
        }

        let deficit = required - mainEnd
        if deficit > EditPlanValidator.durationTolerance {
            plan.tracks[pi].elements.append(PlanElement(content: .gap(duration: deficit)))
        }
    }
}
