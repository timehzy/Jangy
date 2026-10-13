import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO

/// 导出帧快照：给定时间点，走完整导出管线渲染真值并抽帧为 PNG。
///
/// 用途（roadmap「字幕预览决策」的护栏）：UI 字幕层只承诺时间对位、不承诺像素一致，
/// 本入口提供「用户最终拿到的视频在这一时刻的真实画面」，供人工比对预览与导出的 drift，
/// 同时是剪辑 Agent 链路的视觉自检工具（headless 场景没有预览可截）。
///
/// 实现口径（路线 A）：完整导出临时 mp4 → 零容差抽帧 → PNG，帧逐像素等于导出产物。
/// 多时刻共享一次导出（导出是主要成本，抽帧近乎免费）。
/// 已知限制：macOS 宿主对 HDR 源抽帧会色调映射为 SDR 位图——不影响字幕位置/内容比对，
/// 但本入口不是 HDR 保真工具。若将来需要单帧直渲（免全片导出），需在 Kadr fork 暴露
/// 导出路径的 composition + animationTool（路线 B，见 roadmap backlog）。
public enum FrameSnapshotter {

    public enum Failure: Error, Equatable {
        /// 快照时刻超出渲染时长（口径：EditPlan.renderedDuration，与导出产物锚定）。
        case timeOutOfRange(at: TimeInterval, duration: TimeInterval)
        /// PNG 编码失败。
        case encodingFailed
    }

    /// 走完整导出管线（含 ExportVerifier 硬校验，passthrough 垃圾不会变成"快照"），
    /// 抽取指定时刻帧。返回 [时刻: PNG 数据]，落盘/展示由调用方决定。
    /// - Parameter times: 合成时间轴时刻（秒），须在 [0, plan.renderedDuration] 内。
    public static func snapshots(plan: EditPlan, resolver: AssetResolver,
                                 at times: [TimeInterval],
                                 options: ExportOptions = .default) async throws -> [TimeInterval: Data] {
        guard !times.isEmpty else { return [:] }
        let duration = plan.renderedDuration
        for t in times where !(0...duration).contains(t) {
            throw Failure.timeOutOfRange(at: t, duration: duration)
        }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jangy-snapshot-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temp) }

        for try await event in ExportRunner.export(plan: plan, resolver: resolver, to: temp, options: options) {
            if case .done = event { break }
        }

        let asset = AVURLAsset(url: temp)
        var result: [TimeInterval: Data] = [:]
        for t in times {
            result[t] = try pngData(frame(from: asset, at: t))
        }
        return result
    }

    /// 零容差抽帧：默认容差会取最近关键帧（近似帧），导致核对帧取错片段。
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
