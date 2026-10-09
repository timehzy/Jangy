import XCTest
@testable import POCCore

/// DraftStore 落盘/恢复/schema 守卫/完整性校验。
final class DraftStoreTests: XCTestCase {

    private var workDir: URL!
    private var libraryDir: URL!
    private var store: DraftStore!
    private var resolver: AssetResolver!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        libraryDir = workDir.appendingPathComponent("Library")
        // 合成全套样例素材（clip1/2/3.mp4 + sample.srt），与 SamplePlan 登记表一致
        resolver = try AssetSynthesizer.synthesize(into: libraryDir)
        store = DraftStore(directory: libraryDir)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        libraryDir = nil
        store = nil
        resolver = nil
    }

    func testSaveLoadRoundTrip() throws {
        let plan = SamplePlan.make()
        try store.save(plan: plan)
        XCTAssertEqual(try store.load(), plan)
    }

    func testRepeatedSavesAreByteIdentical() throws {
        let plan = SamplePlan.make()
        try store.save(plan: plan)
        let first = try Data(contentsOf: store.fileURL)
        try store.save(plan: plan)
        let second = try Data(contentsOf: store.fileURL)
        XCTAssertEqual(first, second, "sortedKeys 格式下未变更的两次保存应字节一致")
    }

    func testLoadReturnsNilWhenNoDraft() throws {
        let empty = DraftStore(directory: workDir.appendingPathComponent("Empty"))
        XCTAssertNil(try empty.load())
        XCTAssertFalse(empty.exists)
    }

    func testSchemaGuardRejectsNewerVersion() throws {
        var plan = SamplePlan.make()
        plan.version = DraftStore.currentSchemaVersion + 1
        try store.save(plan: plan)

        XCTAssertThrowsError(try store.load()) { error in
            guard case DraftError.unsupportedVersion(let found, let supported) = error else {
                return XCTFail("应抛 unsupportedVersion，实际: \(error)")
            }
            XCTAssertEqual(found, DraftStore.currentSchemaVersion + 1)
            XCTAssertEqual(supported, DraftStore.currentSchemaVersion)
        }
    }

    func testLoadCorruptedFileThrowsPlanLoaderError() throws {
        try Data(#"{"clips": "not-an-array"}"#.utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load()) { error in
            guard case PlanLoaderError.decodingFailed(let path, _) = error else {
                return XCTFail("应抛 PlanLoaderError.decodingFailed，实际: \(error)")
            }
            XCTAssertEqual(path, "clips", "错误应带字段路径翻译")
        }
    }

    func testFailedSaveKeepsPreviousDraftIntact() throws {
        let plan = SamplePlan.make()
        try store.save(plan: plan)
        let before = try Data(contentsOf: store.fileURL)

        // 目录只读 → 原子写入失败；旧草稿必须完好
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: libraryDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: libraryDir.path) }

        var mutated = plan
        mutated.clips.removeAll()
        XCTAssertThrowsError(try store.save(plan: mutated))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before, "写入失败不得破坏旧草稿")
    }

    func testVerifyCleanForSamplePlan() async throws {
        let report = await store.verify(plan: SamplePlan.make(), resolver: resolver)
        XCTAssertTrue(report.isEmpty, "样例工程对合成素材应零缺失零漂移，实际: \(report.summary)")
    }

    func testVerifyReportsMissingAsset() async throws {
        try FileManager.default.removeItem(at: libraryDir.appendingPathComponent("clip2.mp4"))
        let report = await store.verify(plan: SamplePlan.make(), resolver: resolver)
        XCTAssertEqual(report.missing.map(\.fileName), ["clip2.mp4"])
        XCTAssertTrue(report.drifted.isEmpty)
        XCTAssertTrue(report.summary.contains("clip2.mp4"))
    }

    func testVerifyReportsMetadataDrift() async throws {
        var plan = SamplePlan.make()
        // 篡改登记表：clip1 登记时长 4s → 9.9s，分辨率 1280 → 999
        plan.assets[0].duration = 9.9
        plan.assets[0].pixelWidth = 999

        let report = await store.verify(plan: plan, resolver: resolver)
        XCTAssertTrue(report.missing.isEmpty)
        XCTAssertEqual(report.drifted.count, 2)
        XCTAssertEqual(Set(report.drifted.map(\.field)), ["duration", "pixelWidth"])
        XCTAssertTrue(report.drifted.allSatisfy { $0.fileName == "clip1.mp4" })
    }

    func testDeleteRemovesDraft() throws {
        try store.save(plan: SamplePlan.make())
        XCTAssertTrue(store.exists)
        try store.delete()
        XCTAssertFalse(store.exists)
        XCTAssertNil(try store.load())
    }
}
