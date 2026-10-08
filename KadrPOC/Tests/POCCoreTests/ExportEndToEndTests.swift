import XCTest
import AVFoundation
import CoreGraphics
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

        // 6. 像素级：t=2.8 在 clip1 内、字幕窗口外（cue1 结束于 2.5s）
        //    → 纯色帧，白色像素 ≈ 0（反证第 5 步不是底噪）
        let whiteAt28 = try whitePixelCount(asset, at: 2.8, inBottomFraction: 0.25)
        XCTAssertLessThan(whiteAt28, 100, "t=2.8 无字幕，应为纯色帧")

        // 7. 像素级：t=2.75 处于 dissolve 中点（红↔绿混合）
        //    → 中心像素应是红绿混合色（红通道与绿通道都显著），转场确实渲染了
        let center = try centerPixel(asset, at: 2.75)
        XCTAssertGreaterThan(center.r, 80, "dissolve 中点应保留红色分量")
        XCTAssertGreaterThan(center.g, 80, "dissolve 中点应混入绿色分量")
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
        let cg = try gen.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (pixels, w, h)
    }
}
