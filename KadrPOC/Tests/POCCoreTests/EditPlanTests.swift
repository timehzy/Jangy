import XCTest
@testable import POCCore

final class EditPlanTests: XCTestCase {

    private func makePlan() -> EditPlan {
        EditPlan(
            clips: [
                PlanClip(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                         source: MediaRef(fileName: "clip1.mp4"),
                         range: 0...3, speed: .flat(1.0),
                         transitionAfter: .dissolve(duration: 0.5)),
                PlanClip(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                         source: MediaRef(fileName: "clip2.mp4"),
                         range: 0...3, speed: .flat(0.5),
                         transitionAfter: nil),
            ],
            captions: CaptionTrack(source: MediaRef(fileName: "sample.srt"),
                                   isEnabled: true,
                                   style: CaptionStyle(fontSize: 48, isBold: true)),
            preset: .reelsAndShorts
        )
    }

    func testRoundTrip() throws {
        let plan = makePlan()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(plan)
        let decoded = try JSONDecoder().decode(EditPlan.self, from: data)
        XCTAssertEqual(decoded, plan)
    }

    func testDefaultVersionIs1() {
        XCTAssertEqual(makePlan().version, 1)
    }

    func testSpeedRateAccessor() {
        XCTAssertEqual(SpeedPlan.flat(0.5).rate, 0.5)
    }

    func testTransitionDurationAccessor() {
        XCTAssertEqual(PlanTransition.dissolve(duration: 0.5).duration, 0.5)
        XCTAssertEqual(PlanTransition.fade(duration: 0.3).duration, 0.3)
    }

    /// Agent 手写的极简 JSON：省略 version/id/speed/transitionAfter/captions/preset，
    /// 解码时全部落回默认值。id 缺省时随机生成，故只断言可断言的字段。
    func testDecodesMinimalJSON() throws {
        let json = """
        {
          "clips": [
            {
              "source": { "fileName": "clip1.mp4" },
              "range": [0, 3]
            }
          ]
        }
        """
        let plan = try JSONDecoder().decode(EditPlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.version, 1)
        XCTAssertEqual(plan.preset, .reelsAndShorts)
        XCTAssertNil(plan.captions)
        XCTAssertEqual(plan.clips.count, 1)
        XCTAssertEqual(plan.clips[0].source, MediaRef(fileName: "clip1.mp4"))
        XCTAssertEqual(plan.clips[0].range, 0...3)
        XCTAssertEqual(plan.clips[0].speed, .flat(1.0))
        XCTAssertNil(plan.clips[0].transitionAfter)
    }

    func testSpeedPlanWireFormat() throws {
        struct Wrapper: Codable { var speed: SpeedPlan }
        let data = try JSONEncoder().encode(Wrapper(speed: .flat(0.5)))
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"type\":\"flat\""), "got: \(json)")
        XCTAssertTrue(json.contains("\"rate\":0.5"), "got: \(json)")

        let decoded = try JSONDecoder().decode(SpeedPlan.self,
                                               from: Data("{\"type\":\"flat\",\"rate\":0.5}".utf8))
        XCTAssertEqual(decoded, .flat(0.5))
    }

    func testPlanTransitionWireFormat() throws {
        struct Wrapper: Codable { var transition: PlanTransition }
        let data = try JSONEncoder().encode(Wrapper(transition: .dissolve(duration: 0.5)))
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"type\":\"dissolve\""), "got: \(json)")
        XCTAssertTrue(json.contains("\"duration\":0.5"), "got: \(json)")

        let decoded = try JSONDecoder().decode(PlanTransition.self,
                                               from: Data("{\"type\":\"dissolve\",\"duration\":0.5}".utf8))
        XCTAssertEqual(decoded, .dissolve(duration: 0.5))
    }

    func testUnknownEnumTypeThrows() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(SpeedPlan.self,
                                     from: Data("{\"type\":\"warp\",\"rate\":1}".utf8))
        ) { error in
            XCTAssertTrue(String(describing: error).contains("warp"))
        }
    }
}
