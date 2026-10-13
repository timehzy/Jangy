import Foundation

/// 整树快照撤销栈。Swift 值类型 + Copy-on-Write 使快照近乎零成本，
/// POC 不做增量快照与命令合并（YAGNI）。
public struct UndoStack: Equatable, Sendable {
    public private(set) var snapshots: [EditPlan]
    public private(set) var index: Int
    public let limit: Int

    public init(initial: EditPlan, limit: Int = 100) {
        self.snapshots = [initial]
        self.index = 0
        self.limit = limit
    }

    public var current: EditPlan { snapshots[index] }
    public var canUndo: Bool { index > 0 }
    public var canRedo: Bool { index < snapshots.count - 1 }

    /// push 语义：截断 index 之后的 redo 分支，再追加；超出 limit 淘汰最旧。
    public mutating func push(_ snapshot: EditPlan) {
        snapshots = Array(snapshots[...index])
        snapshots.append(snapshot)
        if snapshots.count > limit {
            snapshots.removeFirst(snapshots.count - limit)
        }
        index = snapshots.count - 1
    }

    @discardableResult
    public mutating func undo() -> EditPlan? {
        guard canUndo else { return nil }
        index -= 1
        return current
    }

    @discardableResult
    public mutating func redo() -> EditPlan? {
        guard canRedo else { return nil }
        index += 1
        return current
    }
}
