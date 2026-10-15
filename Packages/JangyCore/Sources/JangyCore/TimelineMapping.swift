import Foundation

extension PlanClip {
    /// 元素内某「输出偏移」对应的**源素材时间**：源区间起点 + 输出偏移 × 倍速。
    /// 缩略图从源素材抽帧时用（输出时间轴 → 源时间轴）。
    /// 纯算术、可测；`.still` 无源区间，返回 nil（图片缩略图不走抽帧路径）。
    public func sourceTime(forOutputOffset offset: TimeInterval) -> TimeInterval? {
        guard case .video(let range) = source else { return nil }
        return range.lowerBound + offset * speed.rate
    }
}

extension PlanTrack {
    /// 每个元素在成片时间轴上的**输出起点**。
    /// - 链式轨：前缀和，逐段扣掉该段尾部转场的重叠量（与 `EditPlan.renderedDuration` 同口径）
    /// - 绝对轨：元素的 `at`
    /// 供缩略图把「可见输出区间」映射到各元素的输出偏移。
    public func elementOutputStarts() -> [TimeInterval] {
        switch placement {
        case .absolute:
            return elements.map { $0.at ?? 0 }
        case .chained:
            var starts: [TimeInterval] = []
            var cursor: TimeInterval = 0
            for element in elements {
                starts.append(cursor)
                cursor += element.duration
                if case .content(let payload) = element.content,
                   let clip = payload.value as? PlanClip,
                   let transition = clip.transitionAfter {
                    cursor -= transition.overlapDuration
                }
            }
            return starts
        }
    }
}
