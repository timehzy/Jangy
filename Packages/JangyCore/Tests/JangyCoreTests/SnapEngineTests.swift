import XCTest
@testable import JangyCore

final class SnapEngineTests: XCTestCase {

    func testSnapPointsIncludeZeroEndAndAllBoundaries() {
        let a = PlanClip(assetID: UUID(), source: .video(0...3))
        let b = PlanClip(assetID: UUID(), source: .video(0...2))
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(a))),
            PlanElement(content: .content(TrackPayload(b))),
        ])
        let overlay = PlanTrack(kind: .video, placement: .absolute, elements: [
            PlanElement(at: 4, content: .content(TrackPayload(PlanClip(assetID: UUID(), source: .video(0...1))))),
        ])
        let plan = EditPlan(tracks: [primary, overlay], primaryTrackID: primary.id)

        let points = SnapEngine.snapPoints(in: plan)
        // 主轨边界 0,3,5；成片时长 5；叠加轨 4,5
        XCTAssertEqual(points, [0, 3, 4, 5])
    }

    func testSnapPicksNearestWithinTolerance() {
        XCTAssertEqual(SnapEngine.snap(3.05, to: [0, 3, 5], within: 0.1), 3, accuracy: 0.0001)
    }

    func testSnapReturnsCandidateWhenNothingInRange() {
        XCTAssertEqual(SnapEngine.snap(4.0, to: [0, 3, 5], within: 0.1), 4.0, accuracy: 0.0001)
    }

    func testSnapPicksCloserOfTwoCandidates() {
        XCTAssertEqual(SnapEngine.snap(2.9, to: [3, 2], within: 1.0), 3, accuracy: 0.0001)
    }
}
