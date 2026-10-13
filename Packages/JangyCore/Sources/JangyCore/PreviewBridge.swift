import AVFoundation
import Kadr

/// UI 中立的字幕 cue（表现层不 import Kadr，故不能暴露 Kadr.Caption）。
public struct CaptionCue: Equatable, Sendable {
    public let text: String
    public let range: ClosedRange<TimeInterval>

    public init(text: String, range: ClosedRange<TimeInterval>) {
        self.text = text
        self.range = range
    }
}

/// 预览包：AVPlayerItem + 字幕 cue 列表。
/// 注意：Kadr 的 overlay（烧录字幕）不进入预览（AVFoundation 限制，export-only），
/// 表现层需用 SwiftUI 原生叠加层按播放器时间显示 cues。
public struct PreviewPackage {
    public let playerItem: AVPlayerItem
    public let cues: [CaptionCue]
}

public enum PreviewBridge {

    @MainActor
    public static func makePreview(for plan: EditPlan, resolver: AssetResolver) async throws -> PreviewPackage {
        let video = try await EngineBridge.makeComposition(from: plan, resolver: resolver)
        let item = try await video.makePlayerItem()
        breakRenderSizeEquality(in: item)
        let cues = video.captions.map {
            CaptionCue(text: $0.text,
                       range: $0.timeRange.start.seconds...($0.timeRange.start.seconds + $0.timeRange.duration.seconds))
        }
        return PreviewPackage(playerItem: item, cues: cues)
    }

    /// iOS 显示管线怪癖规避（实测：iOS 26 模拟器，错误 -11800 / 底层 -19230
    /// "CoreAnimation image queue does not support this pixel format"）：
    /// 转场路径（双视频轨 composition）中，素材分辨率恰好等于 renderSize 时，
    /// 显示管线把解码 buffer 直通 CA image queue，其像素格式被拒 →
    /// AVPlayerItemFailedToPlayToEndTime，播到转场即停（实测：identity transform
    /// 微扰无效——直通判定基于尺寸相等而非 transform；1078x1920 即可正常播放）。
    /// 规避：renderSize 宽度加 0.5pt 打破「恰好相等」，强制走合成渲染路径。
    /// 仅影响预览 item（导出走独立路径）；视觉差异不可感知。
    static func breakRenderSizeEquality(in item: AVPlayerItem) {
        guard let source = item.videoComposition else { return }
        let renderSize = source.renderSize
        let hasExactMatch = item.asset.tracks(withMediaType: .video).contains {
            Int($0.naturalSize.width) == Int(renderSize.width)
                && Int($0.naturalSize.height) == Int(renderSize.height)
        }
        guard hasExactMatch else { return }
        guard let vc = source.mutableCopy() as? AVMutableVideoComposition else { return }
        vc.renderSize = CGSize(width: renderSize.width + 0.5, height: renderSize.height)
        item.videoComposition = vc
    }
}
