import XCTest
@testable import POCCore

final class AssetResolverTests: XCTestCase {

    func testResolvesFileNameAgainstDirectory() {
        let dir = URL(fileURLWithPath: "/tmp/poc-assets")
        let resolver = AssetResolver(directory: dir)
        XCTAssertEqual(resolver.resolve(MediaRef(fileName: "clip1.mp4")).path, "/tmp/poc-assets/clip1.mp4")
    }

    func testAbsolutePathPassThrough() {
        let resolver = AssetResolver(directory: URL(fileURLWithPath: "/tmp/ignored"))
        XCTAssertEqual(resolver.resolve(MediaRef(fileName: "/Users/x/4k-hdr.mp4")).path, "/Users/x/4k-hdr.mp4")
    }

    func testExists() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("a.mp4")
        try! Data().write(to: file)
        let resolver = AssetResolver(directory: dir)
        XCTAssertTrue(resolver.exists(MediaRef(fileName: "a.mp4")))
        XCTAssertFalse(resolver.exists(MediaRef(fileName: "b.mp4")))
    }
}
