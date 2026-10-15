import Foundation
@testable import JangyCore

/// 老测试的最常见形状是「一组 clip 的扁平 plan」，这里收敛它的构造与读取。
enum PlanTestSupport {

    static func plan(assets: [AssetItem] = [], clips: [PlanClip],
                     captionSettings: CaptionTrackSettings? = nil,
                     cues: [PlanElement] = []) -> EditPlan {
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: clips.map { PlanElement(content: .content(TrackPayload($0))) })
        var tracks = [primary]
        if let captionSettings {
            tracks.append(PlanTrack(kind: .caption, placement: .absolute,
                                    settings: TrackPayload(captionSettings), elements: cues))
        }
        return EditPlan(assets: assets, tracks: tracks, primaryTrackID: primary.id)
    }

    /// 主轨第 i 个元素解出的 clip。
    static func clip(_ plan: EditPlan, _ i: Int) -> PlanClip? {
        plan.primaryTrack?.elements[i].content.clipPayload
    }
}

extension ElementContent {
    /// 内容是视频 clip 时解出来，否则 nil（gap / 别的 payload）。
    var clipPayload: PlanClip? {
        guard case .content(let payload) = self else { return nil }
        return payload.value as? PlanClip
    }
}
