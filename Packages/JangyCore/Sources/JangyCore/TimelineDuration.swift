import Foundation

/// 渲染时长口径（实测口径）：与 Kadr CompositionBuilder 的 cursor 推进规则一一对应——
/// dissolve 与下一片段全额重叠（总时长扣 duration）；fade 不重叠
/// （出/入侧各占相邻片段内 duration/2，总时长不变）。
/// 依据：kadr CompositionBuilder.swift 的 `overlap(during:)`（dissolve→d，fade→0）。
///
/// 注意：`Kadr.Video.duration` 是各 Clip.duration 的属性求和（转场全额计入），
/// ≠ 渲染输出时长；预览/导出/UI 时长展示一律用这里的口径，不要重新发明求和。
extension PlanClip {
    /// 片段在输出时间线上的时长 = 源区间长度 / 倍速。
    /// 视频：源区间长 / 倍速；图片：基准时长 / 倍速（图片「变速」即改输出时长）。
    /// TrackElementPayload.duration 转发到这里——两者是同一个值，不是两处口径。
    public var outputDuration: TimeInterval { duration }
}

extension PlanTransition {
    /// 转场对输出总时长的扣减量（重叠量）：dissolve 全额重叠，fade 不重叠。
    public var overlapDuration: TimeInterval {
        switch self {
        case .dissolve(let d): return d
        case .fade: return 0
        }
    }
}

extension EditPlan {
    /// 渲染输出总时长（实测口径）= 主轨链长 = Σ 元素输出时长 − Σ 转场重叠量。
    /// 样例工程实测锚点：3s@1x + 3s@0.5x + 2s@2x 挂 0.5s dissolve → 9.5s
    /// （≠ Kadr.Video.duration 求和值 10.5s）。e2e 断言基于此属性。
    ///
    /// 多轨不变式：主轨从 0 起连续覆盖 [0, renderedDuration]，其他轨元素不得超出主轨末端
    /// （由 TrackOperations 维持、EditPlanValidator 兜底）。故成片时长恒等于主轨链长。
    public var renderedDuration: TimeInterval {
        guard let track = primaryTrack else { return 0 }
        return track.elements.reduce(0) { total, element in
            total + element.duration - element.trailingOverlap
        }
    }
}
