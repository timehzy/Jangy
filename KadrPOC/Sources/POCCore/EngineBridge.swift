import Foundation
import CoreMedia
import Kadr
import KadrCaptions

/// EditPlan → Kadr DSL 的单向映射。预览与导出共用这一个出口。
/// 本文件是 POCCore 中唯一 import Kadr / KadrCaptions 的地方（硬边界规则 1）。
public enum EngineBridge {

    public static func makeComposition(from plan: EditPlan, resolver: AssetResolver) async throws -> Kadr.Video {
        var elements: [any Kadr.Clip] = []
        for clip in plan.clips {
            var videoClip = Kadr.VideoClip(url: resolver.resolve(clip.source))
                .trimmed(to: clip.range)
            // Kadr 1.x 校准：`speed(_:)` 只接受 Speed 枚举（Double 重载在 v0.14 被移除）。
            if clip.speed.rate != 1.0 {
                videoClip = videoClip.speed(.flat(clip.speed.rate))
            }
            elements.append(videoClip)
            if let transition = clip.transitionAfter {
                elements.append(kadrTransition(transition))
            }
        }

        // Kadr 1.x 校准：VideoBuilder 的 buildExpression 只接受单个 Clip，
        // 单个数组表达式不编译——用 for 循环走 buildArray 路径。
        var video = Kadr.Video {
            for element in elements { element }
        }.preset(.reelsAndShorts)

        if let track = plan.captions, track.isEnabled {
            let cues = try await Kadr.Caption.load(srt: resolver.resolve(track.source))
            video = video.captions(cues)                    // 软字幕：AVMetadataItem
            for cue in cues {
                video = video.overlay(captionOverlay(cue, style: track.style))  // 烧录：TextOverlay
            }
        }
        return video
    }

    static func kadrTransition(_ transition: PlanTransition) -> Kadr.Transition {
        switch transition {
        case .dissolve(let d): return .dissolve(duration: d)
        case .fade(let d): return .fade(duration: d)
        }
    }

    static func captionOverlay(_ cue: Kadr.Caption, style: CaptionStyle) -> Kadr.TextOverlay {
        let start = cue.timeRange.start.seconds
        let end = start + cue.timeRange.duration.seconds
        return Kadr.TextOverlay(
            cue.text,
            style: Kadr.TextStyle(
                fontSize: style.fontSize,
                alignment: .center,
                weight: style.isBold ? .bold : .regular
            )
        )
        .position(.bottom)
        .anchor(.bottom)
        .visible(during: start...end)
    }
}
