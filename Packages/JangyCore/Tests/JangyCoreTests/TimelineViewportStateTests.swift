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
        XCTAssertEqual(s.time(atViewportX: 200), 7, accuracy: 0.001, "视口中央恒等于播放头时间")
    }

    func testPlayheadClampsToContentDuration() {
        let s = makeState()
        s.setPlayhead(-5); XCTAssertEqual(s.playheadTime, 0)
        s.setPlayhead(999); XCTAssertEqual(s.playheadTime, 100)
    }

    func testZoomKeepsTimeUnderAnchorFixed() {
        let s = makeState(width: 400, duration: 100)
        s.setPlayhead(50)
        let anchorX: CGFloat = 300            // 锚点在视口右侧
        let timeBefore = s.time(atViewportX: anchorX) // = 50 + (300-200)/10 = 60
        XCTAssertEqual(timeBefore, 60, accuracy: 0.001)

        s.zoom(by: 2, anchorX: anchorX)       // pps 10 → 20
        XCTAssertEqual(s.pointsPerSecond, 20, accuracy: 0.001)
        XCTAssertEqual(s.time(atViewportX: anchorX), 60, accuracy: 0.01, "锚点下的时间不动")
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

    func testViewportXIsInverseOfTime() {
        let s = makeState(width: 400, duration: 100)
        s.setPlayhead(37)
        for t in [0.0, 12.5, 50.0, 99.0] {
            XCTAssertEqual(s.time(atViewportX: s.viewportX(forTime: t)), t, accuracy: 0.001,
                           "viewportX 是 time(atViewportX:) 的逆")
        }
    }

    func testContentXEqualsViewportXPlusScrollOffset() {
        let s = makeState(width: 400, duration: 100)
        s.setPlayhead(37)
        for t in [0.0, 12.5, 50.0] {
            XCTAssertEqual(s.contentX(forTime: t), s.viewportX(forTime: t) + s.scrollOffset,
                           accuracy: 0.001)
        }
    }

    func testShrinkingContentDurationReclampsPlayhead() {
        let s = makeState(width: 400, duration: 100)
        s.setPlayhead(50)
        s.contentDuration = 10     // 删片段后时长收缩
        XCTAssertEqual(s.playheadTime, 10, "收缩时长要把播放头重夹回内容范围内")
    }

    func testVisibleTimeRangeWellFormedWhenEmpty() {
        let s = TimelineViewportState(pointsPerSecond: 10)   // viewportWidth / contentDuration 均 0
        let r = s.visibleTimeRange
        XCTAssertLessThanOrEqual(r.lowerBound, r.upperBound, "空视口也要给出良构区间")
    }
}
