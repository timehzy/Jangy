import XCTest
@testable import POCCore

final class UndoStackTests: XCTestCase {

    /// 注意：PlanClip.id 缺省为随机 UUID，同一 marker 两次调用产生的实例不相等，
    /// 因此各测试先把实例捕获到局部常量再做相等断言。
    private func plan(_ marker: String) -> EditPlan {
        EditPlan(clips: [PlanClip(source: MediaRef(fileName: marker), range: 0...1)])
    }

    func testInitialState() {
        let a = plan("a")
        let stack = UndoStack(initial: a)
        XCTAssertEqual(stack.current, a)
        XCTAssertFalse(stack.canUndo)
        XCTAssertFalse(stack.canRedo)
    }

    func testPushAdvancesCurrent() {
        let a = plan("a")
        let b = plan("b")
        var stack = UndoStack(initial: a)
        stack.push(b)
        XCTAssertEqual(stack.current, b)
        XCTAssertTrue(stack.canUndo)
        XCTAssertEqual(stack.snapshots.count, 2)
    }

    func testUndoRedo() {
        let a = plan("a")
        let b = plan("b")
        var stack = UndoStack(initial: a)
        stack.push(b)
        XCTAssertEqual(stack.undo(), a)
        XCTAssertTrue(stack.canRedo)
        XCTAssertEqual(stack.redo(), b)
        XCTAssertFalse(stack.canRedo)
    }

    func testUndoAtStartReturnsNil() {
        let a = plan("a")
        var stack = UndoStack(initial: a)
        XCTAssertNil(stack.undo())
        XCTAssertEqual(stack.current, a)
    }

    func testPushTruncatesRedoBranch() {
        let a = plan("a")
        let b = plan("b")
        let c = plan("c")
        let d = plan("d")
        var stack = UndoStack(initial: a)
        stack.push(b)
        stack.push(c)
        stack.undo()                       // 回到 b
        stack.push(d)                      // c 被截断
        XCTAssertEqual(stack.snapshots, [a, b, d])
        XCTAssertFalse(stack.canRedo)
    }

    func testLimitEvictsOldest() {
        let s0 = plan("s0")
        let s2 = plan("s2")
        let s4 = plan("s4")
        var stack = UndoStack(initial: s0, limit: 3)
        stack.push(plan("s1"))
        stack.push(s2)
        stack.push(plan("s3"))
        stack.push(s4)
        XCTAssertEqual(stack.snapshots.count, 3)
        XCTAssertEqual(stack.snapshots.first, s2)   // s0、s1 被淘汰
        XCTAssertEqual(stack.current, s4)
        XCTAssertTrue(stack.canUndo)
    }

    func testDefaultLimitIs100() {
        let stack = UndoStack(initial: plan("a"))
        XCTAssertEqual(stack.limit, 100)
    }
}
