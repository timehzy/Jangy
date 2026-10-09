import XCTest
import AVFoundation
@testable import POCCore

/// AssetImporter 入库链路：move 落盘 + 元数据探测 + 登记项生成。
final class AssetImporterTests: XCTestCase {

    private var workDir: URL!
    private var libraryDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        libraryDir = workDir.appendingPathComponent("Library")
        // 源素材目录：合成一段 clip1.mp4 作为「picker 导出的临时文件」替身
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        _ = try AssetSynthesizer.synthesize(into: workDir.appendingPathComponent("Source"))
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        libraryDir = nil
    }

    func testImportMovesFileAndProbesMetadata() async throws {
        let source = workDir.appendingPathComponent("Source/clip1.mp4")
        let importer = AssetImporter(directory: libraryDir)
        let item = try await importer.importVideo(from: source, origin: .photoLibrary,
                                                  displayName: "实拍素材")

        // move 语义：源文件消失，库目录出现 UUID 命名的新文件
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let resolved = AssetResolver(directory: libraryDir).resolve(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
        XCTAssertTrue(item.fileName.hasSuffix(".mp4"))
        XCTAssertNotEqual(item.fileName, "clip1.mp4", "入库应 UUID 重命名防冲突")

        // 元数据探测：与 AssetSynthesizer 产物规格一致（4s 1280x720 无音频）
        XCTAssertEqual(item.kind, .video)
        XCTAssertEqual(item.origin, .photoLibrary)
        XCTAssertEqual(item.displayName, "实拍素材")
        XCTAssertEqual(item.duration ?? 0, 4.0, accuracy: 0.1)
        XCTAssertEqual(item.pixelWidth, 1280)
        XCTAssertEqual(item.pixelHeight, 720)
        XCTAssertEqual(item.hasAudio, false)
        XCTAssertNotNil(item.importedAt)
    }

    func testDisplayNameDefaultsToSourceFileName() async throws {
        let source = workDir.appendingPathComponent("Source/clip2.mp4")
        let item = try await AssetImporter(directory: libraryDir).importVideo(from: source, origin: .files)
        XCTAssertEqual(item.displayName, "clip2")
    }

    func testImportResultPassesValidation() async throws {
        let source = workDir.appendingPathComponent("Source/clip3.mp4")
        let importer = AssetImporter(directory: libraryDir)
        let item = try await importer.importVideo(from: source, origin: .photoLibrary)
        let plan = EditPlan(assets: [item],
                            clips: [PlanClip(assetID: item.id, range: 0...(item.duration ?? 0))])
        XCTAssertTrue(EditPlanValidator().validate(plan).isEmpty)
        XCTAssertTrue(EditPlanValidator().validateAssets(plan, resolver: AssetResolver(directory: libraryDir)).isEmpty)
    }

    func testMissingSourceThrows() async {
        let importer = AssetImporter(directory: libraryDir)
        do {
            _ = try await importer.importVideo(from: workDir.appendingPathComponent("nope.mp4"),
                                               origin: .files)
            XCTFail("源文件不存在应抛错")
        } catch {}
    }
}
