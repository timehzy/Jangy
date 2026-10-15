import XCTest
@testable import JangyCore
@testable import JangyTestSupport

/// 工程包：导出 → 导入往返等价、assetID 冲突改写、哈希去重、原子性。
final class ProjectPackageTests: XCTestCase {

    private var root: URL!
    private var store: ProjectStore!
    private var library: AssetLibrary!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(root: root)
        library = AssetLibrary(root: root)
        // 素材入库（SamplePlan 引用的 clip1/2/3.mp4 + sample.srt）
        let srcDir = root.appendingPathComponent("src")
        _ = try AssetSynthesizer.synthesize(into: srcDir)
        let plan = SamplePlan.make()
        for asset in plan.assets {
            let temp = root.appendingPathComponent("tmp-\(asset.fileName)")
            try FileManager.default.copyItem(at: srcDir.appendingPathComponent(asset.fileName), to: temp)
            _ = try await library.importFile(from: temp, kind: asset.kind, origin: asset.origin)
        }
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil; store = nil; library = nil
    }

    /// 素材已入库后造一个引用它们的项目
    private func makeProject(name: String) throws -> ProjectSummary {
        let summary = try store.createProject(name: name)
        let libraryItems = try library.load()
        // setUp 按 plan.assets 顺序导入；入库后 fileName 变成 UUID 名，
        // 按 kind + 未占用顺序对应回原素材
        var plan = SamplePlan.make()
        var used: Set<UUID> = []
        var idMap: [UUID: UUID] = [:]
        for (index, asset) in plan.assets.enumerated() {
            let lib = libraryItems.first { $0.kind == asset.kind && !used.contains($0.id) }!
            used.insert(lib.id)
            idMap[asset.id] = lib.id
            plan.assets[index] = lib
        }
        plan.clips = plan.clips.map { PlanClip(id: $0.id, assetID: idMap[$0.assetID]!,
                                               source: $0.source, speed: $0.speed,
                                               transitionAfter: $0.transitionAfter) }
        if let captions = plan.captions {
            plan.captions = CaptionTrack(assetID: idMap[captions.assetID]!,
                                         isEnabled: captions.isEnabled, style: captions.style)
        }
        try store.saveProject(id: summary.id, plan: plan)
        return summary
    }

    func testExportImportRoundTrip() async throws {
        let project = try makeProject(name: "我的项目")
        let zip = root.appendingPathComponent("out.jangyproj.zip")
        try ProjectPackage.export(projectID: project.id, from: store,
                                  library: library, resolver: library.resolver, to: zip)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))

        let expectedPlan = try store.loadProject(id: project.id)
        let imported = try await ProjectPackage.import(from: zip, into: store, library: library)
        XCTAssertEqual(imported.name, "我的项目 2", "名称冲突加后缀")
        XCTAssertEqual(try store.loadProject(id: imported.id), expectedPlan,
                       "同库导入：素材哈希全部命中，plan 引用不变")
    }

    func testImportIntoFreshEnvironment() async throws {
        let project = try makeProject(name: "P")
        let zip = root.appendingPathComponent("out.jangyproj.zip")
        try ProjectPackage.export(projectID: project.id, from: store,
                                  library: library, resolver: library.resolver, to: zip)

        // 全新环境（另一个 root）
        let root2 = root.appendingPathComponent("env2")
        try FileManager.default.createDirectory(at: root2, withIntermediateDirectories: true)
        let store2 = ProjectStore(root: root2)
        let library2 = AssetLibrary(root: root2)
        let imported = try await ProjectPackage.import(from: zip, into: store2, library: library2)
        let plan = try store2.loadProject(id: imported.id)
        let registry = try library2.load()
        XCTAssertEqual(registry.count, plan.assets.count, "素材全部入库")
        for clip in plan.clips {
            XCTAssertTrue(registry.contains { $0.id == clip.assetID }, "clip 引用有效")
        }
        for asset in plan.assets {
            XCTAssertTrue(library2.resolver.exists(asset), "素材文件已落盘")
        }
    }

    func testDoubleImportDoesNotDuplicateAssets() async throws {
        let project = try makeProject(name: "P")
        let zip = root.appendingPathComponent("out.jangyproj.zip")
        try ProjectPackage.export(projectID: project.id, from: store,
                                  library: library, resolver: library.resolver, to: zip)
        let before = try library.load().count
        _ = try await ProjectPackage.import(from: zip, into: store, library: library)
        XCTAssertEqual(try library.load().count, before, "同内容素材不重复入库")
        let fileCount = try FileManager.default.contentsOfDirectory(atPath: library.assetsDir.path).count
        XCTAssertEqual(fileCount, before, "磁盘文件不重复")
    }

    func testExportFailsOnMissingAsset() throws {
        let project = try makeProject(name: "P")
        // 删掉一个被引用的素材文件
        let plan = try store.loadProject(id: project.id)
        try FileManager.default.removeItem(at: library.resolver.resolve(plan.assets[0]))
        XCTAssertThrowsError(try ProjectPackage.export(projectID: project.id, from: store,
                                                       library: library, resolver: library.resolver,
                                                       to: root.appendingPathComponent("x.zip"))) { error in
            guard case ProjectPackageError.missingAssetFile = error else {
                return XCTFail("应抛 missingAssetFile，实际: \(error)")
            }
        }
    }

    func testImportRejectsCorruptPackage() async throws {
        let junk = root.appendingPathComponent("junk.jangyproj.zip")
        try Data("not a zip".utf8).write(to: junk)
        await XCTAssertAsyncThrowsError(try await ProjectPackage.import(from: junk, into: store, library: library))
        XCTAssertEqual(try store.listProjects().count, 0, "失败不产生半成品项目")
    }

    func testImportRejectsNewerPlanVersion() async throws {
        let project = try makeProject(name: "P")
        let zip = root.appendingPathComponent("out.jangyproj.zip")
        try ProjectPackage.export(projectID: project.id, from: store,
                                  library: library, resolver: library.resolver, to: zip)

        // 解开 → 抬高 plan.version 一级 → 重新打包（formatVersion 合法但 plan 超纲）
        let staging = root.appendingPathComponent("staging")
        try ZipArchive.unzip(zip, into: staging)
        let planURL = staging.appendingPathComponent(ProjectStore.planFileName)
        var plan = try PlanLoader.load(from: planURL)
        plan.version = ProjectStore.currentSchemaVersion + 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(plan).write(to: planURL)
        let tampered = root.appendingPathComponent("tampered.jangyproj.zip")
        try ZipArchive.zip(contentsOf: staging, to: tampered)

        let registryBefore = try library.load()
        await XCTAssertAsyncThrowsError(try await ProjectPackage.import(from: tampered, into: store, library: library)) { error in
            guard case ProjectStoreError.unsupportedVersion = error else {
                return XCTFail("应抛 unsupportedVersion，实际: \(error)")
            }
        }
        XCTAssertEqual(try store.listProjects().count, 1, "失败不产生半成品项目（仅剩原有项目）")
        XCTAssertEqual(try library.load(), registryBefore, "登记表不变")
    }
}

/// XCTest 无原生 async throws 断言，补一个
func XCTAssertAsyncThrowsError(_ expression: @autoclosure () async throws -> some Any,
                               file: StaticString = #filePath, line: UInt = #line,
                               _ errorHandler: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail("应抛错", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
