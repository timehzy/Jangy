import XCTest
@testable import POCCore

final class PlanLoaderTests: XCTestCase {

    private func writeTemp(_ content: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testLoadsValidPlan() throws {
        let url = writeTemp(#"{"version":2,"assets":[{"id":"aaaaaaaa-0000-0000-0000-000000000001","kind":"video","fileName":"a.mp4"}],"clips":[{"id":"11111111-1111-1111-1111-111111111111","assetID":"aaaaaaaa-0000-0000-0000-000000000001","range":[0,3],"speed":{"type":"flat","rate":1.0},"transitionAfter":null}],"captions":null,"preset":"reelsAndShorts"}"#)
        let plan = try PlanLoader.load(from: url)
        XCTAssertEqual(plan.clips.count, 1)
        XCTAssertEqual(plan.clips[0].assetID, UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!)
        XCTAssertEqual(plan.asset(withID: plan.clips[0].assetID)?.fileName, "a.mp4")
    }

    func testTypeMismatchReportsFieldPath() throws {
        let url = writeTemp(#"{"version":2,"clips":[{"id":"11111111-1111-1111-1111-111111111111","assetID":"aaaaaaaa-0000-0000-0000-000000000001","range":[0,3],"speed":{"type":"flat","rate":"fast"},"transitionAfter":null}],"captions":null,"preset":"reelsAndShorts"}"#)
        XCTAssertThrowsError(try PlanLoader.load(from: url)) { error in
            guard case let PlanLoaderError.decodingFailed(path, _) = error else {
                return XCTFail("应为 decodingFailed，实际 \(error)")
            }
            XCTAssertTrue(path.contains("clips[0].speed"), "路径应指到出错字段，实际: \(path)")
        }
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try PlanLoader.load(from: URL(fileURLWithPath: "/tmp/no-such-\(UUID().uuidString).json")))
    }

    func testGarbageJSONThrows() {
        let url = writeTemp("not json at all")
        XCTAssertThrowsError(try PlanLoader.load(from: url))
    }
}
