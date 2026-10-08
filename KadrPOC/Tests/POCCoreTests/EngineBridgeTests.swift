import XCTest
import CoreMedia
import Kadr
@testable import POCCore

final class EngineBridgeTests: XCTestCase {

    private var resolver: AssetResolver!

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        resolver = try AssetSynthesizer.synthesize(into: dir)
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
        // （Kadr Video.duration 为各 Clip.duration 之和，转场时长计入）
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
}
