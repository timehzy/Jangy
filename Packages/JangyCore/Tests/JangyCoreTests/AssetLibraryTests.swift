import XCTest
@testable import JangyCore
@testable import JangyTestSupport

/// 全局素材库登记表：library.json 读写、哈希去重入库、删除清理、一致性校验。
final class AssetLibraryTests: XCTestCase {

    private var root: URL!
    private var library: AssetLibrary!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = AssetLibrary(root: root)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        library = nil
    }

    private func makeTempVideo() throws -> URL {
        // 复用测试素材合成器产物做导入源：合成产物字节不定（mp4 容器含写入时间），
        // 同一源文件拷贝两份才能保证内容一致、触发哈希去重路径；
        // 拷贝到独立临时文件是因为 importFile 是 move 语义
        let sourceDir = root.appendingPathComponent("synth")
        _ = try AssetSynthesizer.synthesize(into: sourceDir)
        let source = sourceDir.appendingPathComponent(AssetSynthesizer.clipFileNames[0])
        let tempDir = root.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let temp = tempDir.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: temp)
        return temp
    }

    func testEmptyLibraryLoadsEmpty() throws {
        XCTAssertEqual(try library.load(), [])
    }

    func testImportRegistersAndSaves() async throws {
        let source = try makeTempVideo()
        let (item, isNew) = try await library.importFile(from: source, kind: .video, origin: .files)
        XCTAssertTrue(isNew)
        XCTAssertEqual(try library.load(), [item])
        XCTAssertTrue(library.resolver.exists(item))
    }

    func testDuplicateContentReusesExistingEntry() async throws {
        let first = try await library.importFile(from: makeTempVideo(), kind: .video, origin: .files)
        let second = try await library.importFile(from: makeTempVideo(), kind: .video, origin: .files)
        XCTAssertTrue(first.isNew)
        XCTAssertFalse(second.isNew)
        XCTAssertEqual(first.item.id, second.item.id, "同内容复用同一 assetID")
        XCTAssertEqual(try library.load().count, 1, "登记表不重复")
        let files = try FileManager.default.contentsOfDirectory(atPath: library.assetsDir.path)
        XCTAssertEqual(files.count, 1, "磁盘只占一份")
    }

    func testRemoveCleansRegistryAndFile() async throws {
        let (item, _) = try await library.importFile(from: makeTempVideo(), kind: .video, origin: .files)
        try library.remove(ids: [item.id])
        XCTAssertEqual(try library.load(), [])
        XCTAssertFalse(library.resolver.exists(item))
    }

    func testVerifyReportsMissingAndUnregistered() async throws {
        let (item, _) = try await library.importFile(from: makeTempVideo(), kind: .video, origin: .files)
        // 手删磁盘文件 → missing；丢一个未登记文件 → unregistered
        try FileManager.default.removeItem(at: library.resolver.resolve(item))
        try Data("orphan".utf8).write(to: library.assetsDir.appendingPathComponent("orphan.bin"))
        let report = try library.verify()
        XCTAssertEqual(report.missingFiles.map(\.id), [item.id])
        XCTAssertEqual(report.unregisteredFiles, ["orphan.bin"])
        XCTAssertFalse(report.isEmpty)
    }
}
