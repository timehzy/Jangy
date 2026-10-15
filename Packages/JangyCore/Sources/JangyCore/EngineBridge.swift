import AVFoundation
import Foundation
import CoreMedia
import Kadr
import KadrCaptions

/// EditPlan → Kadr DSL 的单向映射。预览与导出共用这一个出口。
/// 引擎适配层文件族（EngineBridge/PreviewBridge/ExportRunner）是 JangyCore 中唯一允许
/// import Kadr / KadrCaptions 的地方（硬边界规则 1）。
///
/// 注意：`Kadr.Video.duration` 是各 Clip.duration 的属性求和（转场全额计入），
/// ≠ 渲染输出时长（dissolve 与相邻片段重叠，输出更短）；输出长度口径统一走
/// `EditPlan.renderedDuration`（见 TimelineDuration.swift），预览/导出/UI 不得用求和值。
///
/// SRT cue 时间直接作为合成时间轴时间处理（约定：SRT 按渲染后的时间轴编写）。
///
/// 调用前须通过 EditPlanValidator.validate + validateAssets；
/// 否则非法 composition/缺失素材的错误延迟到 Kadr 导出期才抛出。
public enum EngineBridge {

    /// plan 引用的素材不在登记表中。正常路径已被 EditPlanValidator 拦截，
    /// 这里防御性抛出，避免静默丢片段。
    public struct MissingAssetError: Error, CustomStringConvertible {
        public let assetID: UUID
        public var description: String { "素材未登记: \(assetID)" }
    }

    /// 图片素材无法解码（损坏/非图片）。validator 只校验 source 与 kind 一致、不校验可解码性，
    /// 故损坏图片会在渲染期到此抛出（而非编辑期被拦）。
    public struct ImageDecodeError: Error, CustomStringConvertible {
        public let assetID: UUID
        public var description: String { "图片素材无法解码: \(assetID)" }
    }

    /// plan 的 primaryTrackID 指向的轨道不存在。
    public struct MissingPrimaryTrackError: Error, CustomStringConvertible {
        public var description: String { "plan 没有主轨（primaryTrackID 指向的轨道不存在）" }
    }

    /// 轨道类型与 payload 类型对不上（如视频轨里塞了字幕 cue）。
    public struct UnknownPayloadError: Error, CustomStringConvertible {
        public let kind: TrackKind
        public let payloadType: String
        public var description: String { "轨道类型 \(kind.rawValue) 不认识 payload 类型 '\(payloadType)'" }
    }

    /// - Parameter options: 导出配置（仅导出链路关心 SDR 降级；预览走默认 HDR 直通）。
    public static func makeComposition(from plan: EditPlan, resolver: AssetResolver,
                                       options: ExportOptions = .default) async throws -> Kadr.Video {
        // 显式映射而非静默丢弃：新增 OutputPreset case 时此处必须编译报错。
        let preset: Kadr.Preset
        switch plan.preset {
        case .reelsAndShorts:
            preset = options.hdrPassthrough
                ? .reelsAndShorts
                // SDR 降级：几何/帧率不变（同 1080x1920@30），编码换 H.264——
                // AVAssetExportPresetHighestQuality 会把 BT.2020+HLG 自动色调映射到
                // BT.709（POC 验证点③实测与 709 composition 路径产物逐像素一致）。
                // 不用 .tiktok（同为 1080x1920@30 H.264）是刻意解耦语义档位名。
                : .custom(width: 1080, height: 1920, frameRate: 30, codec: .h264)
        }

        guard let primary = plan.primaryTrack else { throw MissingPrimaryTrackError() }

        // 主轨：链式。gap 映射成纯黑 ImageClip，链保持连续（转场路径不受影响）。
        var elements: [any Kadr.Clip] = []
        for element in primary.elements {
            switch element.content {
            case .gap(let duration):
                elements.append(Kadr.ImageClip.color(PlatformColor.black, duration: duration))
            case .content(let payload):
                guard let clip = payload.value as? PlanClip else {
                    throw UnknownPayloadError(kind: primary.kind, payloadType: payload.payloadType)
                }
                guard let asset = plan.asset(withID: clip.assetID) else {
                    throw MissingAssetError(assetID: clip.assetID)
                }
                let sourceURL = resolver.resolve(asset)
                switch clip.source {
                case .video(let range):
                    var videoClip = Kadr.VideoClip(url: sourceURL).trimmed(to: range)
                    // Kadr 1.x 校准：`speed(_:)` 只接受 Speed 枚举（Double 重载在 v0.14 被移除）。
                    if clip.speed.rate != 1.0 {
                        videoClip = videoClip.speed(.flat(clip.speed.rate))
                    }
                    elements.append(videoClip)
                case .still(let duration):
                    // 图片无源区间：预合成到 preset 画幅（消除 Kadr 拉伸变形），
                    // 时长 = 基准 / 倍速（图片「变速」即改输出时长）。
                    guard let image = StillImagePreparer.prepare(url: sourceURL, canvas: preset.resolution) else {
                        throw ImageDecodeError(assetID: clip.assetID)
                    }
                    elements.append(Kadr.ImageClip(image, duration: duration / clip.speed.rate))
                }
                if let transition = clip.transitionAfter {
                    elements.append(kadrTransition(transition))
                }
            }
        }

        // 叠加视频轨 → Kadr.Track（每个元素一个，锚在 element.at）。Track 本身是 Clip，
        // 直接进 builder 数组（Kadr.Video 没有 track(_:) modifier）。
        // 声明顺序 = 绘制顺序，后面的盖前面的。
        for track in plan.tracks where track.id != primary.id && track.kind == .video {
            elements.append(contentsOf: try await VideoEngine.makeParallelTracks(track: track, plan: plan,
                                                                                resolver: resolver, preset: preset))
        }

        // Kadr 1.x 校准：VideoBuilder 的 buildExpression 只接受单个 Clip，
        // 单个数组表达式不编译——用 for 循环走 buildArray 路径。
        var video = Kadr.Video {
            for element in elements { element }
        }.preset(preset)

        // 字幕轨（可能多条，accumulate）
        for track in plan.tracks where track.kind == .caption {
            let cues = CaptionEngine.makeCues(track: track)
            guard !cues.isEmpty else { continue }
            video = video.captions(cues)                    // 软字幕：AVMetadataItem
            for cue in cues {
                video = video.overlay(captionOverlay(cue, style: CaptionFeature.settings(of: track)))  // 烧录：ImageOverlay（见 captionOverlay 注释）
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

    /// 字幕烧录 overlay：预渲染图片而非 Kadr.TextOverlay。
    /// 原因（实测隔离，详见 CaptionImageRenderer 注释）：macOS headless 导出中
    /// AVVideoCompositionCoreAnimationTool 不绘制 CATextLayer 文字，TextOverlay 全部隐形；
    /// ImageOverlay（CGImage contents）则稳定可见。
    /// 位置语义与原 TextOverlay 方案一致：底部居中、CMTimeRange 直达的可见窗口。
    /// 正式版：长 SRT（数百 cue）考虑合并同时点 cue 或分页渲染，避免 layer/图片数量爆炸。
    static func captionOverlay(_ cue: Kadr.Caption, style: CaptionTrackSettings) -> Kadr.ImageOverlay {
        let image = CaptionImageRenderer.render(cue.text, fontSize: style.fontSize, isBold: style.isBold)
        return Kadr.ImageOverlay(image)
            .position(.normalized(x: 0.5, y: 0.92))  // 底部居中，留 8% 安全边距
            .anchor(.bottom)
            .visible(during: cue.timeRange)          // CMTimeRange 直达：timescale 1000 原样保留
    }
}
