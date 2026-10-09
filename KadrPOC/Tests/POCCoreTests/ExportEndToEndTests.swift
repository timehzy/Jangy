import XCTest
import AVFoundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif
@testable import POCCore

/// 端到端导出回归：防 Kadr 静默 passthrough（空音频轨 → 兼容性检查 false →
/// passthrough 拷贝）与字幕隐形（CATextLayer 不渲染）两大坑。
/// 素材为纯色视频（clip1 红 / clip2 绿 / clip3 蓝），像素级断言因此可行。
final class ExportEndToEndTests: XCTestCase {

    private var resolver: AssetResolver!
    private var assetsDir: URL!

    override func setUp() async throws {
        assetsDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        resolver = try AssetSynthesizer.synthesize(into: assetsDir)
    }

    override func tearDown() async throws {
        if let assetsDir { try? FileManager.default.removeItem(at: assetsDir) }
        resolver = nil
        assetsDir = nil
    }

    func testSamplePlanExportProducesFullyRenderedOutput() async throws {
        let output = assetsDir.appendingPathComponent("export.mp4")
        var sawDone = false
        for try await event in ExportRunner.export(plan: SamplePlan.make(), resolver: resolver, to: output) {
            if case .done = event { sawDone = true }
        }
        XCTAssertTrue(sawDone, "导出流应以 done 结束")

        let asset = AVURLAsset(url: output)

        // 1. 单视频轨（passthrough 会拷出转场的双轨）
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1, "疑似 passthrough：输出应只有一条渲染后视频轨")

        // 2. preset 分辨率 1080x1920
        let track = videoTracks[0]
        let size = try await track.load(.naturalSize).applying(track.load(.preferredTransform))
        XCTAssertEqual(abs(size.width), 1080, accuracy: 2)
        XCTAssertEqual(abs(size.height), 1920, accuracy: 2)

        // 3. HEVC 编码（reelsAndShorts preset）
        let codec = try await track.load(.formatDescriptions).map { CMFormatDescriptionGetMediaSubType($0) }.first
        XCTAssertTrue([ExportVerifier.fourCC("hvc1"), ExportVerifier.fourCC("hev1")].contains(codec ?? 0),
                      "应为 HEVC，实际 \(codec.map(ExportVerifier.fourCCString) ?? "nil")")

        // 4. 渲染时长 = 9.5s（dissolve 重叠扣除；passthrough 或时长错误都会偏）
        let duration = try await CMTimeGetSeconds(asset.load(.duration))
        XCTAssertEqual(duration, 9.5, accuracy: 0.2)

        // 5. 像素级：t=1.0 在 clip1（纯红）+ 字幕"第一段：开场"（0–2.5s）窗口内
        //    → 底部字幕区应存在白色文字像素（无字幕烧录时纯色帧为 0）
        let whiteAt1 = try whitePixelCount(asset, at: 1.0, inBottomFraction: 0.25)
        XCTAssertGreaterThan(whiteAt1, 100, "t=1.0 应有烧录字幕的白色像素")

        // 6. 像素级：t=2.8 处于 dissolve 窗口（2.5–3.0s）内、字幕窗口外（cue1 结束于 2.5s）
        //    → 红↔绿混合帧，白色像素 ≈ 0（反证第 5 步不是底噪）
        let whiteAt28 = try whitePixelCount(asset, at: 2.8, inBottomFraction: 0.25)
        XCTAssertLessThan(whiteAt28, 100, "t=2.8 无字幕，应为纯色帧")

        // 7. 像素级：t=2.75 处于 dissolve 中点（红↔绿混合）
        //    → 中心像素应是红绿混合色（红通道与绿通道都显著），转场确实渲染了
        let center = try centerPixel(asset, at: 2.75)
        XCTAssertGreaterThan(center.r, 80, "dissolve 中点应保留红色分量")
        XCTAssertGreaterThan(center.g, 80, "dissolve 中点应混入绿色分量")

