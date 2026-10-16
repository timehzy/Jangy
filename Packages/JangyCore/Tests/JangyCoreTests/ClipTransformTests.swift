import XCTest
import CoreGraphics
@testable import JangyCore

final class ClipTransformTests: XCTestCase {

    func testFullScreenIsIdentityDefaults() {
        XCTAssertEqual(ClipTransform.fullScreen, ClipTransform())
        XCTAssertEqual(ClipTransform.fullScreen.scale, 1)
        XCTAssertEqual(ClipTransform.fullScreen.centerX, 0.5)
    }

    func testHalfScreenSymmetry() {
        let canvas = CGSize(width: 1080, height: 1920)
        let left = ClipTransform.halfScreen(sourceSize: canvas, canvasSize: canvas, side: .left)
        let right = ClipTransform.halfScreen(sourceSize: canvas, canvasSize: canvas, side: .right)
        XCTAssertEqual(left.centerX + right.centerX, 1.0, accuracy: 0.0001)
        XCTAssertEqual(left.centerY, right.centerY)
        // 源已铺满画布（filledWidth == canvasWidth）时，半宽块就是 scale 0.5。
        XCTAssertEqual(left.scale, 0.5, accuracy: 0.0001)
        XCTAssertEqual(right.scale, 0.5, accuracy: 0.0001)
    }

    func testHalfScreenLandscapeSourceScalesToHalfWidth() {
        let source = CGSize(width: 1280, height: 720)
        let canvas = CGSize(width: 1080, height: 1920)
        let left = ClipTransform.halfScreen(sourceSize: source, canvasSize: canvas, side: .left)
        XCTAssertEqual(left.scale, 0.1582, accuracy: 0.001)

        // 出来的块宽就是画布一半宽。
        let fill = max(canvas.width / source.width, canvas.height / source.height)
        let filledWidth = source.width * fill
        XCTAssertEqual(left.scale * filledWidth, 0.5 * canvas.width, accuracy: 0.5)
    }

    func testHalfScreenImageUsesCanvasAsSource() {
        // 图片经 StillImagePreparer 预合成到画布（letterbox），填充后尺寸即画布 → scale 0.5。
        let asset = AssetItem(kind: .image, fileName: "i.png")
        let transform = ClipTransform.halfScreen(for: asset, preset: .reelsAndShorts, side: .left)
        XCTAssertEqual(transform.scale, 0.5, accuracy: 0.0001)
    }

    func testHalfScreenDegenerateSourceFallsBackToFullScreen() {
        let transform = ClipTransform.halfScreen(
            sourceSize: CGSize(width: 0, height: 0),
            canvasSize: CGSize(width: 1080, height: 1920), side: .left)
        XCTAssertEqual(transform, .fullScreen)
    }

    func testClipRoundTripsWithTransform() throws {
        var clip = PlanClip(assetID: UUID(), source: .video(0...3))
        clip.transform = ClipTransform(centerX: 0.25, centerY: 0.5, scale: 0.1582)
        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(PlanClip.self, from: data)
        XCTAssertEqual(decoded.transform, ClipTransform(centerX: 0.25, centerY: 0.5, scale: 0.1582))
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
