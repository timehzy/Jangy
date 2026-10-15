import XCTest
@testable import JangyCore
@testable import JangyTestSupport

/// ProjectStore：项目 CRUD / 列表扫描 / 版本守卫 / 完整性校验 / 旧布局迁移。
final class ProjectStoreTests: XCTestCase {

    private var root: URL!
    private var store: ProjectStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(root: root)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        store = nil
    }

    func testCreateAndLoadRoundTrip() throws {
        let summary = try store.createProject(name: "测试项目")
        XCTAssertEqual(summary.name, "测试项目")
        XCTAssertEqual(try store.loadProject(id: summary.id), EditPlan(clips: []))
        XCTAssertEqual(try store.loadMeta(id: summary.id).name, "测试项目")
    }

    func testSaveLoadPlanRoundTrip() throws {
        let summary = try store.createProject(name: "A")
        let plan = SamplePlan.make()
        try store.saveProject(id: summary.id, plan: plan)
        XCTAssertEqual(try store.loadProject(id: summary.id), plan)
    }

    func testRepeatedSavesAreByteIdentical() throws {
        let summary = try store.createProject(name: "A")
        let plan = SamplePlan.make()
        try store.saveProject(id: summary.id, plan: plan)
        let url = store.projectDirectory(id: summary.id).appendingPathComponent(ProjectStore.planFileName)
        let first = try Data(contentsOf: url)
        try store.saveProject(id: summary.id, plan: plan)
        XCTAssertEqual(first, try Data(contentsOf: url), "sortedKeys 格式下未变更的两次保存应字节一致")
    }

    func testSchemaGuardRejectsNewerVersion() throws {
        let summary = try store.createProject(name: "A")
        // 直接写一个「更新版本」的文件（模拟更新版 App 产出）；不走 saveProject——它会归一化版本
        var plan = EditPlan(clips: [])
        plan.version = ProjectStore.currentSchemaVersion + 1
        let url = store.projectDirectory(id: summary.id).appendingPathComponent(ProjectStore.planFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(plan).write(to: url)
        XCTAssertThrowsError(try store.loadProject(id: summary.id)) { error in
            guard case ProjectStoreError.unsupportedVersion(let found, _) = error else {
                return XCTFail("应抛 unsupportedVersion，实际: \(error)")
            }
            XCTAssertEqual(found, ProjectStore.currentSchemaVersion + 1)
        }
    }

    func testListProjectsSortedByModifiedDesc() throws {
        let a = try store.createProject(name: "A")
        let b = try store.createProject(name: "B")
        // 触碰 A 使其修改时间更新
        try store.saveProject(id: a.id, plan: EditPlan(clips: []))
        let names = try store.listProjects().map(\.name)
        XCTAssertEqual(names, ["A", "B"], "修改时间倒序；同秒精度下后写入的 A 在前")
        _ = b
    }

    func testUniqueName() throws {
        _ = try store.createProject(name: "未命名项目")
        _ = try store.createProject(name: store.uniqueName(base: "未命名项目"))
        let names = try store.listProjects().map(\.name)
        XCTAssertTrue(names.contains("未命名项目"))
        XCTAssertTrue(names.contains("未命名项目 2"))
    }

    func testRename() throws {
        let summary = try store.createProject(name: "旧名")
        try store.renameProject(id: summary.id, to: "新名")
        XCTAssertEqual(try store.loadMeta(id: summary.id).name, "新名")
    }

    func testDuplicateCopiesPlanNotAssets() throws {
        let summary = try store.createProject(name: "原始")
        try store.saveProject(id: summary.id, plan: SamplePlan.make())
        let copy = try store.duplicateProject(id: summary.id)
        XCTAssertEqual(copy.name, "原始 副本")
        XCTAssertEqual(try store.loadProject(id: copy.id), SamplePlan.make(), "plan 深拷贝（引用语义下无需拷素材）")
        XCTAssertNotEqual(copy.id, summary.id)
    }

    func testDelete() throws {
        let summary = try store.createProject(name: "A")
        try store.deleteProject(id: summary.id)
        XCTAssertEqual(try store.listProjects(), [])
        XCTAssertThrowsError(try store.loadProject(id: summary.id))
    }

    func testVerifyReportsMissingAsset() async throws {
        let summary = try store.createProject(name: "A")
        let plan = SamplePlan.make()  // 引用 clip1/2/3.mp4 + sample.srt，但 Assets 目录为空
        let report = await store.verify(plan: plan, resolver: AssetLibrary(root: root).resolver)
        XCTAssertEqual(report.missing.count, plan.assets.count)
        XCTAssertFalse(report.isEmpty)
        _ = summary
    }

    /// 旧布局迁移：draft.json → Projects/<uuid>/project.json；散落素材 → Assets/；
    /// library.json 从迁移项目的 plan.assets 播种（含 sha256 计算）。
    func testMigrateLegacyLayout() async throws {
        // 摆出旧布局：draft.json + 散落素材文件 + agent-config.json 同级
        let plan = SamplePlan.make()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(plan).write(to: root.appendingPathComponent("draft.json"))
        _ = try AssetSynthesizer.synthesize(into: root)  // 素材直接散落 root（旧布局）
        try Data("{}".utf8).write(to: root.appendingPathComponent("agent-config.json"))

        let migrated = try store.migrateLegacyLayoutIfNeeded()
        XCTAssertTrue(migrated)

        // draft.json 消失，项目出现
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("draft.json").path))
        let projects = try store.listProjects()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].name, "未命名项目")
        XCTAssertEqual(try store.loadProject(id: projects[0].id), plan)

        // 素材进 Assets/，agent-config.json 原地不动
        let library = AssetLibrary(root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.assetsDir.appendingPathComponent("clip1.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("agent-config.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("clip1.mp4").path))

        // library.json 从迁移项目播种
        let registry = try library.load()
        XCTAssertEqual(Set(registry.map(\.id)), Set(plan.assets.map(\.id)))

        // 幂等：再跑一遍无变化
        XCTAssertFalse(try store.migrateLegacyLayoutIfNeeded())
    }

    /// 旧版本 plan 落盘后应标记为当前版本（防「旧版本号 + 新格式」混搭）。
    func testSaveNormalizesLegacyVersionToCurrent() throws {
        let summary = try store.createProject(name: "A")
        var legacy = SamplePlan.make()
        legacy.version = 2
        try store.saveProject(id: summary.id, plan: legacy)
        let url = store.projectDirectory(id: summary.id).appendingPathComponent(ProjectStore.planFileName)
        XCTAssertEqual(try PlanLoader.load(from: url).version, ProjectStore.currentSchemaVersion)
    }
}
