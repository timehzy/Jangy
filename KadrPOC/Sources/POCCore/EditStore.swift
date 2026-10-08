import Foundation

/// Result 的 Failure 必须遵循 Error；校验结果以数组承载，故补条件一致性。
extension Array: @retroactive Error where Element == ValidationIssue {}

/// 编辑状态层入口：持有当前快照，所有编辑操作 = 产出新快照压栈。
/// 校验失败 = 不产出新快照 = 栈不变（快照模型天然是事务语义）。
@Observable
public final class EditStore {
    public private(set) var plan: EditPlan
    private var undoStack: UndoStack
    private let validator = EditPlanValidator()

    public init(initial: EditPlan) {
        self.plan = initial
        self.undoStack = UndoStack(initial: initial)
    }

    public var canUndo: Bool { undoStack.canUndo }
    public var canRedo: Bool { undoStack.canRedo }
    public var historyCount: Int { undoStack.snapshots.count }

    @discardableResult
    public func apply(_ mutate: (inout EditPlan) -> Void) -> Result<EditPlan, [ValidationIssue]> {
        var next = plan
        mutate(&next)
        let issues = validator.validate(next)
        guard issues.isEmpty else { return .failure(issues) }
        undoStack.push(next)
        plan = next
        return .success(next)
    }

    public func undo() {
        if let restored = undoStack.undo() { plan = restored }
    }

    public func redo() {
        if let restored = undoStack.redo() { plan = restored }
    }

    /// 与 CLI `sample` 子命令、Agent 契约同一份序列化格式。
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(plan), as: UTF8.self)
    }
}
