import XCTest
@testable import POCCore

final class SamplePlanTests: XCTestCase {

    /// 黄金契约：Agent 手写/LLM 生成的 JSON 必须能解码为与 SamplePlan.make() 完全相等的模型。
    /// 方向是 外部 JSON → 模型，这正是 Agent 场景的消费方向。
    func testGoldenJSONDecodesToSamplePlan() throws {
        let fixtureURL = Bundle.module.url(forResource: "SamplePlan.golden", withExtension: "json", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: fixtureURL)
        let decoded = try JSONDecoder().decode(EditPlan.self, from: data)
        XCTAssertEqual(decoded, SamplePlan.make())
    }

    func testSamplePlanIsValid() {
        XCTAssertTrue(EditPlanValidator().validate(SamplePlan.make()).isEmpty)
    }

    /// 样例工程的 clip/字幕引用必须全部落在素材登记表里（v2 引用完整性）。
    func testSamplePlanReferencesResolve() {
        let plan = SamplePlan.make()
        for clip in plan.clips {
            XCTAssertNotNil(plan.asset(withID: clip.assetID), "clip \(clip.id) 引用了未登记素材")
        }
        XCTAssertNotNil(plan.asset(withID: plan.captions!.assetID))
    }

    func testSynthesizeProducesAssets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resolver = try AssetSynthesizer.synthesize(into: dir)
        for name in AssetSynthesizer.clipFileNames {
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolver.resolve(fileName: name).path), "\(name) 应已生成")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolver.resolve(fileName: AssetSynthesizer.srtFileName).path))
        // 生成后素材存在性校验应通过（登记表 4 个条目全部落盘）
        XCTAssertTrue(EditPlanValidator().validateAssets(SamplePlan.make(), resolver: resolver).isEmpty)
    }
}
