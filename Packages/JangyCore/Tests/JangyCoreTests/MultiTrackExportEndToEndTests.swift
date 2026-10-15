import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
@testable import JangyCore
@testable import JangyTestSupport

/// 多轨导出端到端：主轨 + 叠加视频轨、主轨带 gap。
/// 素材为纯色视频（clip1 红 / clip2 绿 / clip3 蓝），像素级断言因此可行。
final class MultiTrackExportEndToEndTests: XCTestCase {
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

    private func videoAsset(_ name: String) -> AssetItem {
        AssetItem(kind: .video, fileName: name, origin: .synthesized,
                  duration: 4.0, pixelWidth: 1280, pixelHeight: 720, hasAudio: false)
    }

    private func export(_ plan: EditPlan, to name: String) async throws -> URL {
        let out = assetsDir.appendingPathComponent(name)
        for try await _ in ExportRunner.export(plan: plan, resolver: resolver, to: out) {}
        return out
    }

    /// 抽帧 → 指定相对矩形内的平均 RGB（0–255）。矩形按图像坐标，y 从顶部起算。
    private func meanColor(_ asset: AVAsset, at seconds: Double,
                           in rect: CGRect) throws -> (red: Double, green: Double, blue: Double) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let cg = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600),
                                           actualTime: nil)

        let x0 = Int(rect.minX * Double(cg.width)), x1 = Int(rect.maxX * Double(cg.width))
        let y0 = Int(rect.minY * Double(cg.height)), y1 = Int(rect.maxY * Double(cg.height))
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let o = (y * w + x) * 4
                r += Double(buf[o]); g += Double(buf[o + 1]); b += Double(buf[o + 2]); n += 1
            }
        }
        return (r / n, g / n, b / n)
    }

    func testGapRendersAsBlackAndPreservesDuration() async throws {
        let a = videoAsset("clip1.mp4")
        let b = videoAsset("clip2.mp4")
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: a.id, source: .video(0...2))))),
            PlanElement(content: .gap(duration: 1.0)),
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: b.id, source: .video(0...2))))),
        ])
        let plan = EditPlan(assets: [a, b], tracks: [primary], primaryTrackID: primary.id)

        let out = try await export(plan, to: "gap.mp4")
        let asset = AVURLAsset(url: out)
        let duration = try await CMTimeGetSeconds(asset.load(.duration))
        XCTAssertEqual(duration, plan.renderedDuration, accuracy: 0.2)
        XCTAssertEqual(plan.renderedDuration, 5.0, accuracy: 0.001)

        // 主轨空洞处（2.0–3.0s）应为黑帧
        let color = try meanColor(asset, at: 2.5, in: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
        XCTAssertLessThan(color.red + color.green + color.blue, 36,
                          "gap 区间应为黑场，实测 RGB \(color)")
    }

    func testOverlayTrackRendersOverMainTrack() async throws {
        // 阻塞项（2026-10-15 实测）：叠加视频轨在导出里被主轨完全遮挡。
        // 成因两层，都在 Kadr 侧：
        //   ① 层序：AVFoundation 的 layerInstructions[0] 是**最上层**（Apple 文档 + 裸 AVF 探针双重确认），
        //      而 Kadr buildMultiTrack 强制把隐式主链放进 videoTracks[0] → 主轨恒在最上。
        //      Kadr 源码里两处「later = on top」的注释写反了。
        //   ② 末帧保持：任何早于合成末端结束的轨道，其末帧会被 AVFoundation 保持并盖住后续帧
        //      （默认路径与自定义 compositor 路径都有）。光修层序会变成「叠加结束后画面被冻结」。
        // 解除条件：Kadr fork 修好层序 + 末帧保持后，去掉本 skip。
        // 详见 docs/superpowers/specs/2026-10-15-timeline-tracks-design.md 的「待验证 / 未决」。
        throw XCTSkip("叠加轨层序/末帧保持是 Kadr 侧阻塞项，待 fork 修复后解除")
    }
}
