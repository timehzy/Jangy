import XCTest
@testable import JangyCore

@MainActor
final class TimelineViewportStateTests: XCTestCase {

    private func makeState(width: CGFloat = 400, duration: TimeInterval = 100) -> TimelineViewportState {
        let s = TimelineViewportState(pointsPerSecond: 10)   // 100s 内容 = 1000pt
        s.viewportWidth = width
        s.contentDuration = duration
        return s
    }

    func testScrollOffsetIsPlayheadTimeTimesScale() {
        let s = makeState()
        s.setPlayhead(3)
        XCTAssertEqual(s.scrollOffset, 30, accuracy: 0.001)
    }

    func testTimeAtViewportCenterIsPlayheadTime() {
        let s = makeState()
        s.setPlayhead(7)
        XCTAssertEqual(s.time(atX: 200), 7, accuracy: 0.001, "视口中央恒等于播放头时间")
    }

    func testPlayheadClampsToContentDuration() {
        let s = makeState()
        s.setPlayhead(-5); XCTAssertEqual(s.playheadTime, 0)
        s.setPlayhead(999); XCTAssertEqual(s.playheadTime, 100)
    }

    func testScrubRightMovesPlayheadEarlier() {
        // 内容往右拖（dx>0）= 看更早的内容 = 播放头时间减小
        let s = makeState()
        s.setPlayhead(5)
        s.scrub(by: 20)   // 20pt / 10pps = 2s
        XCTAssertEqual(s.playheadTime, 3, accuracy: 0.001)
    }

    func testZoomKeepsTimeUnderAnchorFixed() {
        let s = makeState(width: 400, duration: 100)
        s.setPlayhead(50)
        let anchorX: CGFloat = 300            // 锚点在视口右侧
        let timeBefore = s.time(atX: anchorX) // = 50 + (300-200)/10 = 60
        XCTAssertEqual(timeBefore, 60, accuracy: 0.001)

        s.zoom(by: 2, anchorX: anchorX)       // pps 10 → 20
        XCTAssertEqual(s.pointsPerSecond, 20, accuracy: 0.001)
        XCTAssertEqual(s.time(atX: anchorX), 60, accuracy: 0.01, "锚点下的时间不动")
    }

    func testZoomClampsToScaleBounds() {
        let s = makeState()
        s.zoom(by: 0.0001, anchorX: 200)
        XCTAssertEqual(s.pointsPerSecond, TimelineViewportState.minPointsPerSecond, accuracy: 0.001)
        s.zoom(by: 1e9, anchorX: 200)
        XCTAssertEqual(s.pointsPerSecond, TimelineViewportState.maxPointsPerSecond, accuracy: 0.001)
    }

    func testVisibleTimeRangeSpansViewport() {
        let s = makeState(width: 400, duration: 100)
        s.setPlayhead(50)
        let r = s.visibleTimeRange
        XCTAssertEqual(r.lowerBound, 30, accuracy: 0.001)
        XCTAssertEqual(r.upperBound, 70, accuracy: 0.001)
    }
}
