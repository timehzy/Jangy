import CoreGraphics
import Foundation

/// 拖拽解析所需的上下文（纯数据，无 UI 依赖）。
public struct DragContext: Sendable {
    public let plan: EditPlan
    public let pointsPerSecond: CGFloat
    public let snapPoints: [TimeInterval]
    public let snapTolerance: TimeInterval
    /// 轨道行高（点），轨道重排按它换算位移 → 目标下标。
    public let trackRowHeight: CGFloat
    /// 元素最短时长（秒），trim 不许短于它。
    public let minElementDuration: TimeInterval

    public init(plan: EditPlan, pointsPerSecond: CGFloat, snapPoints: [TimeInterval],
                snapTolerance: TimeInterval, trackRowHeight: CGFloat,
                minElementDuration: TimeInterval) {
        self.plan = plan
        self.pointsPerSecond = pointsPerSecond
        self.snapPoints = snapPoints
        self.snapTolerance = snapTolerance
        self.trackRowHeight = trackRowHeight
        self.minElementDuration = minElementDuration
    }
}

/// 一次「按下 → 拖 → 抬手」的全过程状态。**值语义**——L0 用 @State 持有，
/// 每帧更新只改这个局部值，EditPlan 一个字节不动（公约 §6.5 高频分界）。
public struct DragSession: Equatable, Sendable {
    public enum Edge: Equatable, Sendable { case leading, trailing }

    public enum Kind: Equatable, Sendable {
        /// 拖元素左右边缘手柄 = trim。
        case trim(elementID: UUID, edge: Edge)
        /// 长按元素浮起后拖 = 移动（改位置 / 换轨）。
        case moveElement(elementID: UUID, fromTrackID: UUID)
        /// 长按轨道头上下拖 = 轨道重排。
        case reorderTrack(trackID: UUID)
    }

    public let kind: Kind
    /// 累计位移（点，右正 / 下正）。
    public var translation: CGSize = .zero

    public init(kind: Kind) { self.kind = kind }

    public func translated(to translation: CGSize) -> DragSession {
        var copy = self
        copy.translation = translation
        return copy
    }

    /// 由拖拽瞬态解析出抬手要落的原子编辑；nil = 净变化为零（不落栈）。
    public func resolve(in context: DragContext) -> TimelineEdit? {
        switch kind {
        case .trim(let elementID, let edge):
            return resolveTrim(elementID: elementID, edge: edge, context: context)
        case .moveElement(let elementID, let fromTrackID):
            return resolveMove(elementID: elementID, fromTrackID: fromTrackID, context: context)
        case .reorderTrack(let trackID):
            return resolveReorder(trackID: trackID, context: context)
        }
    }

    // MARK: trim

    private func resolveTrim(elementID: UUID, edge: Edge, context: DragContext) -> TimelineEdit? {
        guard let (_, clip) = findClip(elementID, in: context.plan) else { return nil }
        let deltaSeconds = TimeInterval(translation.width / context.pointsPerSecond)
        guard deltaSeconds != 0 else { return nil }

        switch clip.source {
        case .video(let range):
            let assetDuration = context.plan.asset(withID: clip.assetID)?.duration ?? range.upperBound
            var lower = range.lowerBound, upper = range.upperBound
            switch edge {
            case .leading:
                lower = SnapEngine.snap(range.lowerBound + deltaSeconds, to: context.snapPoints,
                                        within: context.snapTolerance)
                lower = min(max(0, lower), upper - context.minElementDuration)
            case .trailing:
                upper = SnapEngine.snap(range.upperBound + deltaSeconds, to: context.snapPoints,
                                        within: context.snapTolerance)
                upper = min(max(lower + context.minElementDuration, upper), assetDuration)
            }
            if lower == range.lowerBound, upper == range.upperBound { return nil }
            return .trimSource(elementID: elementID, source: .video(lower...upper))

        case .still(let duration):
            // still 只有时长，两端等效
            let delta = (edge == .leading ? -deltaSeconds : deltaSeconds)
            let newDuration = max(context.minElementDuration, duration + delta)
            if newDuration == duration { return nil }
            return .trimSource(elementID: elementID, source: .still(duration: newDuration))
        }
    }

