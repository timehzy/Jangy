import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO

/// 导出帧快照：给定时间点，以导出保真度渲染单帧为 PNG。
///
/// 用途（roadmap「字幕预览决策」的护栏）：UI 字幕层只承诺时间对位、不承诺像素一致，
/// 本入口提供「用户最终拿到的视频在这一时刻的真实画面」，供人工比对预览与导出的 drift，
/// 同时是剪辑 Agent 链路的视觉自检工具（headless 场景没有预览可截）。
///
/// 实现口径（路线 B，Kadr v1.2.0 `Video.renderedFrame`）：复用导出路径同款构建
/// （`CompositionBuilder` + overlay 层树挂 animationTool），经 `AVAssetImageGenerator`
/// 单帧渲染，跳过全片编码。与导出产物的等价性由 e2e 锚定用例
/// `testFrameSnapshotMatchesExportedTruth` 看守。
/// 已知限制：HDR 源抽帧会被色调映射为 SDR 位图——不影响字幕位置/内容比对，
/// 但本入口不是 HDR 保真工具。
public enum FrameSnapshotter {

    public enum Failure: Error, Equatable {
        /// 快照时刻超出渲染时长（口径：EditPlan.renderedDuration，与导出产物锚定）。
        case timeOutOfRange(at: TimeInterval, duration: TimeInterval)
        /// PNG 编码失败。
        case encodingFailed
    }

    /// 以导出保真度渲染指定时刻帧。返回 [时刻: PNG 数据]，落盘/展示由调用方决定。
    /// - Parameter times: 合成时间轴时刻（秒），须在 [0, plan.renderedDuration] 内。
    public static func snapshots(plan: EditPlan, resolver: AssetResolver,
                                 at times: [TimeInterval],
                                 options: ExportOptions = .default) async throws -> [TimeInterval: Data] {
        guard !times.isEmpty else { return [:] }
        let duration = plan.renderedDuration
        for t in times where !(0...duration).contains(t) {
            throw Failure.timeOutOfRange(at: t, duration: duration)
        }

        // options 只影响编码档（HDR/SDR），帧渲染的几何/内容两档一致，照常透传即可。
        let video = try await EngineBridge.makeComposition(from: plan, resolver: resolver, options: options)
        var result: [TimeInterval: Data] = [:]
        for t in times {
            result[t] = try pngData(try await video.renderedFrame(at: t))
        }
        return result
    }

    /// 零容差抽帧（从已有视频文件）：默认容差会取最近关键帧（近似帧），导致核对帧取错片段。
    public static func frame(from asset: AVAsset, at seconds: TimeInterval) throws -> CGImage {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        return try gen.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    }

    /// PNG 编码（ImageIO，macOS/iOS 通用；App 侧将来做比对调试入口时直接可用）。
    public static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw Failure.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        return data as Data
    }
}
