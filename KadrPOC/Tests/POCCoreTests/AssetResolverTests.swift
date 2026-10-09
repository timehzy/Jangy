import XCTest
@testable import POCCore

final class AssetResolverTests: XCTestCase {

    private func asset(_ fileName: String) -> AssetItem {
        AssetItem(kind: .video, fileName: fileName)
    }

    func testResolvesFileNameAgainstDirectory() {
        let dir = URL(fileURLWithPath: "/tmp/poc-assets")
        let resolver = AssetResolver(directory: dir)
        XCTAssertEqual(resolver.resolve(asset("clip1.mp4")).path, "/tmp/poc-assets/clip1.mp4")
        XCTAssertEqual(resolver.resolve(fileName: "clip1.mp4").path, "/tmp/poc-assets/clip1.mp4")
    }

    func testAbsolutePathPassThrough() {
        let resolver = AssetResolver(directory: URL(fileURLWithPath: "/tmp/ignored"))
        XCTAssertEqual(resolver.resolve(asset("/Users/x/4k-hdr.mp4")).path, "/Users/x/4k-hdr.mp4")
    }

    func testExists() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("a.mp4")
        try! Data().write(to: file)
        let resolver = AssetResolver(directory: dir)
        XCTAssertTrue(resolver.exists(asset("a.mp4")))
        XCTAssertFalse(resolver.exists(asset("b.mp4")))
    }
}
