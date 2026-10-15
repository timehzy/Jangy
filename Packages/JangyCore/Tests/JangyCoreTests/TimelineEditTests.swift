import XCTest
@testable import JangyCore

@MainActor
final class TimelineEditTests: XCTestCase {

    private func store(clips: [PlanClip]) -> EditStore {
        let assets = clips.map { AssetItem(id: $0.assetID, kind: .video, fileName: "v.mp4") }
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: clips.map { PlanElement(content: .content(TrackPayload($0))) })
        return EditStore(initial: EditPlan(assets: assets, tracks: [primary], primaryTrackID: primary.id))
    }

    func testTrimSourceAppliesAndPushesOneUndoStep() {
        let s = store(clips: [PlanClip(assetID: UUID(), source: .video(0...4))])
        let id = s.plan.primaryTrack!.elements[0].id
        let before = s.historyCount

        let result = TimelineEdit.trimSource(elementID: id, source: .video(1...3)).apply(to: s)
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(s.historyCount, before + 1, "一次编辑只 +1 撤销步")
        XCTAssertEqual(s.plan.renderedDuration, 2, accuracy: 0.001)
    }

    func testMoveToChainedTrackAppendsAndKeepsInvariants() {
        let overlayClip = PlanClip(assetID: UUID(), source: .video(0...2))
        let primaryClip = PlanClip(assetID: UUID(), source: .video(0...3))
        let assets = [overlayClip, primaryClip].map { AssetItem(id: $0.assetID, kind: .video, fileName: "v.mp4") }
        let overlay = PlanTrack(kind: .video, placement: .absolute, elements: [
            PlanElement(at: 1, content: .content(TrackPayload(overlayClip))),
        ])
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: [PlanElement(content: .content(TrackPayload(primaryClip)))])
        let s = EditStore(initial: EditPlan(assets: assets, tracks: [primary, overlay], primaryTrackID: primary.id))
        let id = overlay.elements[0].id

        _ = TimelineEdit.moveElement(elementID: id, toTrackID: primary.id, at: nil, toIndex: nil).apply(to: s)
        XCTAssertEqual(s.plan.primaryTrack!.elements.count, 2, "元素进主轨")
        XCTAssertTrue(s.plan.tracks[1].elements.isEmpty, "叠加轨清空")
    }

    func testReorderTrackMovesRow() {
        let a = PlanTrack(kind: .video, placement: .chained,
                          elements: [PlanElement(content: .gap(duration: 3))])
        let b = PlanTrack(kind: .video, placement: .absolute)
        let s = EditStore(initial: EditPlan(tracks: [a, b], primaryTrackID: a.id))

        _ = TimelineEdit.reorderTrack(trackID: b.id, toIndex: 0).apply(to: s)
        XCTAssertEqual(s.plan.tracks[0].id, b.id)
        XCTAssertEqual(s.plan.tracks[1].id, a.id)
    }
}
