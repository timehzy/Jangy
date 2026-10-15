import XCTest
@testable import JangyCore

/// 分组事务：组内 apply 照常校验/改 plan 但不压撤销栈；endGrouping 把整组收成一步。
/// 承载「一次 Agent 任务 = 一步撤销」（公约 §2.4 延伸，spec 拍板 #1）。
final class EditStoreGroupingTests: XCTestCase {

    private func initialPlan() -> EditPlan {
        let assetID = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
        return EditPlan(
            assets: [AssetItem(id: assetID, kind: .video, fileName: "clip1.mp4", duration: 4.0)],
            clips: [PlanClip(assetID: assetID, source: .video(0...3))]
        )
    }

    func testGroupCollapsesMultipleAppliesIntoOneUndoStep() {
        let store = EditStore(initial: initialPlan())
        let baselineCount = store.historyCount
        store.beginGrouping()
        XCTAssertTrue(store.isGrouping)
        store.apply { $0.clips[0].speed = .flat(0.5) }
        store.apply { $0.clips[0].source = .video(0...2) }
        XCTAssertEqual(store.historyCount, baselineCount, "组内 apply 不压栈")
        store.endGrouping()
        XCTAssertFalse(store.isGrouping)
        XCTAssertEqual(store.historyCount, baselineCount + 1, "整组只压一步")
        store.undo()
        XCTAssertEqual(store.plan.clips[0].speed, .flat(1.0), "一步撤销回退整组")
        XCTAssertEqual(store.plan.clips[0].source, .video(0...3))
    }

    func testFailedApplyInsideGroupPushesNothing() {
        let store = EditStore(initial: initialPlan())
        let baselineCount = store.historyCount
        store.beginGrouping()
        let result = store.apply { $0.clips[0].speed = .flat(99) }  // 越界，校验失败
        guard case .failure = result else { return XCTFail("应失败") }
        store.endGrouping()
        XCTAssertEqual(store.historyCount, baselineCount, "组内失败 apply 不留痕，空组不压步")
    }

    func testEmptyGroupPushesNothing() {
        let store = EditStore(initial: initialPlan())
        store.beginGrouping()
        store.endGrouping()
        XCTAssertEqual(store.historyCount, 1, "无 apply 的空组不压步")
    }

    func testUndoRedoIgnoredDuringGrouping() {
        let store = EditStore(initial: initialPlan())
        store.apply { $0.clips[0].speed = .flat(2.0) }
        let beforeGroup = store.plan
        store.beginGrouping()
        XCTAssertFalse(store.canUndo, "分组中 canUndo 报 false（UI 禁用绑定）")
        XCTAssertFalse(store.canRedo)
        store.undo()
        store.redo()
        XCTAssertEqual(store.plan, beforeGroup, "分组中 undo/redo 被忽略")
        store.endGrouping()
    }

    func testNestedBeginGroupingIsNoOp() {
        let store = EditStore(initial: initialPlan())
        store.beginGrouping()
        store.beginGrouping()  // 不嵌套：第二次调用无副作用
        store.apply { $0.clips[0].speed = .flat(0.5) }
        store.endGrouping()
        XCTAssertFalse(store.isGrouping)
        store.undo()
        XCTAssertEqual(store.plan.clips[0].speed, .flat(1.0))
    }
}
