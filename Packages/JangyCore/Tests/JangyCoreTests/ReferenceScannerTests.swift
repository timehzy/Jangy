import XCTest
@testable import JangyCore
@testable import JangyTestSupport

/// 引用扫描：assetID → 引用它的项目集。素材侧不存反向数据，用到时扫。
final class ReferenceScannerTests: XCTestCase {

    private var root: URL!
    private var store: ProjectStore!
    private var scanner: ReferenceScanner!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(root: root)
        scanner = ReferenceScanner(projectStore: store)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil; store = nil; scanner = nil
    }

    func testScanCollectsAssetReferences() throws {
        let a = try store.createProject(name: "A")
        let b = try store.createProject(name: "B")
        try store.saveProject(id: a.id, plan: SamplePlan.make())
        try store.saveProject(id: b.id, plan: EditPlan(clips: []))

        let refs = try scanner.scan()
        // SamplePlan 的全部素材都引用自项目 A；空项目 B 不产生任何条目
        for asset in SamplePlan.make().assets {
            XCTAssertEqual(refs[asset.id], Set([a.id]))
        }
        XCTAssertFalse(refs.values.contains { $0.contains(b.id) })
    }

    func testInMemoryPlanOverridesDisk() throws {
        let a = try store.createProject(name: "A")
        try store.saveProject(id: a.id, plan: SamplePlan.make())
        // 内存 plan 已是空时间线（未落盘）：扫描应以内存为准
        let refs = try scanner.scan(currentProjectID: a.id, currentPlan: EditPlan(clips: []))
        XCTAssertTrue(refs.isEmpty, "当前项目的未落盘编辑要参与扫描")
    }

    func testCorruptProjectFailsScan() throws {
        let a = try store.createProject(name: "A")
        // 写坏 project.json
        try Data("not json".utf8).write(to: store.projectDirectory(id: a.id)
            .appendingPathComponent(ProjectStore.planFileName))
        XCTAssertThrowsError(try scanner.scan()) { error in
            guard case ReferenceScanError.corruptProject(let id) = error else {
                return XCTFail("应抛 corruptProject，实际: \(error)")
            }
            XCTAssertEqual(id, a.id)
        }
    }
}
