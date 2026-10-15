import XCTest
@testable import JangyCore

final class VideoFeatureTests: XCTestCase {
    private let assetID = UUID()

    private func context(assets: [AssetItem], mainTrackEnd: TimeInterval = 10) -> TrackValidationContext {
        TrackValidationContext(assets: assets, mainTrackEnd: mainTrackEnd, tracks: [])
    }

    func testClipRoundTripsAsTrackPayload() throws {
        let clip = PlanClip(assetID: assetID, source: .video(0...3), speed: .flat(2.0))
        let payload = TrackPayload(clip)
        XCTAssertEqual(payload.payloadType, "clip")
        XCTAssertEqual(payload.duration, 1.5, accuracy: 0.0001)

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TrackPayload.self, from: data)
        XCTAssertEqual(decoded.value as? PlanClip, clip)
    }

    func testClipJSONCarriesTypeDiscriminator() throws {
        let data = try JSONEncoder().encode(TrackPayload(PlanClip(assetID: assetID, source: .video(0...3))))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "clip")
    }

    func testValidateRejectsVideoClipReferencingImageAsset() {
        let track = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: assetID, source: .video(0...3))))),
        ])
        let issues = VideoFeature.validate(
            track: track,
            context: context(assets: [AssetItem(id: assetID, kind: .image, fileName: "a.png")]))
        XCTAssertTrue(issues.contains { $0.message.contains("视频片段必须引用视频素材") })
    }

    func testValidateRejectsTransitionCrossingGap() {
        let track = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: assetID, source: .video(0...3),
                                                                transitionAfter: .dissolve(duration: 0.5))))),
            PlanElement(content: .gap(duration: 1)),
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: assetID, source: .video(0...3))))),
        ])
        let issues = VideoFeature.validate(track: track, context: context(assets: []))
        XCTAssertTrue(issues.contains { $0.message.contains("转场不能跨过空档") })
    }

    func testValidateIssuesCarryElementID() {
        let element = PlanElement(content: .content(TrackPayload(
            PlanClip(assetID: UUID(), source: .video(0...3)))))
        let track = PlanTrack(kind: .video, placement: .chained, elements: [element])
        let issues = VideoFeature.validate(track: track, context: context(assets: []))
        XCTAssertEqual(issues.first?.elementID, element.id)
    }

    func testValidateAcceptsChainedGap() {
        let track = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .gap(duration: 2)),
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: assetID, source: .video(0...3))))),
        ])
        XCTAssertTrue(VideoFeature.validate(
            track: track,
            context: context(assets: [AssetItem(id: assetID, kind: .video, fileName: "v.mp4", duration: 4)])).isEmpty)
    }

    // MARK: - 边界用例：钉住从旧 EditPlanValidator 平移过来的规则（Task 6 删旧代码后仍要绿）

    /// 规则：图片片段（.still）必须引用图片素材。
    func testValidateRejectsStillClipReferencingNonImageAsset() {
        let track = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: assetID, source: .still(duration: 3))))),
        ])
        let issues = VideoFeature.validate(
            track: track,
            context: context(assets: [AssetItem(id: assetID, kind: .video, fileName: "v.mp4")]))
        XCTAssertTrue(issues.contains { $0.message.contains("图片片段必须引用图片素材") })
    }

    /// 规则：图片时长必须为正（0 或负都拒）。
    func testValidateRejectsNonPositiveStillDuration() {
        let track = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: assetID, source: .still(duration: 0))))),
        ])
        let issues = VideoFeature.validate(
            track: track,
            context: context(assets: [AssetItem(id: assetID, kind: .image, fileName: "a.png")]))
        XCTAssertTrue(issues.contains { $0.message.contains("图片时长必须为正") })
    }

    /// 规则：变速倍率必须落在 EditPlanValidator.speedRange 内（这里取越界值 9.0）。
    func testValidateRejectsOutOfRangeSpeed() {
        let track = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(
                PlanClip(assetID: assetID, source: .video(0...3), speed: .flat(9.0))))),
        ])
        let issues = VideoFeature.validate(
            track: track,
            context: context(assets: [AssetItem(id: assetID, kind: .video, fileName: "v.mp4", duration: 4)]))
        XCTAssertTrue(issues.contains { $0.message.contains("变速倍率必须在") })
    }

    /// 规则：转场时长不得超过相邻较短者的时长（这里相邻为 3s 与 1s，转场 2s 越界）。
    func testValidateRejectsTransitionExceedingAdjacentDuration() {
        let track = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: assetID, source: .video(0...3),
                                                                transitionAfter: .dissolve(duration: 2))))),
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: assetID, source: .video(0...1))))),
        ])
        let issues = VideoFeature.validate(
            track: track,
            context: context(assets: [AssetItem(id: assetID, kind: .video, fileName: "v.mp4", duration: 4)]))
        XCTAssertTrue(issues.contains { $0.message.contains("转场时长不能超过相邻片段时长") })
    }

    /// 规则：最后一个元素不能挂转场（没有「下一个」可转）。
    func testValidateRejectsTransitionOnLastElement() {
        let track = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: assetID, source: .video(0...3),
                                                                transitionAfter: .dissolve(duration: 0.5))))),
        ])
        let issues = VideoFeature.validate(track: track, context: context(assets: []))
        XCTAssertTrue(issues.contains { $0.message.contains("最后一个片段不能挂转场") })
    }

    /// 规则：引用必须落在素材登记表里。
    func testValidateRejectsUnregisteredAsset() {
        let track = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(PlanClip(assetID: assetID, source: .video(0...3))))),
        ])
        let issues = VideoFeature.validate(track: track, context: context(assets: []))
        XCTAssertTrue(issues.contains { $0.message.contains("引用了未登记的素材") })
    }
}
