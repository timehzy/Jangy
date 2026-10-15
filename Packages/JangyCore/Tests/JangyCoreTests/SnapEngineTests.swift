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

    func testSnapTiePrefersLastIteratedPoint() {
        // 等距：2 与 3 距 2.5 都是 0.5 → 后遍历到的（升序里的较大时间）胜出
        XCTAssertEqual(SnapEngine.snap(2.5, to: [2, 3], within: 1.0), 3, accuracy: 0.0001)
    }

    func testSnapPointsSubtractTrailingDissolveOverlap() {
        // 3s@1x 挂 0.5s dissolve + 3s@1x → 后段起点 3-0.5=2.5，成片时长 5.5
        let a = PlanClip(assetID: UUID(), source: .video(0...3), transitionAfter: .dissolve(duration: 0.5))
        let b = PlanClip(assetID: UUID(), source: .video(0...3))
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(a))),
            PlanElement(content: .content(TrackPayload(b))),
        ])
        let plan = EditPlan(tracks: [primary], primaryTrackID: primary.id)
        XCTAssertEqual(SnapEngine.snapPoints(in: plan), [0, 2.5, 3, 5.5])
    }

    func testSnapPointsFadeContributesNoOverlap() {
        // fade 不重叠 → 边界 0,3,6，成片时长 6
        let a = PlanClip(assetID: UUID(), source: .video(0...3), transitionAfter: .fade(duration: 0.5))
        let b = PlanClip(assetID: UUID(), source: .video(0...3))
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(a))),
            PlanElement(content: .content(TrackPayload(b))),
        ])
        let plan = EditPlan(tracks: [primary], primaryTrackID: primary.id)
        XCTAssertEqual(SnapEngine.snapPoints(in: plan), [0, 3, 6])
    }

    func testSnapPointsOfEmptyPlanIsJustZero() {
        let plan = EditPlan(tracks: [], primaryTrackID: UUID())
        XCTAssertEqual(SnapEngine.snapPoints(in: plan), [0])
    }
}
