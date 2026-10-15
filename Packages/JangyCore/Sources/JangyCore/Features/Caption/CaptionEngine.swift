import CoreMedia
import Foundation
import Kadr

/// 字幕轨特性（L3 片）：字幕轨 → Kadr.Caption 数组。
/// 不再从文件读——cue 的文本与时间都在 plan 里（位置以 PlanElement.at 为权威）。
public enum CaptionEngine {

    static func makeCues(track: PlanTrack) -> [Kadr.Caption] {
        guard CaptionFeature.settings(of: track).isEnabled else { return [] }
        return track.elements.compactMap { element in
            guard case .content(let payload) = element.content,
                  let cue = payload.value as? CaptionCuePayload,
                  let at = element.at else { return nil }
            let start = CMTime(seconds: at, preferredTimescale: 1000)
            let duration = CMTime(seconds: cue.duration, preferredTimescale: 1000)
            return Kadr.Caption(text: cue.text, timeRange: CMTimeRange(start: start, duration: duration))
        }
    }
}
