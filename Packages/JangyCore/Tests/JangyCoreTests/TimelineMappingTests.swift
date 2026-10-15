import XCTest
@testable import JangyCore

final class TimelineMappingTests: XCTestCase {

    func testSourceTimeMapsOutputOffsetThroughSpeed() {
        // 源 [10,14]（长 4s），倍速 2 → 输出长 2s；输出偏移 0.5s → 源 10 + 0.5*2 = 11s
        let clip = PlanClip(assetID: UUID(), source: .video(10...14), speed: .flat(2.0))
        XCTAssertEqual(clip.sourceTime(forOutputOffset: 0)!, 10, accuracy: 0.001)
        XCTAssertEqual(clip.sourceTime(forOutputOffset: 0.5)!, 11, accuracy: 0.001)
        XCTAssertEqual(clip.sourceTime(forOutputOffset: 2.0)!, 14, accuracy: 0.001)
    }

    func testSourceTimeIsNilForStill() {
        // still 没有源区间，无从抽帧
        XCTAssertNil(PlanClip(assetID: UUID(), source: .still(duration: 3)).sourceTime(forOutputOffset: 1))
    }

    func testChainedTrackOutputStartsArePrefixSumsMinusOverlap() {
        // 3s@1x + 3s@1x，前段挂 0.5s dissolve → 后段起点 = 3 - 0.5 = 2.5
        let a = PlanClip(assetID: UUID(), source: .video(0...3), transitionAfter: .dissolve(duration: 0.5))
        let b = PlanClip(assetID: UUID(), source: .video(0...3))
        let track = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(a))),
            PlanElement(content: .content(TrackPayload(b))),
        ])
        XCTAssertEqual(track.elementOutputStarts(), [0, 2.5])
    }

    func testAbsoluteTrackOutputStartsComeFromAt() {
        let track = PlanTrack(kind: .video, placement: .absolute, elements: [
            PlanElement(at: 1, content: .content(TrackPayload(PlanClip(assetID: UUID(), source: .video(0...2))))),
            PlanElement(at: 4, content: .content(TrackPayload(PlanClip(assetID: UUID(), source: .video(0...2))))),
        ])
        XCTAssertEqual(track.elementOutputStarts(), [1, 4])
    }
}
