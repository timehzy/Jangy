import XCTest
import CoreMedia
import Kadr
@testable import JangyCore
@testable import JangyTestSupport

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
        if let ti = plan.tracks.firstIndex(where: { $0.kind == .caption }) {
            var settings = CaptionFeature.settings(of: plan.tracks[ti])
            settings.isEnabled = false
            plan.tracks[ti].settings = TrackPayload(settings)
        }
        let video = try await EngineBridge.makeComposition(from: plan, resolver: resolver)
        XCTAssertEqual(video.captions.count, 0)
        XCTAssertEqual(video.overlays.count, 0)
    }

    // MARK: - isHidden 引擎行为（隐藏轨不进 composition；预览与导出共用这份 composition）

    /// 隐藏的字幕轨与「settings.isEnabled = false」同形：软字幕与烧录 overlay 都不产出。
    func testHiddenCaptionTrackProducesNoCaptions() async throws {
        var plan = SamplePlan.make()
        let ti = try XCTUnwrap(plan.tracks.firstIndex { $0.kind == .caption })
        plan.tracks[ti].isHidden = true
        let video = try await EngineBridge.makeComposition(from: plan, resolver: resolver)
        XCTAssertEqual(video.captions.count, 0)
        XCTAssertEqual(video.overlays.count, 0)
    }

    /// 隐藏的叠加视频轨（非主轨）：其元素对应的 `Kadr.Track` clip 不产出。
    func testHiddenOverlayTrackExcludedFromComposition() async throws {
        let a = AssetItem(kind: .video, fileName: "clip1.mp4", origin: .synthesized,
                          duration: 4.0, pixelWidth: 1280, pixelHeight: 720, hasAudio: false)
        let b = AssetItem(kind: .video, fileName: "clip2.mp4", origin: .synthesized,
                          duration: 4.0, pixelWidth: 1280, pixelHeight: 720, hasAudio: false)
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: a.id, source: .video(0...3))))),
        ])
        let overlay = PlanTrack(kind: .video, placement: .absolute, elements: [
            PlanElement(at: 0.5, content: .content(TrackPayload(
                PlanClip(assetID: b.id, source: .video(0...2))))),
        ])
        let shown = EditPlan(assets: [a, b], tracks: [primary, overlay], primaryTrackID: primary.id)
        var hidden = shown
        hidden.tracks[try XCTUnwrap(hidden.tracks.firstIndex { $0.id == overlay.id })].isHidden = true

        let shownVideo = try await EngineBridge.makeComposition(from: shown, resolver: resolver)
        let hiddenVideo = try await EngineBridge.makeComposition(from: hidden, resolver: resolver)

        // 叠加轨每个元素 → 一个 Kadr.Track clip；隐藏后该 Track 不产出。
        XCTAssertEqual(shownVideo.clips.filter { $0 is Kadr.Track }.count, 1)
        XCTAssertEqual(hiddenVideo.clips.filter { $0 is Kadr.Track }.count, 0)
        XCTAssertEqual(hiddenVideo.clips.count, shownVideo.clips.count - 1)
    }

    /// 主轨是链式基底，`isHidden` 不作用于它：3 个 PlanClip + 1 个转场仍全在。
    func testPrimaryTrackNotSkippedWhenHidden() async throws {
        var plan = SamplePlan.make()
        plan.tracks[try XCTUnwrap(plan.tracks.firstIndex { $0.id == plan.primaryTrackID })].isHidden = true
        let video = try await EngineBridge.makeComposition(from: plan, resolver: resolver)
        XCTAssertEqual(video.clips.count, 4)
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
        let assetID = UUID()
        let plan = PlanTestSupport.plan(
            assets: [AssetItem(id: assetID, kind: .video, fileName: "clip1.mp4", duration: 4.0)],
            clips: [PlanClip(assetID: assetID, source: .video(0...3))])
        let video = try await EngineBridge.makeComposition(from: plan, resolver: resolver)
        XCTAssertEqual(video.clips.count, 1)
        XCTAssertEqual(CMTimeGetSeconds(video.duration), 3.0, accuracy: 0.01)
    }

    func testCaptionOverlayVisibilityRangeMatchesCue() async throws {
        let plan = SamplePlan.make()
        let video = try await EngineBridge.makeComposition(from: plan, resolver: resolver)
        let track = plan.tracks.first { $0.kind == .caption }!
        let cues = CaptionEngine.makeCues(track: track)
        // 烧录走 ImageOverlay（macOS headless 下 CATextLayer 不渲染，见 CaptionImageRenderer 注释）
        let overlay = try XCTUnwrap(video.overlays.first as? Kadr.ImageOverlay)
        let visibility = try XCTUnwrap(overlay.visibilityRange)
        let cueRange = cues[0].timeRange
        XCTAssertEqual(CMTimeGetSeconds(visibility.start), CMTimeGetSeconds(cueRange.start), accuracy: 0.01)
        XCTAssertEqual(CMTimeGetSeconds(CMTimeRangeGetEnd(visibility)),
                       CMTimeGetSeconds(CMTimeRangeGetEnd(cueRange)), accuracy: 0.01)
        // CMTimeRange 直达（无双秒往返）：cue 位置由 element.at 以 timescale 1000 构造，
        // overlay 必须原样保留，不得被 ClosedRange<TimeInterval> 重定量化到 600。
        XCTAssertEqual(visibility.start.timescale, cueRange.start.timescale)
        XCTAssertEqual(visibility.duration.timescale, cueRange.duration.timescale)
    }
}
