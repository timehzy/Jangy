import Foundation
import CoreMedia
import Kadr
import KadrCaptions

/// EditPlan → Kadr DSL 的单向映射。预览与导出共用这一个出口。
/// 本文件是 POCCore 中唯一 import Kadr / KadrCaptions 的地方（硬边界规则 1）。
///
/// 注意：`Kadr.Video.duration` 是各 Clip.duration 的属性求和（转场全额计入），
/// ≠ 渲染输出时长（dissolve 与相邻片段重叠，输出更短）；预览/导出不得用它当输出长度。
///
/// SRT cue 时间直接作为合成时间轴时间处理（约定：SRT 按渲染后的时间轴编写）。
///
/// 调用前须通过 EditPlanValidator.validate + validateAssets；
/// 否则非法 composition/缺失素材的错误延迟到 Kadr 导出期才抛出。
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

        // 显式映射而非静默丢弃：新增 OutputPreset case 时此处必须编译报错。
        let preset: Kadr.Preset
        switch plan.preset {
        case .reelsAndShorts: preset = .reelsAndShorts
        }

        // Kadr 1.x 校准：VideoBuilder 的 buildExpression 只接受单个 Clip，
        // 单个数组表达式不编译——用 for 循环走 buildArray 路径。
        var video = Kadr.Video {
            for element in elements { element }
        }.preset(preset)

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

    /// 正式版：长 SRT（数百 cue）考虑合并同时点 cue 或分页渲染，避免 CALayer 爆炸。
    static func captionOverlay(_ cue: Kadr.Caption, style: CaptionStyle) -> Kadr.TextOverlay {
        // CMTimeRange 直达：SRT 解析为 timescale 1000，直接传递避免
        // Double 秒往返被重定量化到 timescale 600 产生漂移。
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
        .visible(during: cue.timeRange)
    }
}
