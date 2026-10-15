import XCTest
@testable import JangyCore

/// `EditStore.apply` 是唯一写入口，结构变化后的不变式维持（补尾部 gap）与 payload 归一化
/// （清失效转场）都收敛在这里。本文件钉住这两条路径——它们此前零覆盖：
/// trim/speed 让主轨变短没人补 gap（编辑静默失败）、删除中间片段留下跨 gap 的转场（删除失败）。
final class EditStoreInvariantsTests: XCTestCase {

    private func videoAsset(_ name: String, duration: TimeInterval = 10) -> AssetItem {
        AssetItem(kind: .video, fileName: name, duration: duration)
    }

    private func clip(_ assetID: UUID, _ range: ClosedRange<TimeInterval>,
                      transitionAfter: PlanTransition? = nil) -> PlanClip {
        PlanClip(assetID: assetID, source: .video(range), transitionAfter: transitionAfter)
    }

    /// 主轨 [A(6s), B(3s)] + 绝对定位字幕轨（cue 末端 9.0）。主轨初始 9.0s，合法。
    private func planWithCaption() -> EditPlan {
        let a = videoAsset("a.mp4"), b = videoAsset("b.mp4")
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(clip(a.id, 0...6)))),
            PlanElement(content: .content(TrackPayload(clip(b.id, 0...3)))),
        ])
        let caption = PlanTrack(kind: .caption, placement: .absolute,
                                settings: TrackPayload(CaptionTrackSettings()),
                                elements: [PlanElement(at: 8.0, content: .content(TrackPayload(
                                    CaptionCuePayload(text: "收尾", duration: 1.0))))])
        return EditPlan(assets: [a, b], tracks: [primary, caption], primaryTrackID: primary.id)
    }

    /// trim 缩短主轨 → 编辑成功，主轨自动补尾部 gap 到字幕轨末端。
    func testShrinkingMainTrackPadsTailGap() {
        let store = EditStore(initial: planWithCaption())
        XCTAssertEqual(store.plan.renderedDuration, 9.0, accuracy: 0.001)

        let result = store.apply { $0.updatePrimaryClip(at: 0) { $0.source = .video(0...4) } }

        guard case .success(let plan) = result else {
            return XCTFail("主轨变短应由尾部补 gap 消化，不应校验失败")
        }
        XCTAssertEqual(plan.renderedDuration, 9.0, accuracy: 0.001, "补到字幕轨末端")
        guard case .gap(let d) = plan.primaryTrack?.elements.last?.content else {
            return XCTFail("主轨末尾应补一个 gap 元素")
        }
        XCTAssertEqual(d, 2.0, accuracy: 0.001)
    }

    /// set_speed 缩短主轨 → 编辑成功，主轨自动补尾部 gap。
    func testSetSpeedShrinkingMainTrackPadsTailGap() {
        let store = EditStore(initial: planWithCaption())

        // A 6s @2x → 3s：主轨变 6.0s → 补到字幕轨末端 9.0s
        let result = store.apply { $0.updatePrimaryClip(at: 0) { $0.speed = .flat(2.0) } }

        guard case .success(let plan) = result else { return XCTFail("应变速成功") }
        XCTAssertEqual(plan.renderedDuration, 9.0, accuracy: 0.001)
        guard case .gap(let d) = plan.primaryTrack?.elements.last?.content else {
            return XCTFail("主轨末尾应补一个 gap 元素")
        }
        XCTAssertEqual(d, 3.0, accuracy: 0.001)
    }

    /// 删除「前一段挂着转场」的中间元素 → 前一段的转场被清掉，编辑成功。
    func testRemovingMiddleElementClearsPrecedingTransition() {
        let a = videoAsset("a.mp4"), b = videoAsset("b.mp4"), c = videoAsset("c.mp4")
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(clip(a.id, 0...3, transitionAfter: .dissolve(duration: 0.5))))),
            PlanElement(content: .content(TrackPayload(clip(b.id, 0...3)))),
            PlanElement(content: .content(TrackPayload(clip(c.id, 0...3)))),
        ])
        let plan = EditPlan(assets: [a, b, c], tracks: [primary], primaryTrackID: primary.id)
        let store = EditStore(initial: plan)
        let bID = plan.primaryTrack!.elements[1].id

        let result = store.apply { TrackOperations.removeElement(bID, in: &$0) }

        guard case .success(let after) = result else { return XCTFail("删除中间元素应成功") }
        XCTAssertNil(after.primaryTrack?.elements[0].content.clipPayload?.transitionAfter,
                     "前一段的转场应被归一化清掉（其后已变成 gap）")
        guard case .gap = after.primaryTrack?.elements[1].content else {
            return XCTFail("被删的中间元素应留等长 gap")
        }
    }

    /// 删除末位元素且新末位挂着转场 → 新末位的转场被清掉，编辑成功。
    func testRemovingLastElementClearsNewLastTransition() {
        let a = videoAsset("a.mp4"), b = videoAsset("b.mp4")
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .content(TrackPayload(clip(a.id, 0...3, transitionAfter: .dissolve(duration: 0.5))))),
            PlanElement(content: .content(TrackPayload(clip(b.id, 0...3)))),
        ])
        let plan = EditPlan(assets: [a, b], tracks: [primary], primaryTrackID: primary.id)
        let store = EditStore(initial: plan)
        let bID = plan.primaryTrack!.elements[1].id

        let result = store.apply { TrackOperations.removeElement(bID, in: &$0) }

        guard case .success(let after) = result else { return XCTFail("删除末位元素应成功") }
        XCTAssertNil(after.primaryTrack?.elements[0].content.clipPayload?.transitionAfter,
                     "新末位（A）的转场应被归一化清掉")
    }
}
