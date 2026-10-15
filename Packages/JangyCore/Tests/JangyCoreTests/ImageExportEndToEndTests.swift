import XCTest
import AVFoundation
import CoreGraphics
@testable import JangyCore
@testable import JangyTestSupport

/// 图片上轨的端到端导出回归：纯图片工程、视频+图片混排、letterbox 无变形、快照。
final class ImageExportEndToEndTests: XCTestCase {

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

    /// 合成图登记项（640×360 16:9，非 preset 画幅）
    private var imageAsset: AssetItem {
        AssetItem(kind: .image, fileName: AssetSynthesizer.imageFileName,
                  origin: .synthesized, pixelWidth: 640, pixelHeight: 360)
    }

    private func export(_ plan: EditPlan, to name: String) async throws -> URL {
        let out = assetsDir.appendingPathComponent(name)
        for try await _ in ExportRunner.export(plan: plan, resolver: resolver, to: out) {}
        return out
    }

    /// 抽帧（零容差）读单点像素。y 从图像顶部起算（CGBitmapContext 内存行 0 = 图像顶部）。
    private func pixel(_ url: URL, at seconds: TimeInterval, x: Int, y: Int) throws -> (UInt8, UInt8, UInt8) {
        let cg = try FrameSnapshotter.frame(from: AVURLAsset(url: url), at: seconds)
        let w = cg.width, h = cg.height
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
        defer { buf.deallocate() }
        let ctx = CGContext(data: buf, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let o = (y * w + x) * 4
        return (buf[o], buf[o + 1], buf[o + 2])
    }

    func testPureImageExportDurationAndContent() async throws {
        let image = imageAsset
        let plan = EditPlan(assets: [image],
                            clips: [PlanClip(assetID: image.id, source: .still(duration: 2.0))])
        let out = try await export(plan, to: "img-only.mp4")

        let duration = try await CMTimeGetSeconds(AVURLAsset(url: out).load(.duration))
        XCTAssertEqual(duration, 2.0, accuracy: 0.2, "渲染时长 = 图片时长")

        // 16:9 图在 9:16 画幅里贴满宽、上下留黑：中心为图片色（黄），顶部为黑边。
        // 断言用「中心明显亮于黑边」的相对式，规避 HDR→SDR 色调映射的绝对色偏。
        let center = try pixel(out, at: 1.0, x: 540, y: 960)
        let top = try pixel(out, at: 1.0, x: 540, y: 60)
        XCTAssertGreaterThan(Int(center.0), 120, "中心应为图片（偏黄）")
        XCTAssertGreaterThan(Int(center.1), 100)
        XCTAssertLessThan(Int(top.0), 60, "顶部应为黑边")
        XCTAssertLessThan(Int(top.1), 60)
        XCTAssertLessThan(Int(top.2), 60)
        XCTAssertGreaterThan(Int(center.0) - Int(top.0), 80, "中心应明显亮于黑边")
    }

    func testMixedVideoImageTransitionExport() async throws {
        // clip1 视频 + dissolve + 图片 + fade + clip2 视频
        let v1 = AssetItem(kind: .video, fileName: "clip1.mp4", origin: .synthesized,
                           duration: 4.0, pixelWidth: 1280, pixelHeight: 720, hasAudio: false)
        let v2 = AssetItem(kind: .video, fileName: "clip2.mp4", origin: .synthesized,
                           duration: 4.0, pixelWidth: 1280, pixelHeight: 720, hasAudio: false)
        let image = imageAsset
        let plan = EditPlan(assets: [v1, image, v2], clips: [
            PlanClip(assetID: v1.id, source: .video(0...3), transitionAfter: .dissolve(duration: 0.5)),
            PlanClip(assetID: image.id, source: .still(duration: 2.0), transitionAfter: .fade(duration: 0.5)),
            PlanClip(assetID: v2.id, source: .video(0...3)),
        ])
        let out = try await export(plan, to: "mixed.mp4")

        let asset = AVURLAsset(url: out)
        // 单视频轨（无 passthrough）
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let duration = try await CMTimeGetSeconds(asset.load(.duration))
        XCTAssertEqual(duration, plan.renderedDuration, accuracy: 0.25)
    }

    func testSnapshotInsideStillRegion() async throws {
        let image = imageAsset
        let plan = EditPlan(assets: [image],
                            clips: [PlanClip(assetID: image.id, source: .still(duration: 3.0))])
        let frames = try await FrameSnapshotter.snapshots(plan: plan, resolver: resolver, at: [1.5])
        let png = try XCTUnwrap(frames[1.5])
        XCTAssertTrue(png.starts(with: [0x89, 0x50, 0x4E, 0x47]), "应为 PNG")
    }

    func testStillSpeedHalvesOutputDuration() async throws {
        let image = imageAsset
        let plan = EditPlan(assets: [image],
                            clips: [PlanClip(assetID: image.id, source: .still(duration: 4.0), speed: .flat(2.0))])
        let out = try await export(plan, to: "img-speed.mp4")
        let duration = try await CMTimeGetSeconds(AVURLAsset(url: out).load(.duration))
        XCTAssertEqual(duration, 2.0, accuracy: 0.2, "图片 4s @2x → 输出 2s")
    }
}
