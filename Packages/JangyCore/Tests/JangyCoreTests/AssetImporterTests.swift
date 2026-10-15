import XCTest
import AVFoundation
@testable import JangyCore
@testable import JangyTestSupport

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
                            clips: [PlanClip(assetID: item.id, source: .video(0...(item.duration ?? 0)))])
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

/// importMedia 泛化入库：三类素材的元数据探测 + sha256 登记。
final class AssetImporterMediaTests: XCTestCase {

    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    /// 最小合法 PNG（1x1 红点），CGImageSource 可读尺寸
    private func makePNG() throws -> URL {
        let url = workDir.appendingPathComponent("pixel.png")
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        try data.write(to: url)
        return url
    }

    /// 最小 WAV（PCM 头 + 0.5 秒 8kHz 单声道静音）
    private func makeWAV() throws -> URL {
        let url = workDir.appendingPathComponent("tone.wav")
        let sampleRate: UInt32 = 8000
        let samples = Int(sampleRate / 2)
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLE(UInt32(36 + samples))
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.appendLE(UInt32(16))          // fmt 块长
        data.appendLE(UInt16(1))           // PCM
        data.appendLE(UInt16(1))           // 单声道
        data.appendLE(sampleRate)
        data.appendLE(sampleRate)          // byteRate = rate * 1 * 1
        data.appendLE(UInt16(1))           // blockAlign
        data.appendLE(UInt16(8))           // 8bit
        data.append(contentsOf: "data".utf8)
        data.appendLE(UInt32(samples))
        data.append(Data(repeating: 128, count: samples))  // 8bit PCM 静音 = 128
        try data.write(to: url)
        return url
    }

    func testImportImageProbesPixelSize() async throws {
        let source = try makePNG()
        let importer = AssetImporter(directory: workDir.appendingPathComponent("Assets"))
        let item = try await importer.importMedia(from: source, kind: .image, origin: .files)
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.pixelWidth, 1)
        XCTAssertEqual(item.pixelHeight, 1)
        XCTAssertNil(item.duration)
        XCTAssertNotNil(item.sha256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: importer.directory.appendingPathComponent(item.fileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "move 语义：源文件不留残余")
    }

    func testImportAudioProbesDuration() async throws {
        let source = try makeWAV()
        let importer = AssetImporter(directory: workDir.appendingPathComponent("Assets"))
        let item = try await importer.importMedia(from: source, kind: .audio, origin: .files)
        XCTAssertEqual(item.kind, .audio)
        XCTAssertEqual(item.duration ?? 0, 0.5, accuracy: 0.05)
        XCTAssertNotNil(item.sha256)
    }

    func testImportMediaComputesSHA256UnlessKnown() async throws {
        let source = try makePNG()
        let importer = AssetImporter(directory: workDir.appendingPathComponent("Assets"))
        let item = try await importer.importMedia(from: source, kind: .image, origin: .files,
                                                  knownSHA256: "preset-hash")
        XCTAssertEqual(item.sha256, "preset-hash", "调用方已算好哈希时不重复读盘")
    }
}

/// Data 小端追加助手（WAV 头构造用）
private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: MemoryLayout<T>.size))
    }
}
