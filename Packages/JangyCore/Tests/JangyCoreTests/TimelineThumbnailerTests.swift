import XCTest
import CoreGraphics
@testable import JangyCore
@testable import JangyTestSupport

final class TimelineThumbnailerTests: XCTestCase {
    private var dir: URL!
    private var resolver: AssetResolver!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        resolver = try AssetSynthesizer.synthesize(into: dir)
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func videoAsset(_ name: String) -> AssetItem {
        AssetItem(kind: .video, fileName: name, origin: .synthesized,
                  duration: 4.0, pixelWidth: 1280, pixelHeight: 720, hasAudio: false)
    }

    func testFramesAreProducedAtRequestedOutputOffsets() async throws {
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let asset = videoAsset("clip1.mp4")
        let clip = PlanClip(assetID: asset.id, source: .video(0...4), speed: .flat(1.0))

        let frames = await thumbnailer.frames(asset: asset, clip: clip, level: .medium,
                                              outputOffsets: [0, 1, 2])
        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(frames.allSatisfy { $0 != nil }, "纯色素材每桶都应抽到帧")
    }

    func testFramesMapThroughSpeed() async throws {
        // 倍速 2：输出偏移 1s → 源 2s，仍应落在源区间 [0,4] 内抽出帧
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let asset = videoAsset("clip1.mp4")
        let clip = PlanClip(assetID: asset.id, source: .video(0...4), speed: .flat(2.0))
        let frames = await thumbnailer.frames(asset: asset, clip: clip, level: .small,
                                              outputOffsets: [0.5, 1.0])
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames.allSatisfy { $0 != nil })
    }

    func testStillAssetFramesAreNil() async throws {
        // 图片没有源区间，抽帧路径返回 nil（L0 走降采样兜底）
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let asset = AssetItem(kind: .image, fileName: "clip1.mp4")   // 借用存在的文件即可
        let clip = PlanClip(assetID: asset.id, source: .still(duration: 3))
        let frames = await thumbnailer.frames(asset: asset, clip: clip, level: .medium,
                                              outputOffsets: [0, 1])
        XCTAssertEqual(frames, [nil, nil])
    }

    func testAssetThumbnailReturnsImageForVideo() async throws {
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let image = await thumbnailer.thumbnail(for: videoAsset("clip1.mp4"), maxPixel: 240)
        XCTAssertNotNil(image)
    }

    func testCacheReturnsSameInstanceForRepeatedRequest() async throws {
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let asset = videoAsset("clip1.mp4")
        let clip = PlanClip(assetID: asset.id, source: .video(0...4))
        let first = await thumbnailer.frames(asset: asset, clip: clip, level: .medium, outputOffsets: [1])
        let second = await thumbnailer.frames(asset: asset, clip: clip, level: .medium, outputOffsets: [1])
        XCTAssertTrue(first[0] === second[0], "同键应命中缓存、返回同一 CGImage 实例")
    }
}
