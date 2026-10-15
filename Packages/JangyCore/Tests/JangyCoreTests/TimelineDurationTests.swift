import XCTest
@testable import JangyCore
@testable import JangyTestSupport

/// 渲染时长口径（TimelineDuration.swift）：UI 时长展示与 e2e 断言共用的唯一口径，
/// 必须与 Kadr CompositionBuilder 的转场重叠语义一致（dissolve 全额重叠、fade 不重叠）。
final class TimelineDurationTests: XCTestCase {

    private func clip(_ range: ClosedRange<TimeInterval>, rate: Double = 1.0,
                      transition: PlanTransition? = nil) -> PlanClip {
        PlanClip(assetID: UUID(), source: .video(range), speed: .flat(rate), transitionAfter: transition)
    }

    private func plan(_ clips: [PlanClip]) -> EditPlan {
        EditPlan(clips: clips)
    }

    func testOutputDurationDividesBySpeed() {
        XCTAssertEqual(clip(0...3, rate: 1.0).outputDuration, 3.0, accuracy: 1e-9)
        XCTAssertEqual(clip(0...3, rate: 0.5).outputDuration, 6.0, accuracy: 1e-9)
        XCTAssertEqual(clip(0...2, rate: 2.0).outputDuration, 1.0, accuracy: 1e-9)
    }

    func testTransitionOverlapOnlyForDissolve() {
        XCTAssertEqual(PlanTransition.dissolve(duration: 0.5).overlapDuration, 0.5, accuracy: 1e-9)
        XCTAssertEqual(PlanTransition.fade(duration: 0.5).overlapDuration, 0, accuracy: 1e-9)
    }

    func testRenderedDurationWithoutTransitionsIsSumOfClipOutput() {
        let p = plan([clip(0...3), clip(0...3, rate: 0.5), clip(0...2, rate: 2.0)])
        XCTAssertEqual(p.renderedDuration, 10.0, accuracy: 1e-9)
    }

    func testRenderedDurationSubtractsDissolveOverlapInFull() {
        let p = plan([clip(0...3, transition: .dissolve(duration: 0.5)), clip(0...3)])
        XCTAssertEqual(p.renderedDuration, 5.5, accuracy: 1e-9)
    }

    func testRenderedDurationDoesNotSubtractFade() {
        // fade 不重叠：出/入侧各占相邻片段内 duration/2，总时长与无转场相同
        let p = plan([clip(0...3, transition: .fade(duration: 0.5)), clip(0...3)])
        XCTAssertEqual(p.renderedDuration, 6.0, accuracy: 1e-9)
    }

    func testRenderedDurationSubtractsEachDissolve() {
        let p = plan([
            clip(0...3, transition: .dissolve(duration: 0.5)),
            clip(0...3, transition: .dissolve(duration: 1.0)),
            clip(0...3),
        ])
        XCTAssertEqual(p.renderedDuration, 7.5, accuracy: 1e-9)
    }

    func testEmptyPlanHasZeroRenderedDuration() {
        XCTAssertEqual(plan([]).renderedDuration, 0)
    }

    /// 与导出 e2e 互相锚定：样例工程渲染产物实测 9.5s（≠ Video.duration 求和值 10.5s）。
    func testSamplePlanRenderedDurationMatchesMeasuredExport() {
        XCTAssertEqual(SamplePlan.make().renderedDuration, 9.5, accuracy: 1e-9)
    }

    func testStillOutputDurationDividesBySpeed() {
        XCTAssertEqual(PlanClip(assetID: UUID(), source: .still(duration: 3.0)).outputDuration, 3.0, accuracy: 1e-9)
        XCTAssertEqual(PlanClip(assetID: UUID(), source: .still(duration: 6.0), speed: .flat(2.0)).outputDuration, 3.0, accuracy: 1e-9)
    }
}
