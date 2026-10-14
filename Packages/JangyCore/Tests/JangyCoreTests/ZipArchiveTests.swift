import XCTest
@testable import JangyCore

/// store-only ZIP 读写：round-trip 字节一致、嵌套目录、zip slip 防护。
final class ZipArchiveTests: XCTestCase {

    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    func testRoundTrip() throws {
        let src = workDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("assets"),
                                                withIntermediateDirectories: true)
        let files: [(String, Data)] = [
            ("project.json", Data(#"{"clips":[]}"#.utf8)),
            ("assets/a.mp4", Data((0..<3000).map { UInt8($0 % 241) })),
            ("assets/b.jpg", Data("jpeg-bytes".utf8)),
        ]
        for (name, data) in files {
            try data.write(to: src.appendingPathComponent(name))
        }

        let zip = workDir.appendingPathComponent("pkg.zip")
        try ZipArchive.zip(contentsOf: src, to: zip)

        let dst = workDir.appendingPathComponent("dst")
        try ZipArchive.unzip(zip, into: dst)

        for (name, data) in files {
            XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent(name)), data,
                           "\(name) round-trip 应字节一致")
        }
    }

    func testRejectsTruncatedArchive() throws {
        let src = workDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data((0..<2000).map { UInt8($0 % 251) }).write(to: src.appendingPathComponent("big.bin"))

        let zip = workDir.appendingPathComponent("pkg.zip")
        try ZipArchive.zip(contentsOf: src, to: zip)
        let full = try Data(contentsOf: zip)
        let truncated = zip.deletingLastPathComponent().appendingPathComponent("truncated.zip")
        try full.prefix(full.count / 2).write(to: truncated)

        XCTAssertThrowsError(try ZipArchive.unzip(truncated, into: workDir.appendingPathComponent("out"))) { error in
            guard case ZipArchive.ZipError.malformedArchive = error else {
                return XCTFail("应抛 malformedArchive，实际: \(error)")
            }
        }
    }

    func testRejectsZipSlip() throws {
        // 手工构造一个条目名为 "../evil" 的最小 zip（store 方法）
        let name = "../evil"
        let payload = Data("x".utf8)
        let crc = ZipArchive.crc32(payload)
        var zip = Data()
        // local file header
        zip.appendLE(UInt32(0x04034b50)); zip.appendLE(UInt16(20)); zip.appendLE(UInt16(0))
        zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
        zip.appendLE(crc); zip.appendLE(UInt32(payload.count)); zip.appendLE(UInt32(payload.count))
        zip.appendLE(UInt16(name.utf8.count)); zip.appendLE(UInt16(0))
        zip.append(contentsOf: name.utf8); zip.append(payload)
        let centralOffset = UInt32(zip.count)
        // central directory
        zip.appendLE(UInt32(0x02014b50)); zip.appendLE(UInt16(20)); zip.appendLE(UInt16(20))
        zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
        zip.appendLE(crc); zip.appendLE(UInt32(payload.count)); zip.appendLE(UInt32(payload.count))
        zip.appendLE(UInt16(name.utf8.count)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
        zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0)); zip.appendLE(UInt32(0)); zip.appendLE(UInt32(0))
        zip.append(contentsOf: name.utf8)
        // EOCD
        zip.appendLE(UInt32(0x06054b50)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
        zip.appendLE(UInt16(1)); zip.appendLE(UInt16(1))
        zip.appendLE(UInt32(zip.count - Int(centralOffset))); zip.appendLE(centralOffset)
        zip.appendLE(UInt16(0))

        let zipURL = workDir.appendingPathComponent("evil.zip")
        try zip.write(to: zipURL)
        XCTAssertThrowsError(try ZipArchive.unzip(zipURL, into: workDir.appendingPathComponent("out"))) { error in
            guard case ZipArchive.ZipError.unsafeEntryName = error else {
                return XCTFail("应抛 unsafeEntryName，实际: \(error)")
            }
        }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: MemoryLayout<T>.size))
    }
}
