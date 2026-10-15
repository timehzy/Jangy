import XCTest
@testable import JangyCore

final class ClipTransformTests: XCTestCase {

    func testFullScreenIsIdentityDefaults() {
        XCTAssertEqual(ClipTransform.fullScreen, ClipTransform())
        XCTAssertEqual(ClipTransform.fullScreen.scale, 1)
        XCTAssertEqual(ClipTransform.fullScreen.centerX, 0.5)
    }

    func testLeftRightHalfPresetsAreMirrored() {
        XCTAssertEqual(ClipTransform.leftHalf.scale, 0.5)
        XCTAssertEqual(ClipTransform.rightHalf.scale, 0.5)
        XCTAssertEqual(ClipTransform.leftHalf.centerX + ClipTransform.rightHalf.centerX, 1.0, accuracy: 0.0001)
        XCTAssertEqual(ClipTransform.leftHalf.centerY, ClipTransform.rightHalf.centerY)
    }

    func testClipRoundTripsWithTransform() throws {
        var clip = PlanClip(assetID: UUID(), source: .video(0...3))
        clip.transform = .rightHalf
        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(PlanClip.self, from: data)
        XCTAssertEqual(decoded.transform, .rightHalf)
    }

    func testClipWithoutTransformDecodesAsNil() throws {
        // 向后兼容：旧 v4 JSON 没有 transform 字段 → nil（全屏），不报错
        let json = #"{"assetID":"11111111-1111-1111-1111-111111111111","source":{"type":"video","range":[0,3]}}"#.data(using: .utf8)!
        let clip = try JSONDecoder().decode(PlanClip.self, from: json)
        XCTAssertNil(clip.transform)
    }

    func testValidateRejectsOutOfRangeTransform() {
        let asset = AssetItem(kind: .video, fileName: "v.mp4", duration: 10)
        var clip = PlanClip(assetID: asset.id, source: .video(0...3))
        clip.transform = ClipTransform(centerX: 1.5, centerY: 0.5, scale: 0, opacity: 2)
        let track = PlanTrack(kind: .video, placement: .chained,
                              elements: [PlanElement(content: .content(TrackPayload(clip)))])
        let issues = VideoFeature.validate(
            track: track,
            context: TrackValidationContext(assets: [asset], mainTrackEnd: 3, tracks: [track]))
        XCTAssertTrue(issues.contains { $0.message.contains("布局中心") })
        XCTAssertTrue(issues.contains { $0.message.contains("缩放必须为正") })
        XCTAssertTrue(issues.contains { $0.message.contains("不透明度") })
    }
}
