import XCTest
@testable import JangyCore

/// 字幕逐句化的接线：cue 的位置来自 `PlanElement.at`，不再来自 SRT 文件解析。
final class CaptionTimelineTests: XCTestCase {

    private func plan(cueAt: TimeInterval, duration: TimeInterval,
                      enabled: Bool = true) -> EditPlan {
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: [PlanElement(content: .gap(duration: 10))])
        let captionTrack = PlanTrack(
            kind: .caption, placement: .absolute,
            settings: TrackPayload(CaptionTrackSettings(isEnabled: enabled)),
            elements: [PlanElement(at: cueAt, content: .content(TrackPayload(
                CaptionCuePayload(text: "你好", duration: duration))))])
        return EditPlan(tracks: [primary, captionTrack], primaryTrackID: primary.id)
    }

    func testCuePositionComesFromElementAt() {
        let plan = plan(cueAt: 3, duration: 2)
        let track = plan.tracks.first { $0.kind == .caption }!
        let cues = CaptionEngine.makeCues(track: track)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues.first!.timeRange.start.seconds, 3, accuracy: 0.001)
        XCTAssertEqual(cues.first!.timeRange.duration.seconds, 2, accuracy: 0.001)
    }

    func testDisabledCaptionTrackYieldsNoCues() {
        let plan = plan(cueAt: 0, duration: 1, enabled: false)
        let track = plan.tracks.first { $0.kind == .caption }!
        XCTAssertTrue(CaptionEngine.makeCues(track: track).isEmpty)
    }

    func testCueWithoutAtIsSkipped() {
        // 绝对定位轨的元素必须带 at；缺了就跳过，不能崩
        let track = PlanTrack(kind: .caption, placement: .absolute, elements: [
            PlanElement(content: .content(TrackPayload(CaptionCuePayload(text: "x", duration: 1)))),
        ])
        XCTAssertTrue(CaptionEngine.makeCues(track: track).isEmpty)
    }

    func testCueTextIsEditableThroughPlan() {
        var plan = plan(cueAt: 1, duration: 1)
        let ti = plan.tracks.firstIndex { $0.kind == .caption }!
        guard case .content(let payload) = plan.tracks[ti].elements[0].content,
              let cue = payload.value as? CaptionCuePayload else { return XCTFail("payload 类型不对") }
        plan.tracks[ti].elements[0].content = .content(
            TrackPayload(CaptionCuePayload(text: "改过的", duration: cue.duration)))

        let cues = CaptionEngine.makeCues(track: plan.tracks[ti])
        XCTAssertEqual(cues.first?.text, "改过的")
    }

    func testCueTextSurvivesPlanJSONRoundTrip() throws {
        // 字幕文本现在住在 plan 里（不再住在 SRT 文件里），落盘/读回必须无损
        let plan = plan(cueAt: 1, duration: 1)
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(EditPlan.self, from: data)

        let track = decoded.tracks.first { $0.kind == .caption }!
        XCTAssertEqual(CaptionEngine.makeCues(track: track).first?.text, "你好")
    }

    func testMultipleCuesKeepTheirOwnPositions() {
        let captionTrack = PlanTrack(kind: .caption, placement: .absolute, elements: [
            PlanElement(at: 1, content: .content(TrackPayload(
                CaptionCuePayload(text: "一", duration: 1)))),
            PlanElement(at: 4, content: .content(TrackPayload(
                CaptionCuePayload(text: "二", duration: 2)))),
        ])
        let cues = CaptionEngine.makeCues(track: captionTrack)
        XCTAssertEqual(cues.map(\.text), ["一", "二"])
        XCTAssertEqual(cues.map { $0.timeRange.start.seconds }, [1, 4])
    }
}
