import Foundation

/// 编辑状态层入口：持有当前快照，所有编辑操作 = 产出新快照压栈。
/// 校验失败 = 不产出新快照 = 栈不变（快照模型天然是事务语义）。
/// 线程约定：主线程使用；POC 不做并发编辑。
@Observable
public final class EditStore {
    public private(set) var plan: EditPlan
    private var undoStack: UndoStack
    private let validator = EditPlanValidator()

    public init(initial: EditPlan) {
        self.plan = initial
        self.undoStack = UndoStack(initial: initial)
    }

    public var canUndo: Bool { groupBase == nil && undoStack.canUndo }
    public var canRedo: Bool { groupBase == nil && undoStack.canRedo }
    public var historyCount: Int { undoStack.snapshots.count }

    /// 分组事务基线：非 nil 表示处于分组中，组内 apply 不压撤销栈。
    private var groupBase: EditPlan?

    /// 是否处于分组事务中（UI 据此禁用撤销/重做等编辑入口）。
    public var isGrouping: Bool { groupBase != nil }

    /// 开始分组事务：组内 apply 照常校验、照常改 plan，但不压撤销栈；
    /// endGrouping 时若 plan 相对基线有变化，压一个撤销步。
    /// 不嵌套：分组中再次调用为 no-op。
    public func beginGrouping() {
        guard groupBase == nil else { return }
        groupBase = plan
    }

    /// 结束分组事务：plan 有变化则压一步；无变化（空组/全失败）不压。
    public func endGrouping() {
        guard let base = groupBase else { return }
        groupBase = nil
        if plan != base { undoStack.push(plan) }
    }

    @discardableResult
    public func apply(_ mutate: (inout EditPlan) -> Void) -> Result<EditPlan, ValidationFailure> {
        var next = plan
        mutate(&next)

        // 结构变化后的不变式维持与归一化，**只在这一处做**：
        // EditStore.apply 是唯一写入口，放这里任何编辑都绕不开。
        // 散到各工具 / UI 动作里就是「隐式约定散落多处，漏改一处就复发」——
        // 它已经复发过一次（trim/speed 让主轨变短却没人补 gap，编辑静默失败）。
        // 顺序：先补尾部 gap（会改 renderedDuration），再归一化 payload。
        TrackOperations.maintainInvariants(in: &next)
        TrackOperations.normalizePayloads(in: &next)

        let issues = validator.validate(next)
        guard issues.isEmpty else { return .failure(ValidationFailure(issues: issues)) }
        if groupBase == nil { undoStack.push(next) }  // 组内不压栈，endGrouping 统一收
        plan = next
        return .success(next)
    }

    public func undo() {
        guard groupBase == nil else { return }
        if let restored = undoStack.undo() { plan = restored }
    }

    public func redo() {
        guard groupBase == nil else { return }
        if let restored = undoStack.redo() { plan = restored }
    }

    /// 与 CLI `sample` 子命令、Agent 契约同一份序列化格式。
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(plan), as: UTF8.self)
    }
}
