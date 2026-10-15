import Foundation

/// L1 产出的**原子编辑意图**。L0 抬手时把它交给 `apply(to:)`——
/// 这是 L1 的职责：把一次用户操作翻译成对 EditPlan 的原子修改（公约 §2.3）。
/// 校验 / 不变式 / 归一化一律由 `EditStore.apply` 兜（L1 不写合法性校验，公约 §1）。
public enum TimelineEdit: Equatable, Sendable {
    /// trim：结果直接是新的 source（video 区间 / still 时长）。
    case trimSource(elementID: UUID, source: PlanClipSource)
    /// 移动：换到 toTrackID（nil = 不换轨）；绝对轨用 at 定位，链式轨用 toIndex 定位。
    case moveElement(elementID: UUID, toTrackID: UUID?, at: TimeInterval?, toIndex: Int?)
    /// 轨道重排：把 trackID 移到 toIndex。
    case reorderTrack(trackID: UUID, toIndex: Int)

    @discardableResult
    public func apply(to store: EditStore) -> Result<EditPlan, ValidationFailure> {
        store.apply { plan in
            switch self {
            case .trimSource(let elementID, let source):
                guard let location = Self.locate(elementID, in: plan),
                      case .content(let payload) = plan.tracks[location.track].elements[location.element].content,
                      var clip = payload.value as? PlanClip else { return }
                clip.source = source
                plan.tracks[location.track].elements[location.element].content = .content(TrackPayload(clip))

            case .moveElement(let elementID, let toTrackID, let at, let toIndex):
                guard let location = Self.locate(elementID, in: plan) else { return }
                var element = plan.tracks[location.track].elements.remove(at: location.element)
                let destination = toTrackID.flatMap { id in
                    plan.tracks.firstIndex { $0.id == id }
                } ?? location.track
                if let at { element.at = at }
                // 换到链式轨时清掉 at（链式轨位置由顺序推出，留着就是第二个事实源）
                else if plan.tracks[destination].placement == .chained { element.at = nil }
                if let toIndex {
                    let clamped = min(max(0, toIndex), plan.tracks[destination].elements.count)
                    plan.tracks[destination].elements.insert(element, at: clamped)
                } else {
                    plan.tracks[destination].elements.append(element)
                }

            case .reorderTrack(let trackID, let toIndex):
                guard let from = plan.tracks.firstIndex(where: { $0.id == trackID }) else { return }
                let clamped = min(max(0, toIndex), plan.tracks.count - 1)
                let moved = plan.tracks.remove(at: from)
                plan.tracks.insert(moved, at: clamped)
            }
        }
    }

    private static func locate(_ elementID: UUID, in plan: EditPlan) -> (track: Int, element: Int)? {
        for (ti, track) in plan.tracks.enumerated() {
            if let ei = track.elements.firstIndex(where: { $0.id == elementID }) { return (ti, ei) }
        }
        return nil
    }
}
