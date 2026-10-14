import XCTest
@testable import JangyCore

/// SHA-256 流式哈希 + AssetItem.sha256 字段编解码。
final class AssetHasherTests: XCTestCase {

    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    func testSHA256KnownVector() throws {
        // "abc" 的 SHA-256 是公开测试向量
        let file = workDir.appendingPathComponent("a.bin")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try AssetHasher.sha256(of: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSHA256MatchesAcrossIdenticalContent() throws {
        let a = workDir.appendingPathComponent("a.bin")
        let b = workDir.appendingPathComponent("b.bin")
        let content = Data((0..<5000).map { UInt8($0 % 251) })
        try content.write(to: a)
        try content.write(to: b)
        XCTAssertEqual(try AssetHasher.sha256(of: a), try AssetHasher.sha256(of: b))
    }

    func testAssetItemSHA256RoundTrip() throws {
        let item = AssetItem(kind: .video, fileName: "x.mp4", sha256: "deadbeef")
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(AssetItem.self, from: data), item)
    }

    func testAssetItemDecodesWithoutSHA256() throws {
        // 旧格式 JSON（无 sha256 字段）解码为 nil，向后兼容
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","kind":"video","fileName":"x.mp4"}"#
        let item = try JSONDecoder().decode(AssetItem.self, from: Data(json.utf8))
        XCTAssertNil(item.sha256)
    }
}
