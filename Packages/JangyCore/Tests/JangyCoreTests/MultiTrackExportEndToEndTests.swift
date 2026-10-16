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
        // 阻塞项已由 Kadr fork 修复（分支 fix/multitrack-layer-order-and-frame-hold）：
        //   ① 层序：AVFoundation 的 layerInstructions[0] 是**最上层**，Kadr buildMultiTrack
        //      原先按 videoTracks 顺序构造数组，主轨恒在最上；现反转为并行轨在上。
        //   ② 末帧保持：早于合成末端结束的轨道其末帧会被保持并盖住后续帧；现给每条轨在
        //      内容结束点补 setOpacity(0, at:)，使其透明。
        // 详见 docs/superpowers/specs/2026-10-15-timeline-tracks-design.md 的「待验证 / 未决」。
        let a = videoAsset("clip1.mp4")   // 红
        let b = videoAsset("clip2.mp4")   // 绿
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: a.id, source: .video(0...3))))),
        ])
        let overlay = PlanTrack(kind: .video, placement: .absolute, elements: [
            PlanElement(at: 0.5, content: .content(TrackPayload(
                PlanClip(assetID: b.id, source: .video(0...2))))),
        ])
        let plan = EditPlan(assets: [a, b], tracks: [primary, overlay], primaryTrackID: primary.id)

        let out = try await export(plan, to: "overlay.mp4")
        let asset = AVURLAsset(url: out)

        // 叠加时段内（0.5–2.5s）应看到叠加轨的绿
        let during = try meanColor(asset, at: 1.0, in: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
        XCTAssertGreaterThan(during.green, during.red, "叠加时段内应看到叠加轨的绿")

        // 叠加结束后（2.5s 之后）应回到主轨的红——**这条同时钉住「末帧不被保持」**
        let after = try meanColor(asset, at: 2.8, in: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
        XCTAssertGreaterThan(after.red, after.green, "叠加结束后应回到主轨的红，末帧不得被保持")
    }

    /// 叠加轨多元素**绝对定位**：每个元素落在自己的 `at` 上，而不是顺次从轨道起点排。
    /// `Kadr.Track { }` 内部元素的 `.at(time:)` 被忽略（Track 内是 track-relative 隐式链），
    /// 所以叠加轨必须「每个元素一个 Track(at:)」。上面那条 e2e 只有一个叠加元素、且 at 恰为 0.5，
    /// 顺次排布（落在 0–2s）与绝对定位（落在 0.5–2.5s）在它那两个采样点上不可区分，故没能暴露本问题。
    func testMultiElementOverlayTrackPositionsElementsAbsolutely() async throws {
        let a = videoAsset("clip1.mp4")   // 红
        let b = videoAsset("clip2.mp4")   // 绿
        let c = videoAsset("clip3.mp4")   // 蓝
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: a.id, source: .video(0...4))))),
        ])
        // 两个叠加元素，分别锚在 0.5s（绿，0.5–1.5）与 2.0s（蓝，2.0–3.0），中间 1.5–2.0 空着。
        let overlay = PlanTrack(kind: .video, placement: .absolute, elements: [
            PlanElement(at: 0.5, content: .content(TrackPayload(
                PlanClip(assetID: b.id, source: .video(0...1))))),
            PlanElement(at: 2.0, content: .content(TrackPayload(
                PlanClip(assetID: c.id, source: .video(0...1))))),
        ])
        let plan = EditPlan(assets: [a, b, c], tracks: [primary, overlay], primaryTrackID: primary.id)

        let out = try await export(plan, to: "overlay-multi.mp4")
        let asset = AVURLAsset(url: out)
        let rect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)

        // 元素 A 的绝对窗口内（1.0s）见绿——若顺次排布，这里会是 B 的蓝
        let atA = try meanColor(asset, at: 1.0, in: rect)
        XCTAssertGreaterThan(atA.green, atA.red, "t=1.0 应见叠加元素 A 的绿")
        XCTAssertGreaterThan(atA.green, atA.blue, "t=1.0 应见叠加元素 A 的绿（不是 B 的蓝）")

        // 两元素之间的空档（1.75s）见主轨红——顺次排布会让 B 落在这里
        let between = try meanColor(asset, at: 1.75, in: rect)
        XCTAssertGreaterThan(between.red, between.green, "t=1.75 两叠加元素之间应见主轨红")
        XCTAssertGreaterThan(between.red, between.blue, "t=1.75 两叠加元素之间应见主轨红")

        // 元素 B 的绝对窗口内（2.5s）见蓝
        let atB = try meanColor(asset, at: 2.5, in: rect)
        XCTAssertGreaterThan(atB.blue, atB.red, "t=2.5 应见叠加元素 B 的蓝")
        XCTAssertGreaterThan(atB.blue, atB.green, "t=2.5 应见叠加元素 B 的蓝")
    }

    /// 左右分屏（竖屏源，源已铺满画布 → 半宽块即 scale 0.5）：左半偏红、右半偏绿。
    func testLeftRightSplitRendersBothHalves() async throws {
        let a = try portraitAsset("splitRed.mp4", color: (0.90, 0.20, 0.20))   // 红
        let b = try portraitAsset("splitGreen.mp4", color: (0.20, 0.80, 0.30)) // 绿
        try await assertLeftRightSplit(a, b, to: "split.mp4",
                                       leftRect: CGRect(x: 0.05, y: 0.4, width: 0.4, height: 0.2),
                                       rightRect: CGRect(x: 0.55, y: 0.4, width: 0.4, height: 0.2))
    }

    /// 左右分屏（横屏源 1280×720）：Kadr 的 transform 作用在 aspect-fill **之后**，横屏源填充后
    /// 宽达画布 ~3.16 倍，恒定 scale 0.5 只会得到满宽横带；`halfScreen` 按源宽高比把 scale 算成
    /// ~0.1582，块宽回到画布一半（~540px）、高 ~303px、垂直居中（y 0.421–0.579）。
    func testLeftRightSplitRendersBothHalvesForLandscapeSource() async throws {
        let a = videoAsset("clip1.mp4")   // 红
        let b = videoAsset("clip2.mp4")   // 绿
        // 采样矩形落在块内：左块 x 0–0.5、右块 x 0.5–1.0，y 均在 0.421–0.579。
        try await assertLeftRightSplit(a, b, to: "split-landscape.mp4",
                                       leftRect: CGRect(x: 0.1, y: 0.46, width: 0.3, height: 0.08),
                                       rightRect: CGRect(x: 0.6, y: 0.46, width: 0.3, height: 0.08))
    }

    private func assertLeftRightSplit(_ a: AssetItem, _ b: AssetItem, to name: String,
                                      leftRect: CGRect, rightRect: CGRect) async throws {
        var mainClip = PlanClip(assetID: a.id, source: .video(0...3))
        mainClip.transform = .halfScreen(for: a, preset: .reelsAndShorts, side: .left)
        var overlayClip = PlanClip(assetID: b.id, source: .video(0...3))
        overlayClip.transform = .halfScreen(for: b, preset: .reelsAndShorts, side: .right)
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(mainClip)))])
        let overlay = PlanTrack(kind: .video, placement: .absolute, elements: [
            PlanElement(at: 0, content: .content(TrackPayload(overlayClip)))])
        let plan = EditPlan(assets: [a, b], tracks: [primary, overlay], primaryTrackID: primary.id)

        let out = try await export(plan, to: name)
        let asset = AVURLAsset(url: out)
        let left = try meanColor(asset, at: 1.0, in: leftRect)
        let right = try meanColor(asset, at: 1.0, in: rightRect)
        XCTAssertGreaterThan(left.red, left.green, "左半应是主轨的红")
        XCTAssertGreaterThan(right.green, right.red, "右半应是叠加轨的绿")
    }

    /// 与画布等比（9:16）的竖屏纯色素材——分屏 e2e 需要铺满画布的源。
    private func portraitAsset(_ name: String, color: (r: CGFloat, g: CGFloat, b: CGFloat)) throws -> AssetItem {
        let url = assetsDir.appendingPathComponent(name)
        try AssetSynthesizer.writeSolidColorVideo(
            to: url, color: CGColor(red: color.r, green: color.g, blue: color.b, alpha: 1),
            seconds: 4, width: 1080, height: 1920)
        return AssetItem(kind: .video, fileName: name, origin: .synthesized,
                         duration: 4.0, pixelWidth: 1080, pixelHeight: 1920, hasAudio: false)
    }
}
