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
        let cues = video.captions.map {
            CaptionCue(text: $0.text,
                       range: $0.timeRange.start.seconds...($0.timeRange.start.seconds + $0.timeRange.duration.seconds))
        }
        return PreviewPackage(playerItem: item, cues: cues)
    }
}
