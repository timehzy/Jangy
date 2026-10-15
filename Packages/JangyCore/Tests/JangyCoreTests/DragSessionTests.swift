import XCTest
@testable import JangyCore

final class DragSessionTests: XCTestCase {

    private func mainPlan(_ clips: [PlanClip], assets: [AssetItem] = []) -> EditPlan {
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: clips.map { PlanElement(content: .content(TrackPayload($0))) })
        return EditPlan(assets: assets, tracks: [primary], primaryTrackID: primary.id)
    }

    private func context(_ plan: EditPlan, pps: CGFloat = 100,
                         rowHeight: CGFloat = 64) -> DragContext {
        DragContext(plan: plan, pointsPerSecond: pps,
                    snapPoints: SnapEngine.snapPoints(in: plan), snapTolerance: 0.05,
                    trackRowHeight: rowHeight, minElementDuration: 0.2)
    }

    // MARK: trim

    func testTrimTrailingEdgeShortensSourceRange() {
        let plan = mainPlan([PlanClip(assetID: UUID(), source: .video(0...4))])
        let id = plan.primaryTrack!.elements[0].id
        let session = DragSession(kind: .trim(elementID: id, edge: .trailing))
            .translated(to: CGSize(width: -100, height: 0))   // -100pt / 100pps = -1s

        let edit = session.resolve(in: context(plan))
        guard case .trimSource(_, .video(let range))? = edit else { return XCTFail("期望 trimSource") }
        XCTAssertEqual(range.lowerBound, 0, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 3, accuracy: 0.001)
    }

    func testTrimLeadingEdgeClampsAtZero() {
        let plan = mainPlan([PlanClip(assetID: UUID(), source: .video(0...4))])
        let id = plan.primaryTrack!.elements[0].id
        let session = DragSession(kind: .trim(elementID: id, edge: .leading))
            .translated(to: CGSize(width: 500, height: 0))    // 想推到 +5s，超过区间长
        let edit = session.resolve(in: context(plan))
        guard case .trimSource(_, .video(let range))? = edit else { return XCTFail("期望 trimSource") }
        XCTAssertLessThan(range.upperBound - range.lowerBound, 4, "必须留下正长度")
        XCTAssertGreaterThanOrEqual(range.lowerBound, 0)
    }

    func testTrimNoOpReturnsNil() {
        let plan = mainPlan([PlanClip(assetID: UUID(), source: .video(0...4))])
        let id = plan.primaryTrack!.elements[0].id
        let session = DragSession(kind: .trim(elementID: id, edge: .trailing))
            .translated(to: .zero)
        XCTAssertNil(session.resolve(in: context(plan)), "零位移不落栈")
    }

    func testTrimSnapsToNearbyBoundary() {
        // 三段：边界 0/5/7/9。把第一段右缘从 5 拖到 6.97s，应吸到下一段起点 7。
        let asset = AssetItem(kind: .video, fileName: "v.mp4", duration: 20)
        let plan = mainPlan([
            PlanClip(assetID: asset.id, source: .video(0...5)),
            PlanClip(assetID: asset.id, source: .video(0...2)),
            PlanClip(assetID: asset.id, source: .video(0...2)),
        ], assets: [asset])
        let id = plan.primaryTrack!.elements[0].id
        let session = DragSession(kind: .trim(elementID: id, edge: .trailing))
            .translated(to: CGSize(width: 197, height: 0))   // 5 → 6.97s
        let edit = session.resolve(in: context(plan))
        guard case .trimSource(_, .video(let range))? = edit else { return XCTFail("期望 trimSource") }
        XCTAssertEqual(range.upperBound, 7, accuracy: 0.001, "吸附到相邻边界")
    }

    // MARK: move（绝对轨）

    func testMoveAbsoluteElementSetsSnappedAt() {
        let overlay = PlanTrack(kind: .video, placement: .absolute, elements: [
            PlanElement(at: 2, content: .content(TrackPayload(PlanClip(assetID: UUID(), source: .video(0...2))))),
        ])
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: [PlanElement(content: .gap(duration: 10))])
        let plan = EditPlan(tracks: [primary, overlay], primaryTrackID: primary.id)
        let id = overlay.elements[0].id

        let session = DragSession(kind: .moveElement(elementID: id, fromTrackID: overlay.id))
            .translated(to: CGSize(width: 100, height: 0))    // +1s
        let edit = session.resolve(in: context(plan))
        guard case .moveElement(_, _, .some(let at), _)? = edit
        else { return XCTFail("期望 moveElement 带 at") }
        XCTAssertEqual(at, 3, accuracy: 0.001)
    }

    // MARK: 换轨

    func testMoveToOtherTrackByVerticalTranslation() {
        let overlay = PlanTrack(kind: .video, placement: .absolute, elements: [
            PlanElement(at: 1, content: .content(TrackPayload(PlanClip(assetID: UUID(), source: .video(0...2))))),
        ])
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: [PlanElement(content: .gap(duration: 10))])
        let plan = EditPlan(tracks: [primary, overlay], primaryTrackID: primary.id)
        let id = overlay.elements[0].id

        // 向上拖一行（rowHeight 64）→ 目标轨 = primary
        let session = DragSession(kind: .moveElement(elementID: id, fromTrackID: overlay.id))
            .translated(to: CGSize(width: 0, height: -64))
        let edit = session.resolve(in: context(plan, rowHeight: 64))
        guard case .moveElement(_, .some(let trackID), _, _)? = edit
        else { return XCTFail("期望换轨") }
        XCTAssertEqual(trackID, primary.id)
    }

    // MARK: 轨道重排

    func testReorderTrackByVerticalTranslation() {
        let a = PlanTrack(kind: .video, placement: .chained,
                          elements: [PlanElement(content: .gap(duration: 5))])
        let b = PlanTrack(kind: .video, placement: .absolute)
        let plan = EditPlan(tracks: [a, b], primaryTrackID: a.id)

        let session = DragSession(kind: .reorderTrack(trackID: b.id))
            .translated(to: CGSize(width: 0, height: -64))   // 上移一行
        let edit = session.resolve(in: context(plan, rowHeight: 64))
        XCTAssertEqual(edit, .reorderTrack(trackID: b.id, toIndex: 0))
    }

    func testReorderFirstTrackUpIsNoOp() {
        let a = PlanTrack(kind: .video, placement: .chained,
                          elements: [PlanElement(content: .gap(duration: 5))])
        let plan = EditPlan(tracks: [a], primaryTrackID: a.id)
        let session = DragSession(kind: .reorderTrack(trackID: a.id))
            .translated(to: CGSize(width: 0, height: -64))
        XCTAssertNil(session.resolve(in: context(plan)), "已在顶部，上移无净变化")
    }

    // MARK: 链式轨内重排（拖到末端 / 前端）

    // 每段 2s，起点 0/2/4，中点 1/3/5。

    func testChainedReorderDragRightPastLastMovesToEndOfTwo() {
        let plan = mainPlan([
            PlanClip(assetID: UUID(), source: .video(0...2)),
            PlanClip(assetID: UUID(), source: .video(0...2)),
        ])
        let a = plan.primaryTrack!.elements[0].id
        let primaryID = plan.primaryTrackID
        let session = DragSession(kind: .moveElement(elementID: a, fromTrackID: primaryID))
            .translated(to: CGSize(width: 250, height: 0))    // 中点 1 → 3.5，越过 B 的中点
        XCTAssertEqual(session.resolve(in: context(plan)),
                       .moveElement(elementID: a, toTrackID: primaryID, at: nil, toIndex: 1))
    }

    func testChainedReorderDragRightPastEndMovesToEndOfThree() {
        let plan = mainPlan([
            PlanClip(assetID: UUID(), source: .video(0...2)),
            PlanClip(assetID: UUID(), source: .video(0...2)),
            PlanClip(assetID: UUID(), source: .video(0...2)),
        ])
        let a = plan.primaryTrack!.elements[0].id
        let primaryID = plan.primaryTrackID
        let session = DragSession(kind: .moveElement(elementID: a, fromTrackID: primaryID))
            .translated(to: CGSize(width: 500, height: 0))    // 中点 1 → 6，越过末端
        XCTAssertEqual(session.resolve(in: context(plan)),
                       .moveElement(elementID: a, toTrackID: primaryID, at: nil, toIndex: 2))
    }

    func testChainedReorderDragLeftToFrontMovesToZero() {
        let plan = mainPlan([
            PlanClip(assetID: UUID(), source: .video(0...2)),
            PlanClip(assetID: UUID(), source: .video(0...2)),
            PlanClip(assetID: UUID(), source: .video(0...2)),
        ])
        let c = plan.primaryTrack!.elements[2].id
        let primaryID = plan.primaryTrackID
        let session = DragSession(kind: .moveElement(elementID: c, fromTrackID: primaryID))
            .translated(to: CGSize(width: -500, height: 0))   // 中点 5 → 0，越过 A 的中点
        XCTAssertEqual(session.resolve(in: context(plan)),
                       .moveElement(elementID: c, toTrackID: primaryID, at: nil, toIndex: 0))
    }

    func testChainedReorderWithinSameSlotIsNoOp() {
        let plan = mainPlan([
            PlanClip(assetID: UUID(), source: .video(0...2)),
            PlanClip(assetID: UUID(), source: .video(0...2)),
        ])
        let a = plan.primaryTrack!.elements[0].id
        let primaryID = plan.primaryTrackID
        let session = DragSession(kind: .moveElement(elementID: a, fromTrackID: primaryID))
            .translated(to: CGSize(width: 10, height: 0))     // 中点 1 → 1.1，没过 B 的中点
        XCTAssertNil(session.resolve(in: context(plan)), "未跨中点，重排无净变化")
    }
}

