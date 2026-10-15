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
}
