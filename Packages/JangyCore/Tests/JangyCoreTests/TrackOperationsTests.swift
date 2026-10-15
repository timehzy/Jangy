import XCTest
@testable import JangyCore

final class TrackOperationsTests: XCTestCase {

    private func makePlan(mainSeconds: [TimeInterval],
                          captionEnds: [TimeInterval] = []) -> EditPlan {
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: mainSeconds.map { PlanElement(content: .gap(duration: $0)) })
        var tracks = [primary]
        if !captionEnds.isEmpty {
            tracks.append(PlanTrack(kind: .caption, placement: .absolute,
                                    elements: captionEnds.map {
                PlanElement(at: $0 - 1, content: .content(TrackPayload(
                    CaptionCuePayload(text: "x", duration: 1))))
            }))
        }
        return EditPlan(tracks: tracks, primaryTrackID: primary.id)
    }

    // MARK: removeElement —— 只改结构，不维持不变式

    func testRemovingMiddleElementReplacesItWithGap() {
        // 中间元素必须是**真的内容元素**——fixture 默认把主轨造成 gap，
        // 「把 gap 换成 gap」是 no-op，测不出 removeElement 的行为。
        let middle = PlanElement(content: .content(TrackPayload(
            PlanClip(assetID: UUID(), source: .video(0...3)))))
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .gap(duration: 3)),
            middle,
            PlanElement(content: .gap(duration: 3)),
        ])
        var plan = EditPlan(tracks: [primary], primaryTrackID: primary.id)

        // 先钉住前置状态，否则「本来就是 gap」时也会绿
        guard case .content = plan.primaryTrack!.elements[1].content else {
            return XCTFail("前置：中间元素应是内容元素")
        }

        TrackOperations.removeElement(middle.id, in: &plan)

        XCTAssertEqual(plan.primaryTrack!.elements.count, 3, "元素位保留")
        guard case .gap(let d) = plan.primaryTrack!.elements[1].content else {
            return XCTFail("中间元素应被换成 gap")
        }
        XCTAssertEqual(d, 3, accuracy: 0.001)
        XCTAssertEqual(plan.renderedDuration, 9, accuracy: 0.001)
    }

    func testRemovingMiddleGapRipplesFollowingElementsForward() {
        // 删 gap = 「合上」：后续元素前移、成片变短（与「删内容留 gap」相反）。
        // 之前 removeElement 对 gap 也「原地换成等长 gap」——是 no-op，工具层回假成功。
        var plan = makePlan(mainSeconds: [3, 2, 4])

        TrackOperations.removeElement(plan.primaryTrack!.elements[1].id, in: &plan)

        XCTAssertEqual(plan.primaryTrack!.elements.count, 2, "gap 被真正移除（不是换成 gap）")
        XCTAssertEqual(plan.renderedDuration, 7, accuracy: 0.001, "后续元素前移，成片变短")
    }

    func testRemovingLastElementJustRemovesItWithoutPadding() {
        // 只移除，**不补 gap** —— 补 gap 是 maintainInvariants 的职责，不是 removeElement 的
        var plan = makePlan(mainSeconds: [3, 3], captionEnds: [5])
        TrackOperations.removeElement(plan.primaryTrack!.elements[1].id, in: &plan)

        XCTAssertEqual(plan.primaryTrack!.elements.count, 1)
        XCTAssertEqual(plan.renderedDuration, 3, accuracy: 0.001,
                       "removeElement 自己不补 gap")
    }

    func testRemovingElementFromAbsoluteTrackLeavesOthersInPlace() {
        var plan = makePlan(mainSeconds: [10], captionEnds: [3, 6])
        TrackOperations.removeElement(plan.tracks[1].elements[0].id, in: &plan)

        XCTAssertEqual(plan.tracks[1].elements.count, 1)
        XCTAssertEqual(plan.tracks[1].elements[0].at, 5, "绝对轨元素不被挪动")
        XCTAssertEqual(plan.renderedDuration, 10, accuracy: 0.001, "主轨不受影响")
    }

    func testRemovingUnknownElementIsNoOp() {
        var plan = makePlan(mainSeconds: [3])
        let before = plan
        TrackOperations.removeElement(UUID(), in: &plan)
        XCTAssertEqual(plan, before)
    }

    // MARK: moveElement

    func testMovingElementSetsAtWithoutMaintainingInvariants() {
        // 移到主轨末端之外——这样如果 moveElement 偷偷调了 maintainInvariants，
        // 主轨就会被补 gap，断言会失败。移到末端之内的话两种实现都过，测不出契约。
        var plan = makePlan(mainSeconds: [10], captionEnds: [3])
        TrackOperations.moveElement(plan.tracks[1].elements[0].id, to: 11, in: &plan)

        XCTAssertEqual(plan.tracks[1].elements[0].at, 11)
        XCTAssertEqual(plan.primaryTrack!.elements.count, 1, "主轨没有被补 gap")
        XCTAssertEqual(plan.renderedDuration, 10, accuracy: 0.001)
    }

    func testMovingUnknownElementIsNoOp() {
        var plan = makePlan(mainSeconds: [3])
        let before = plan
        TrackOperations.moveElement(UUID(), to: 5, in: &plan)
        XCTAssertEqual(plan, before)
    }

    // MARK: maintainInvariants

    func testMaintainingInvariantsPadsTailWhenOtherTrackExtends() {
        // 主轨须**短于**字幕末端才会补：主轨 3+1=4 < 字幕末端 5 → 补一个 1s gap
        var plan = makePlan(mainSeconds: [3, 1], captionEnds: [5])
        TrackOperations.maintainInvariants(in: &plan)

        XCTAssertEqual(plan.primaryTrack!.span, 5, accuracy: 0.001)
        XCTAssertEqual(plan.renderedDuration, 5, accuracy: 0.001)
        XCTAssertEqual(plan.primaryTrack!.elements.count, 3, "尾部补了一个 gap 元素")
    }

    func testMaintainingInvariantsIsNoOpWhenMainIsLongest() {
        var plan = makePlan(mainSeconds: [9], captionEnds: [5])
        let before = plan
        TrackOperations.maintainInvariants(in: &plan)
        XCTAssertEqual(plan, before, "主轨最长时不追加任何元素")
    }

    func testMaintainingInvariantsIsIdempotent() {
        var plan = makePlan(mainSeconds: [3, 3], captionEnds: [9])
        TrackOperations.maintainInvariants(in: &plan)
        let after = plan.primaryTrack!.elements.count
        TrackOperations.maintainInvariants(in: &plan)
        XCTAssertEqual(plan.primaryTrack!.elements.count, after, "重复调用不再追加 gap")
    }

    func testMaintainingInvariantsAccountsForTransitionOverlap() {
        // 主轨带转场：span(6) ≠ renderedDuration(5.5)。
        // 差额必须按 renderedDuration 算，按 span 算会漏补 0.5。
        let a = PlanClip(assetID: UUID(), source: .video(0...3),
                         transitionAfter: .dissolve(duration: 0.5))
        let b = PlanClip(assetID: UUID(), source: .video(0...3))
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(a))),
            PlanElement(content: .content(TrackPayload(b))),
        ])
        var plan = EditPlan(tracks: [primary], primaryTrackID: primary.id)
        XCTAssertEqual(plan.renderedDuration, 5.5, accuracy: 0.001)
        XCTAssertEqual(plan.primaryTrack!.span, 6, accuracy: 0.001)

        plan.tracks.append(PlanTrack(kind: .caption, placement: .absolute, elements: [
            PlanElement(at: 4.7, content: .content(TrackPayload(
                CaptionCuePayload(text: "x", duration: 1)))),   // 末端 5.7
        ]))
        TrackOperations.maintainInvariants(in: &plan)

        XCTAssertEqual(plan.renderedDuration, 5.7, accuracy: 0.01,
                       "差额按 renderedDuration 算，不是 span")
    }

    // MARK: normalizePayloads

    func testNormalizePayloadsDispatchesToFeatureAndClearsDanglingTransition() {
        // 转场后面是 gap → 悬空 → 归一化清掉
        let a = PlanClip(assetID: UUID(), source: .video(0...3),
                         transitionAfter: .dissolve(duration: 0.5))
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(a))),
            PlanElement(content: .gap(duration: 2)),
        ])
        var plan = EditPlan(tracks: [primary], primaryTrackID: primary.id)
        TrackOperations.normalizePayloads(in: &plan)

        guard case .content(let payload) = plan.primaryTrack!.elements[0].content,
              let clip = payload.value as? PlanClip else { return XCTFail("payload 类型不对") }
        XCTAssertNil(clip.transitionAfter, "悬空转场应被清掉")
    }

    func testNormalizePayloadsKeepsAdjacentTransition() {
        let a = PlanClip(assetID: UUID(), source: .video(0...3),
                         transitionAfter: .dissolve(duration: 0.5))
        let b = PlanClip(assetID: UUID(), source: .video(0...3))
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(a))),
            PlanElement(content: .content(TrackPayload(b))),
        ])
        var plan = EditPlan(tracks: [primary], primaryTrackID: primary.id)
        TrackOperations.normalizePayloads(in: &plan)

        guard case .content(let payload) = plan.primaryTrack!.elements[0].content,
              let clip = payload.value as? PlanClip else { return XCTFail("payload 类型不对") }
        XCTAssertNotNil(clip.transitionAfter, "紧邻内容元素的转场是合法的，不能清")
    }
}
