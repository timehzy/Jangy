import Foundation
import XCTest

@testable import JangyAgent
@testable import JangyCore
@testable import JangyTestSupport

/// snapshot 视觉自检工具：合成素材 → 单帧直渲 → 落盘 + 待回喂队列。
final class AgentSnapshotToolTests: XCTestCase {

    private struct Envelope: Decodable {
        let status: String
        let message: String?
    }

    private var workDir: URL!
    private var resolver: AssetResolver!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jangy-snapshot-test-\(UUID().uuidString)", isDirectory: true)
        resolver = try AssetSynthesizer.synthesize(into: workDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func makeContext() -> AgentRunContext {
        AgentRunContext(plan: SamplePlan.make(), resolver: resolver,
                        framesDirectory: workDir.appendingPathComponent("Frames", isDirectory: true),
                        maxToolCalls: 30)
    }

    func testSnapshotWritesPNGAndQueuesForDelivery() async throws {
        let context = makeContext()
        let result = try await SnapshotTool(context: context).call(parsed: .init(times: [0.5, 9.0]))
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(result.utf8))
        XCTAssertEqual(envelope.status, "ok")

        let pending = context.drainSnapshots()
        XCTAssertEqual(pending.count, 2)
        for frame in pending {
            XCTAssertTrue(FileManager.default.fileExists(atPath: frame.url.path))
            // PNG magic number
            XCTAssertEqual(frame.pngData.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        }
        // 队列取出即清空
        XCTAssertTrue(context.drainSnapshots().isEmpty)
    }

    func testSnapshotTimeOutOfRangeReturnsError() async throws {
        let context = makeContext()
        let result = try await SnapshotTool(context: context).call(parsed: .init(times: [99]))
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(result.utf8))
        XCTAssertEqual(envelope.status, "error")
        XCTAssertTrue(envelope.message?.contains("超出渲染时长") == true)
        XCTAssertTrue(context.drainSnapshots().isEmpty, "失败不入队")
    }

    func testSnapshotEmptyTimesReturnsError() async throws {
        let context = makeContext()
        let result = try await SnapshotTool(context: context).call(parsed: .init(times: []))
        XCTAssertEqual(try JSONDecoder().decode(Envelope.self, from: Data(result.utf8)).status, "error")
    }
}