    // MARK: move

    private func resolveMove(elementID: UUID, fromTrackID: UUID, context: DragContext) -> TimelineEdit? {
        let plan = context.plan
        guard let fromTrack = plan.tracks.first(where: { $0.id == fromTrackID }),
              let element = fromTrack.elements.first(where: { $0.id == elementID }) else { return nil }

        // 纵向换轨：按行高把位移换算成轨道下标偏移
        var targetTrackID = fromTrackID
        if context.trackRowHeight > 0, translation.height != 0,
           let fromIndex = plan.tracks.firstIndex(where: { $0.id == fromTrackID }) {
            let rowDelta = Int((translation.height / context.trackRowHeight).rounded())
            if rowDelta != 0 {
                let target = min(max(0, fromIndex + rowDelta), plan.tracks.count - 1)
                targetTrackID = plan.tracks[target].id
            }
        }

        // 目标轨是绝对定位：横向位移 → at（吸附）
        if let targetTrack = plan.tracks.first(where: { $0.id == targetTrackID }),
           targetTrack.placement == .absolute {
            let deltaSeconds = TimeInterval(translation.width / context.pointsPerSecond)
            let originalAt = element.at ?? 0
            let at = max(0, SnapEngine.snap(originalAt + deltaSeconds, to: context.snapPoints,
                                            within: context.snapTolerance))
            if targetTrackID == fromTrackID, at == originalAt { return nil }
            return .moveElement(elementID: elementID, toTrackID: targetTrackID, at: at, toIndex: nil)
        }

        // 换到链式轨 = 追加到末尾
        if targetTrackID != fromTrackID {
            return .moveElement(elementID: elementID, toTrackID: targetTrackID, at: nil, toIndex: nil)
        }
        return resolveReorderWithinChained(elementID: elementID, track: fromTrack, context: context)
    }

    /// 链式轨内横向拖动 = 重排：按拖动后元素中心与其余元素区间的相对位置算目标下标。
    private func resolveReorderWithinChained(elementID: UUID, track: PlanTrack,
                                              context: DragContext) -> TimelineEdit? {
        guard let currentIndex = track.elements.firstIndex(where: { $0.id == elementID }) else { return nil }
        let starts = track.elementOutputStarts()
        let element = track.elements[currentIndex]
        let deltaSeconds = TimeInterval(translation.width / context.pointsPerSecond)
        let draggedCenter = starts[currentIndex] + element.duration / 2 + deltaSeconds

        var targetIndex = track.elements.count
        for (i, start) in starts.enumerated() where i != currentIndex {
            if draggedCenter < start + track.elements[i].duration / 2 {
                targetIndex = i
                break
            }
        }
        var insertion = targetIndex
        if targetIndex > currentIndex { insertion -= 1 }
        if insertion == currentIndex { return nil }
        return .moveElement(elementID: elementID, toTrackID: track.id, at: nil, toIndex: insertion)
    }

    // MARK: reorder track

    private func resolveReorder(trackID: UUID, context: DragContext) -> TimelineEdit? {
        guard context.trackRowHeight > 0,
              let fromIndex = context.plan.tracks.firstIndex(where: { $0.id == trackID }) else { return nil }
        let rowDelta = Int((translation.height / context.trackRowHeight).rounded())
        let target = min(max(0, fromIndex + rowDelta), context.plan.tracks.count - 1)
        guard target != fromIndex else { return nil }
        return .reorderTrack(trackID: trackID, toIndex: target)
    }

    // MARK: helpers

    private func findClip(_ elementID: UUID, in plan: EditPlan) -> (PlanElement, PlanClip)? {
        for track in plan.tracks {
            for element in track.elements where element.id == elementID {
                guard case .content(let payload) = element.content,
                      let clip = payload.value as? PlanClip else { return nil }
                return (element, clip)
            }
        }
        return nil
    }
}
