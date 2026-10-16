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

        let frames = await thumbnailer.frames(asset: asset, clip: clip, maxPixel: 192,
                                              outputOffsets: [0, 1, 2])
        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(frames.allSatisfy { $0 != nil }, "纯色素材每桶都应抽到帧")
    }

    func testFramesMapThroughSpeed() async throws {
        // 倍速 2：输出偏移 1s → 源 2s，仍应落在源区间 [0,4] 内抽出帧
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let asset = videoAsset("clip1.mp4")
        let clip = PlanClip(assetID: asset.id, source: .video(0...4), speed: .flat(2.0))
        let frames = await thumbnailer.frames(asset: asset, clip: clip, maxPixel: 128,
                                              outputOffsets: [0.5, 1.0])
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames.allSatisfy { $0 != nil })
    }

    func testStillClipFramesReturnTheSameImageForEveryOffset() async throws {
        // 图片没有源区间：任一输出偏移都是同一张图，全部槽位共用一个实例（L0 因此不必为图片单开分支）
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let asset = AssetItem(kind: .image, fileName: AssetSynthesizer.imageFileName)
        let clip = PlanClip(assetID: asset.id, source: .still(duration: 3))
        let frames = await thumbnailer.frames(asset: asset, clip: clip, maxPixel: 192,
                                              outputOffsets: [0, 1, 2])
        XCTAssertEqual(frames.count, 3)
        XCTAssertNotNil(frames[0])
        XCTAssertTrue(frames.allSatisfy { $0 === frames[0] })
    }

    func testStillClipFramesReturnNilWhenImageCannotBeDecoded() async throws {
        // 兜底：文件读不出（这里借一个视频文件冒充图片）→ nil，不崩
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let asset = AssetItem(kind: .image, fileName: "clip1.mp4")
        let clip = PlanClip(assetID: asset.id, source: .still(duration: 3))
        let frames = await thumbnailer.frames(asset: asset, clip: clip, maxPixel: 192,
                                              outputOffsets: [0, 1])
        XCTAssertEqual(frames, [nil, nil])
    }

    func testAssetThumbnailReturnsImageForVideo() async throws {
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let image = await thumbnailer.thumbnail(for: videoAsset("clip1.mp4"), maxPixel: 240)
        XCTAssertNotNil(image)
    }

    func testImageThumbnailReturnsImage() async throws {
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let asset = AssetItem(kind: .image, fileName: AssetSynthesizer.imageFileName)
        let image = await thumbnailer.thumbnail(for: asset, maxPixel: 240)
        XCTAssertNotNil(image)
    }

    func testDistinctMaxPixelsUseDistinctCacheEntries() async throws {
        // 像素档应进缓存键：同素材同偏移、不同档 → 不得命中同一条目
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let asset = videoAsset("clip1.mp4")
        let clip = PlanClip(assetID: asset.id, source: .video(0...4))
        let small = await thumbnailer.frames(asset: asset, clip: clip, maxPixel: 128, outputOffsets: [1])
        let large = await thumbnailer.frames(asset: asset, clip: clip, maxPixel: 256, outputOffsets: [1])
        XCTAssertNotNil(small[0])
        XCTAssertNotNil(large[0])
        XCTAssertFalse(small[0] === large[0], "不同像素档不得命中同一条缓存")
    }

    func testCacheReturnsSameInstanceForRepeatedRequest() async throws {
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let asset = videoAsset("clip1.mp4")
        let clip = PlanClip(assetID: asset.id, source: .video(0...4))
        let first = await thumbnailer.frames(asset: asset, clip: clip, maxPixel: 192, outputOffsets: [1])
        let second = await thumbnailer.frames(asset: asset, clip: clip, maxPixel: 192, outputOffsets: [1])
        XCTAssertTrue(first[0] === second[0], "同键应命中缓存、返回同一 CGImage 实例")
    }

    func testThumbnailAndFramesShareCacheKeyAtTimeZero() async throws {
        // 两条路径的键同源：素材库单帧（t=0）与时间线抽帧（源时间 0）应命中同一条缓存
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let asset = videoAsset("clip1.mp4")
        let clip = PlanClip(assetID: asset.id, source: .video(0...4))
        let single = await thumbnailer.thumbnail(for: asset, maxPixel: 192)
        let framed = await thumbnailer.frames(asset: asset, clip: clip, maxPixel: 192, outputOffsets: [0])
        XCTAssertNotNil(single)
        XCTAssertTrue(single === framed[0], "同素材同像素档、源时间 0 → 同一条缓存")
    }

    @MainActor
    func testFrameBucketIsFinerThanSmallestCellSourceSpan() {
        // 不变式：相邻格的**源时间**间距 = 最小格时长 × 最小倍速。桶比它粗的话，
        // 高倍缩放 × 慢放下相邻格会抽到同一帧（条上出现重复画面）。
        let smallestCellDuration = TimelineFilmstrip.minCellWidth / TimelineViewportState.maxPointsPerSecond
        let smallestSourceSpan = smallestCellDuration * EditPlanValidator.speedRange.lowerBound
        XCTAssertLessThan(TimelineThumbnailer.frameBucket, smallestSourceSpan)
    }

    func testCachedFramesReturnOnlyWhatIsAlreadyCached() async throws {
        // 只查缓存、不抽帧：冷缓存全 nil；抽过的那一帧才命中
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let asset = videoAsset("clip1.mp4")
        let clip = PlanClip(assetID: asset.id, source: .video(0...4))

        let cold = await thumbnailer.cachedFrames(asset: asset, clip: clip, maxPixel: 192,
                                                  outputOffsets: [0, 1])
        XCTAssertEqual(cold, [nil, nil])

        _ = await thumbnailer.frames(asset: asset, clip: clip, maxPixel: 192, outputOffsets: [1])
        let warm = await thumbnailer.cachedFrames(asset: asset, clip: clip, maxPixel: 192,
                                                  outputOffsets: [0, 1])
        XCTAssertNil(warm[0], "没抽过的偏移仍应是 nil")
        XCTAssertNotNil(warm[1])
    }

    func testCachedFramesHitForStillClip() async throws {
        // 图片没有源区间：与 `frames` 同口径（源时间 0），降采样过之后每一格都命中同一张
        let thumbnailer = TimelineThumbnailer(resolver: resolver)
        let asset = AssetItem(kind: .image, fileName: AssetSynthesizer.imageFileName)
        let clip = PlanClip(assetID: asset.id, source: .still(duration: 3))
        _ = await thumbnailer.thumbnail(for: asset, maxPixel: 192)
        let cached = await thumbnailer.cachedFrames(asset: asset, clip: clip, maxPixel: 192,
                                                    outputOffsets: [0, 2])
        XCTAssertNotNil(cached[0])
        XCTAssertTrue(cached[0] === cached[1])
    }
}