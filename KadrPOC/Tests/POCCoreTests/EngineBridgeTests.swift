import XCTest
import CoreMedia
import Kadr
import KadrCaptions
@testable import POCCore

final class EngineBridgeTests: XCTestCase {

    private var resolver: AssetResolver!
    private var assetsDir: URL!

    override func setUp() async throws {
        assetsDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        resolver = try AssetSynthesizer.synthesize(into: assetsDir)
    }

    override func tearDown() async throws {
        if let assetsDir {
            try? FileManager.default.removeItem(at: assetsDir)
        }
        resolver = nil
        assetsDir = nil
    }

    func testSamplePlanStructure() async throws {
        let video = try await EngineBridge.makeComposition(from: SamplePlan.make(), resolver: resolver)
        // 3 个 PlanClip + 1 个转场 = 4 个时间线元素，转场在第 2 位
        XCTAssertEqual(video.clips.count, 4)
        XCTAssertTrue(video.clips[0] is Kadr.VideoClip)
        XCTAssertTrue(video.clips[1] is Kadr.Transition)
        XCTAssertTrue(video.clips[2] is Kadr.VideoClip)
        XCTAssertTrue(video.clips[3] is Kadr.VideoClip)
        // 字幕：3 条 cue → 软字幕 3 条 + 烧录 overlay 3 个
        XCTAssertEqual(video.captions.count, 3)
        XCTAssertEqual(video.overlays.count, 3)
        // duration = 3(clip1@1x) + 0.5(转场) + 6(clip2@0.5x) + 1(clip3@2x) = 10.5
        // Video.duration 是属性求和（转场全额计入）≠ 渲染输出时长（dissolve 重叠扣除，
        // 此 sample 渲染输出为 9.5s）；预览/导出不得用它当输出长度。
        XCTAssertEqual(CMTimeGetSeconds(video.duration), 10.5, accuracy: 0.01)
    }

    func testCaptionsDisabledProducesNoOverlays() async throws {
        var plan = SamplePlan.make()
        plan.captions?.isEnabled = false
        let video = try await EngineBridge.makeComposition(from: plan, resolver: resolver)
        XCTAssertEqual(video.captions.count, 0)
        XCTAssertEqual(video.overlays.count, 0)
    }

    func testTransitionMapping() {
        // Kadr.Transition 无 Equatable 一致性——用 switch 模式匹配断言 case 与 duration。
        let dissolve = EngineBridge.kadrTransition(.dissolve(duration: 0.5))
        guard case .dissolve(let dissolveDuration) = dissolve else {
            return XCTFail("expected .dissolve, got \(dissolve)")
        }
        XCTAssertEqual(CMTimeGetSeconds(dissolveDuration), 0.5, accuracy: 0.001)

        let fade = EngineBridge.kadrTransition(.fade(duration: 0.3))
        guard case .fade(let fadeDuration) = fade else {
            return XCTFail("expected .fade, got \(fade)")
        }
        XCTAssertEqual(CMTimeGetSeconds(fadeDuration), 0.3, accuracy: 0.001)
    }

    func testSingleClipNoTransition() async throws {
        let plan = EditPlan(clips: [PlanClip(source: MediaRef(fileName: "clip1.mp4"), range: 0...3)])
        let video = try await EngineBridge.makeComposition(from: plan, resolver: resolver)
        XCTAssertEqual(video.clips.count, 1)
        XCTAssertEqual(CMTimeGetSeconds(video.duration), 3.0, accuracy: 0.01)
    }

    func testCaptionOverlayVisibilityRangeMatchesCue() async throws {
        let plan = SamplePlan.make()
        let video = try await EngineBridge.makeComposition(from: plan, resolver: resolver)
        let cues = try await Kadr.Caption.load(srt: resolver.resolve(plan.captions!.source))
        // 烧录走 ImageOverlay（macOS headless 下 CATextLayer 不渲染，见 CaptionImageRenderer 注释）
        let overlay = try XCTUnwrap(video.overlays.first as? Kadr.ImageOverlay)
        let visibility = try XCTUnwrap(overlay.visibilityRange)
        let cueRange = cues[0].timeRange
        XCTAssertEqual(CMTimeGetSeconds(visibility.start), CMTimeGetSeconds(cueRange.start), accuracy: 0.01)
        XCTAssertEqual(CMTimeGetSeconds(CMTimeRangeGetEnd(visibility)),
                       CMTimeGetSeconds(CMTimeRangeGetEnd(cueRange)), accuracy: 0.01)
        // CMTimeRange 直达（无双秒往返）：SRT 解析为 timescale 1000，overlay 必须原样保留，
        // 不得被 ClosedRange<TimeInterval> 重定量化到 600。
        XCTAssertEqual(visibility.start.timescale, cueRange.start.timescale)
        XCTAssertEqual(visibility.duration.timescale, cueRange.duration.timescale)
    }
}
