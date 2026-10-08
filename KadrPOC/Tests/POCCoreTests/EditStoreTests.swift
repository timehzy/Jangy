import XCTest
@testable import POCCore

final class EditStoreTests: XCTestCase {

    private func initialPlan() -> EditPlan {
        EditPlan(clips: [PlanClip(source: MediaRef(fileName: "clip1.mp4"), range: 0...3)])
    }

    func testApplyValidMutationPushesSnapshot() {
        let store = EditStore(initial: initialPlan())
        let result = store.apply { $0.clips[0].speed = .flat(0.5) }
        guard case .success = result else { return XCTFail("应成功") }
        XCTAssertEqual(store.plan.clips[0].speed, .flat(0.5))
        XCTAssertTrue(store.canUndo)
    }

    func testApplyInvalidMutationIsTransactional() {
        let initial = initialPlan()          // 修复 UUID 陷阱：捕获同一实例
        let store = EditStore(initial: initial)
        let result = store.apply { $0.clips[0].speed = .flat(99) }
        guard case .failure(let issues) = result else { return XCTFail("应失败") }
        XCTAssertEqual(issues.map(\.path), ["clips[0].speed"])
        // 事务语义：失败 = 什么都没发生
        XCTAssertEqual(store.plan, initial)
        XCTAssertFalse(store.canUndo)
    }

    func testUndoRedoRestoresPlan() {
        let initial = initialPlan()          // 修复 UUID 陷阱：捕获同一实例
        let store = EditStore(initial: initial)
        store.apply { $0.clips[0].speed = .flat(0.5) }
        store.undo()
        XCTAssertEqual(store.plan, initial)
        store.redo()
        XCTAssertEqual(store.plan.clips[0].speed, .flat(0.5))
    }

    func testJSONRoundTrip() throws {
        let store = EditStore(initial: initialPlan())
        let json = try store.json()
        let decoded = try JSONDecoder().decode(EditPlan.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, store.plan)  // 与 store 当前快照比较（同一实例），避免 UUID 陷阱
    }
}