        // 8. 抽帧人工核对：三段字幕窗口各取一帧存到 KadrPOC/TestArtifacts/（gitignored），
        //    供人工确认字幕烧录的位置/字号/内容。复用本次导出产物，不再重复导出。
        //    t=1.0 → cue1（clip1 红底）、t=5.0 → cue2（clip2 绿底 0.5x 段）、
        //    t=8.8 → cue3（clip3 蓝底 2x 段；抽帧已设零容差，精确取帧不会落到 8.5s 接缝另一侧）
        let artifactsDir = Self.testArtifactsDir()
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
        for (seconds, name) in [(1.0, "sample_t1.0_cue1.png"), (5.0, "sample_t5.0_cue2.png"), (8.8, "sample_t8.8_cue3.png")] {
            try saveFramePNG(asset, at: seconds, to: artifactsDir.appendingPathComponent(name))
        }
    }

    /// 变速专项：clip2 0...3 @0.5x 单段 → 导出时长 ≈ 6.0s。
    /// 若变速未生效（按原速渲染）会量出 ~3s，直接红灯。
    func testSpeedChangeExportDuration() async throws {
        let plan = Self.makePlan(clips: [("clip2.mp4", 0...3, 0.5)])
        let output = try await exportToFile(plan, name: "speed.mp4")
        let duration = try await CMTimeGetSeconds(AVURLAsset(url: output).load(.duration))
        XCTAssertEqual(duration, 6.0, accuracy: 0.3, "0.5x 变速后 3s 素材应渲染为 6s")
    }

    /// 拼接专项：clip1 0...3 @1x + clip3 0...2 @1x，无转场 → 导出时长 ≈ 5.0s。
    /// 无转场重叠扣除，时长即两段之和；错误拼接/丢段都会偏。
    func testConcatNoTransitionExportDuration() async throws {
        let plan = Self.makePlan(clips: [("clip1.mp4", 0...3, 1.0), ("clip3.mp4", 0...2, 1.0)])
        let output = try await exportToFile(plan, name: "concat.mp4")
        let duration = try await CMTimeGetSeconds(AVURLAsset(url: output).load(.duration))
        XCTAssertEqual(duration, 5.0, accuracy: 0.3, "无转场拼接时长应为两段之和 5s")
    }

    /// 素材表 + 片段的便捷构造：每段素材在登记表里有对应条目（v2 引用模型）。
    private static func makePlan(clips: [(file: String, range: ClosedRange<TimeInterval>, speed: Double)]) -> EditPlan {
        var assets: [AssetItem] = []
        var planClips: [PlanClip] = []
        for spec in clips {
            let asset = AssetItem(kind: .video, fileName: spec.file, origin: .synthesized,
                                  duration: 4.0, pixelWidth: 1280, pixelHeight: 720, hasAudio: false)
            assets.append(asset)
            planClips.append(PlanClip(assetID: asset.id, range: spec.range, speed: .flat(spec.speed)))
        }
        return EditPlan(assets: assets, clips: planClips)
    }

    /// 跑一遍导出并断言以 done 结束，返回输出文件 URL。
    private func exportToFile(_ plan: EditPlan, name: String) async throws -> URL {
        let output = assetsDir.appendingPathComponent(name)
        var sawDone = false
        for try await event in ExportRunner.export(plan: plan, resolver: resolver, to: output) {
            if case .done = event { sawDone = true }
        }
        XCTAssertTrue(sawDone, "导出流应以 done 结束")
        return output
    }

    /// 抽取指定时刻帧，统计底部区域内近白色像素数。
    private func whitePixelCount(_ asset: AVAsset, at seconds: Double, inBottomFraction fraction: Double) throws -> Int {
        let (pixels, w, h) = try frameRGBA(asset, at: seconds)
        var count = 0
        for y in Int(Double(h) * (1 - fraction))..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                if pixels[o] > 220 && pixels[o + 1] > 220 && pixels[o + 2] > 220 { count += 1 }
            }
        }
        return count
    }

    private func centerPixel(_ asset: AVAsset, at seconds: Double) throws -> (r: Int, g: Int, b: Int) {
        let (pixels, w, h) = try frameRGBA(asset, at: seconds)
        let o = ((h / 2) * w + w / 2) * 4
        return (Int(pixels[o]), Int(pixels[o + 1]), Int(pixels[o + 2]))
    }

    /// AVAssetImageGenerator 抽帧并重绘到已知 RGBA8 布局，消除像素格式差异。
    private func frameRGBA(_ asset: AVAsset, at seconds: Double) throws -> ([UInt8], Int, Int) {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        // 零容差：默认容差会取最近关键帧（近似帧），导致核对帧取错片段
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let cg = try gen.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (pixels, w, h)
    }

    /// 抽帧并编码 PNG 落盘（人工核对产物）。测试宿主为 macOS，用 NSBitmapImageRep。
    private func saveFramePNG(_ asset: AVAsset, at seconds: Double, to url: URL) throws {
        #if canImport(AppKit)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        // 零容差：默认容差会取最近关键帧（近似帧），导致核对帧取错片段
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let cg = try gen.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("PNG 编码失败: \(url.lastPathComponent)")
            return
        }
        try png.write(to: url)
        #else
        throw XCTSkip("抽帧落盘仅在 macOS 测试宿主支持")
        #endif
    }

    /// KadrPOC/TestArtifacts/（已 gitignore）。由本文件路径定位包根，与测试工作目录解耦。
    private static func testArtifactsDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // POCCoreTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // KadrPOC/
            .appendingPathComponent("TestArtifacts")
    }
}
