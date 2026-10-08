import AVFoundation
import Foundation
import CoreMedia
import Kadr
import KadrCaptions

/// EditPlan → Kadr DSL 的单向映射。预览与导出共用这一个出口。
/// 引擎适配层文件族（EngineBridge/PreviewBridge/ExportRunner）是 POCCore 中唯一允许
/// import Kadr / KadrCaptions 的地方（硬边界规则 1）。
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
        // 上游 Kadr bug 规避（trigger-avoidance，详见 ExportVerifier 注释）：
        // Kadr CompositionBuilder 无条件添加音频合成轨；素材无音频时该轨为空，
        // AVFoundation 兼容性检查对含空轨的 composition 一律返回 false，
        // ExportEngine 便静默回退 passthrough。给无音频素材挂一段静音替换音频，
        // 让音频轨始终有 segment，兼容性检查即可通过、走正常重编码路径。
        // 静音时长覆盖最长 clip 源区间即可（Kadr 按 min(音频时长, clip时长) 截取）。
        var silenceURL: URL?
        let maxClipSeconds = plan.clips.map { $0.range.upperBound - $0.range.lowerBound }.max() ?? 0

        var elements: [any Kadr.Clip] = []
        for clip in plan.clips {
            let sourceURL = resolver.resolve(clip.source)
            var videoClip = Kadr.VideoClip(url: sourceURL)
                .trimmed(to: clip.range)
            // Kadr 1.x 校准：`speed(_:)` 只接受 Speed 枚举（Double 重载在 v0.14 被移除）。
            if clip.speed.rate != 1.0 {
                videoClip = videoClip.speed(.flat(clip.speed.rate))
            }
            if await !assetHasAudio(sourceURL) {
                if silenceURL == nil {
                    silenceURL = try SilentAudio.url(covering: maxClipSeconds + 0.25)
                }
                videoClip = videoClip.withAudio(silenceURL!)
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
                video = video.overlay(captionOverlay(cue, style: track.style))  // 烧录：ImageOverlay（见 captionOverlay 注释）
            }
        }
        return video
    }

    /// 素材是否自带音频轨。探测失败（文件损坏/无法读取）按"有音频"处理：
    /// 不挂静音，让真错误在 Kadr 导出期响亮抛出，而不是给可能自带音频的素材静默盖上静音轨。
    static func assetHasAudio(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        return (try? await asset.loadTracks(withMediaType: .audio).isEmpty == false) ?? true
    }

    static func kadrTransition(_ transition: PlanTransition) -> Kadr.Transition {
        switch transition {
        case .dissolve(let d): return .dissolve(duration: d)
        case .fade(let d): return .fade(duration: d)
        }
    }

    /// 字幕烧录 overlay：预渲染图片而非 Kadr.TextOverlay。
    /// 原因（实测隔离，详见 CaptionImageRenderer 注释）：macOS headless 导出中
    /// AVVideoCompositionCoreAnimationTool 不绘制 CATextLayer 文字，TextOverlay 全部隐形；
    /// ImageOverlay（CGImage contents）则稳定可见。
    /// 位置语义与原 TextOverlay 方案一致：底部居中、CMTimeRange 直达的可见窗口。
    /// 正式版：长 SRT（数百 cue）考虑合并同时点 cue 或分页渲染，避免 layer/图片数量爆炸。
    static func captionOverlay(_ cue: Kadr.Caption, style: CaptionStyle) -> Kadr.ImageOverlay {
        let image = CaptionImageRenderer.render(cue.text, fontSize: style.fontSize, isBold: style.isBold)
        return Kadr.ImageOverlay(image)
            .position(.normalized(x: 0.5, y: 0.92))  // 底部居中，留 8% 安全边距
            .anchor(.bottom)
            .visible(during: cue.timeRange)          // CMTimeRange 直达：timescale 1000 原样保留
    }
}
