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
}
