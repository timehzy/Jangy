import XCTest
@testable import POCCore

final class EditStoreTests: XCTestCase {

    private func initialPlan() -> EditPlan {
        let assetID = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
        return EditPlan(
            assets: [AssetItem(id: assetID, kind: .video, fileName: "clip1.mp4", duration: 4.0)],
            clips: [PlanClip(assetID: assetID, range: 0...3)]
        )
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
        guard case .failure(let failure) = result else { return XCTFail("应失败") }
        XCTAssertEqual(failure.issues.map(\.path), ["clips[0].speed"])
        // 事务语义：失败 = 什么都没发生
        XCTAssertEqual(store.plan, initial)
        XCTAssertFalse(store.canUndo)
        XCTAssertEqual(store.historyCount, 1)  // 栈未被触碰的直接证据
    }

    func testApplyDanglingAssetReferenceFails() {
        let initial = initialPlan()
        let store = EditStore(initial: initial)
        let result = store.apply { $0.clips.append(PlanClip(assetID: UUID(), range: 0...1)) }
        guard case .failure(let failure) = result else { return XCTFail("应失败") }
        XCTAssertEqual(failure.issues.map(\.path), ["clips[1].assetID"])
        XCTAssertEqual(store.plan, initial)
    }

    /// 导入流程的关键路径：同一次 apply 里登记素材 + 追加引用它的片段（单撤销步）。
    func testApplyRegistersAssetAndClipAtomically() {
        let store = EditStore(initial: initialPlan())
        let newAsset = AssetItem(kind: .video, fileName: "imported.mp4", duration: 6.0)
        let result = store.apply {
            $0.assets.append(newAsset)
            $0.clips.append(PlanClip(assetID: newAsset.id, range: 0...6))
        }
        guard case .success = result else { return XCTFail("应成功") }
        XCTAssertEqual(store.plan.assets.count, 2)
        XCTAssertEqual(store.plan.clips.count, 2)
        store.undo()
        XCTAssertEqual(store.plan.assets.count, 1)
        XCTAssertEqual(store.plan.clips.count, 1)
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