final class GestureRouterTests: XCTestCase {
    func testTrimHandleHitMakesTrimSession() {
        let id = UUID()
        let s = GestureRouter.trimSession(for: .trimHandle(elementID: id, edge: .leading))
        XCTAssertEqual(s?.kind, .trim(elementID: id, edge: .leading))
    }

    func testLiftOnElementMakesMoveSession() {
        let element = PlanElement(content: .gap(duration: 2))
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [element])
        let plan = EditPlan(tracks: [primary], primaryTrackID: primary.id)
        let s = GestureRouter.liftSession(for: .element(id: element.id), plan: plan)
        XCTAssertEqual(s?.kind, .moveElement(elementID: element.id, fromTrackID: primary.id))
    }

    func testLiftOnEmptyMakesNoSession() {
        let primary = PlanTrack(kind: .video, placement: .chained)
        let plan = EditPlan(tracks: [primary], primaryTrackID: primary.id)
        XCTAssertNil(GestureRouter.liftSession(for: .empty, plan: plan))
    }

    func testLiftOnTrackCapMakesReorderSession() {
        let primary = PlanTrack(kind: .video, placement: .chained)
        let plan = EditPlan(tracks: [primary], primaryTrackID: primary.id)
        XCTAssertEqual(GestureRouter.liftSession(for: .trackCap(trackID: primary.id), plan: plan)?.kind,
                       .reorderTrack(trackID: primary.id))
    }
}
