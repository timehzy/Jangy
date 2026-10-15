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

    // MARK: - notices（迁移期问题必须被调用方看见，不得静默丢）

    func testNoticesEmptyForCleanFixture() throws {
        let legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: try fixtureData())
        let dir = try assetsDirectory(withAssets: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = PlanMigration.migrate(legacy, assetsDirectory: dir)
        XCTAssertTrue(result.notices.isEmpty, "干净 fixture 不应产生任何 notice")
    }

    func testSkippedBlocksAreReported() throws {
        let legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: try fixtureData())
        let dir = try assetsDirectory(withAssets: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 第 2 块没有时间轴行 → 解析不出、被跳过，必须报出来而不是静默变少。
        let srt = """
        1
        00:00:00,000 --> 00:00:02,000
        有效

        2
        坏块没有时间轴
        """
        try srt.write(to: dir.appendingPathComponent("sample.srt"), atomically: true, encoding: .utf8)

        let result = PlanMigration.migrate(legacy, assetsDirectory: dir)
        XCTAssertEqual(result.tracks.first { $0.kind == .caption }?.elements.count, 1)
        XCTAssertEqual(result.notices,
                       [.captionBlocksSkipped(assetID: SamplePlan.captionAssetID, count: 1)])
    }

    func testUnreadableSRTIsReported() throws {
        let legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: try fixtureData())
        let dir = try assetsDirectory(withAssets: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 0x81 / 0x8D 在 UTF-8 与 windowsCP1252 里都是未定义字节，两种编码都解不出。
        try Data([0x81, 0x8D]).write(to: dir.appendingPathComponent("sample.srt"))

        let result = PlanMigration.migrate(legacy, assetsDirectory: dir)
        XCTAssertEqual(result.tracks.first { $0.kind == .caption }?.elements.count, 0)
        XCTAssertEqual(result.notices,
                       [.captionSourceUnreadable(assetID: SamplePlan.captionAssetID)])
    }

    func testCP1252EncodedSRTStillExpands() throws {
        let legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: try fixtureData())
        let dir = try assetsDirectory(withAssets: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        // é 在 CP1252 里是单字节 0xE9，作为 UTF-8 是非法序列 → 逼出编码回落分支。
        let srt = "1\n00:00:00,000 --> 00:00:02,000\ncafé\n"
        try srt.data(using: .windowsCP1252)!.write(to: dir.appendingPathComponent("sample.srt"))

        let result = PlanMigration.migrate(legacy, assetsDirectory: dir)
        let captionTrack = result.tracks.first { $0.kind == .caption }
        XCTAssertEqual(captionTrack?.elements.count, 1, "CP1252 编码的 SRT 应经回落正常展开")
        XCTAssertTrue(result.notices.isEmpty)
    }

    // MARK: - 内联 JSON（不新增 fixture 文件）

    func testLegacyRangeFallbackRestoresElement() throws {
        let json = """
        {
          "version": 3,
          "assets": [{"id":"AAAAAAAA-0000-0000-0000-000000000001","kind":"video","fileName":"clip1.mp4"}],
          "clips": [{"id":"11111111-1111-1111-1111-111111111111","assetID":"AAAAAAAA-0000-0000-0000-000000000001","range":[1,4]}]
        }
        """
        let legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: Data(json.utf8))
        let result = PlanMigration.migrate(legacy, assetsDirectory: nil)
        XCTAssertEqual(result.tracks[0].elements.count, 1, "无 source 时回落旧 range")
        XCTAssertEqual(result.tracks[0].elements[0].duration, 3, accuracy: 0.001)
        XCTAssertTrue(result.notices.isEmpty)
    }

    func testStillClipPassesThrough() throws {
        let json = """
        {
          "version": 3,
          "assets": [{"id":"AAAAAAAA-0000-0000-0000-000000000001","kind":"image","fileName":"still.png"}],
          "clips": [{"id":"11111111-1111-1111-1111-111111111111","assetID":"AAAAAAAA-0000-0000-0000-000000000001","source":{"type":"still","duration":3}}]
        }
        """
        let legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: Data(json.utf8))
        let result = PlanMigration.migrate(legacy, assetsDirectory: nil)
        XCTAssertEqual(result.tracks[0].elements.count, 1)
        XCTAssertEqual(result.tracks[0].elements[0].duration, 3, accuracy: 0.001)
        XCTAssertTrue(result.notices.isEmpty)
    }

    func testClipWithoutSourceIsDroppedAndReported() throws {
        let json = """
        {
          "version": 3,
          "assets": [{"id":"AAAAAAAA-0000-0000-0000-000000000001","kind":"video","fileName":"clip1.mp4"}],
          "clips": [{"id":"11111111-1111-1111-1111-111111111111","assetID":"AAAAAAAA-0000-0000-0000-000000000001"}]
        }
        """
        let legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: Data(json.utf8))
        let result = PlanMigration.migrate(legacy, assetsDirectory: nil)
        XCTAssertEqual(result.tracks[0].elements.count, 0, "无 source 也无 range → 丢弃，不造零长畸形片段")
        XCTAssertEqual(result.notices,
                       [.clipSourceMissing(clipID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)])
    }
}
