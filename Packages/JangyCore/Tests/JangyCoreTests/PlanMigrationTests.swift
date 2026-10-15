import XCTest
@testable import JangyCore
@testable import JangyTestSupport

final class PlanMigrationTests: XCTestCase {

    private func fixtureData() throws -> Data {
        let url = Bundle.module.url(forResource: "plan-v3", withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    private func assetsDirectory(withAssets: Bool) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if withAssets { _ = try AssetSynthesizer.synthesize(into: dir) }
        return dir
    }

    func testLegacyDecodingReadsV3Shape() throws {
        let legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: try fixtureData())
        XCTAssertEqual(legacy.clips.count, 3)
        XCTAssertEqual(legacy.captions?.style?.fontSize, 48)
        XCTAssertEqual(legacy.assets.count, 4)
    }

    func testMigrateBuildsSingleChainedPrimaryTrack() throws {
        let legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: try fixtureData())
        let dir = try assetsDirectory(withAssets: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = PlanMigration.migrate(legacy, assetsDirectory: dir)
        XCTAssertEqual(result.tracks.count, 2, "主轨 + 字幕轨")
        XCTAssertEqual(result.primaryTrackID, result.tracks[0].id)
        XCTAssertEqual(result.tracks[0].placement, .chained)
        XCTAssertEqual(result.tracks[0].elements.count, 3)
        XCTAssertEqual(result.tracks[0].elements[0].id,
                       UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                       "元素 id 继承原 clip id")
    }

    func testMigratedDurationMatchesV3Anchor() throws {
        let legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: try fixtureData())
        let dir = try assetsDirectory(withAssets: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = PlanMigration.migrate(legacy, assetsDirectory: dir)
        let total = result.tracks[0].elements.reduce(0.0) { $0 + $1.duration }
        // 3s@1x + 3s@0.5x + 2s@2x，挂 0.5s dissolve → 输出 9.5s
        XCTAssertEqual(total - 0.5, 9.5, accuracy: 0.001)
    }

    func testCuesExpandFromSRTWhenAssetsPresent() throws {
        let legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: try fixtureData())
        let dir = try assetsDirectory(withAssets: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = PlanMigration.migrate(legacy, assetsDirectory: dir)
        let captionTrack = result.tracks.first { $0.kind == .caption }
        XCTAssertEqual(captionTrack?.elements.count, 3, "sample.srt 有 3 条 cue")
        XCTAssertEqual(captionTrack?.elements[0].at, 0, "cue 位置进 element.at")
        XCTAssertEqual(CaptionFeature.settings(of: captionTrack!).sourceAssetID,
                       SamplePlan.captionAssetID, "来源素材引用保留")
    }

    func testMissingSRTLeavesEmptyCaptionTrackWithoutThrowing() throws {
        let legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: try fixtureData())
        let dir = try assetsDirectory(withAssets: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = PlanMigration.migrate(legacy, assetsDirectory: dir)
        let captionTrack = result.tracks.first { $0.kind == .caption }
        XCTAssertEqual(captionTrack?.elements.count, 0, "SRT 缺失时留空轨，不抛错")
        XCTAssertEqual(CaptionFeature.settings(of: captionTrack!).sourceAssetID,
                       SamplePlan.captionAssetID, "settings 保留来源，供完整性报告提示")
    }

    func testMissingAssetsDirectoryStillProducesStructure() throws {
        let legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: try fixtureData())
        let result = PlanMigration.migrate(legacy, assetsDirectory: nil)
        XCTAssertEqual(result.tracks.count, 2)
        XCTAssertEqual(result.tracks.first { $0.kind == .caption }?.elements.count, 0)
    }
}
