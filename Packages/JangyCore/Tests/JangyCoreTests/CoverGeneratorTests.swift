import XCTest
@testable import JangyCore
@testable import JangyTestSupport

/// 项目封面：第一片段素材首帧 → JPEG。
final class CoverGeneratorTests: XCTestCase {

    private var workDir: URL!
    private var resolver: AssetResolver!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        resolver = try AssetSynthesizer.synthesize(into: workDir.appendingPathComponent("Assets"))
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil; resolver = nil
    }

    func testGeneratesCoverForFirstClip() async throws {
        let cover = workDir.appendingPathComponent("cover.jpg")
        await CoverGenerator.generate(for: SamplePlan.make(), resolver: resolver, to: cover)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cover.path))
        let data = try Data(contentsOf: cover)
        XCTAssertTrue(data.starts(with: [0xFF, 0xD8]), "应为 JPEG（FFD8 魔数）")
    }

    func testEmptyPlanRemovesCover() async throws {
        let cover = workDir.appendingPathComponent("cover.jpg")
        try Data("old".utf8).write(to: cover)
        await CoverGenerator.generate(for: EditPlan(clips: []), resolver: resolver, to: cover)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cover.path), "空时间线清掉旧封面")
    }

    func testGeneratesCoverForImageClip() async throws {
        // 首个片段是图片：封面应直接来自图片（不依赖 AVAssetImageGenerator）
        let imageURL = workDir.appendingPathComponent("Assets").appendingPathComponent(AssetSynthesizer.imageFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path), "合成器应生成图片")

        let asset = AssetItem(kind: .image, fileName: AssetSynthesizer.imageFileName,
                              origin: .synthesized, pixelWidth: 640, pixelHeight: 360)
        let plan = EditPlan(assets: [asset], clips: [PlanClip(assetID: asset.id, source: .still(duration: 3.0))])
        let cover = workDir.appendingPathComponent("cover-img.jpg")
        await CoverGenerator.generate(for: plan, resolver: resolver, to: cover)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cover.path))
        XCTAssertTrue(try Data(contentsOf: cover).starts(with: [0xFF, 0xD8]), "应为 JPEG")
    }
}
