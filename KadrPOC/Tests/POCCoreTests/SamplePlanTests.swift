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

    func testSynthesizeProducesAssets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resolver = try AssetSynthesizer.synthesize(into: dir)
        for name in AssetSynthesizer.clipFileNames {
            XCTAssertTrue(resolver.exists(MediaRef(fileName: name)), "\(name) 应已生成")
        }
        XCTAssertTrue(resolver.exists(MediaRef(fileName: AssetSynthesizer.srtFileName)))
        // 生成后素材存在性校验应通过
        XCTAssertTrue(EditPlanValidator().validateAssets(SamplePlan.make(), resolver: resolver).isEmpty)
    }
}
