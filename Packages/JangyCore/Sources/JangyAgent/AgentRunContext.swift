import Foundation
import JangyCore

/// 单次 Agent 任务的共享态：所有工具执行的出入口。
///
/// AnyLanguageModel 约定 `Tool.call` 可并发触发，而 `EditStore` 是单线程约定——
/// 这里用一把锁串行化所有工具执行（headless 单任务，无争用性能诉求）。
public final class AgentRunContext: @unchecked Sendable {

    /// 快照帧：snapshot 工具产物，落盘 + 排队等待回喂给模型。
    public struct SnapshotFrame: Sendable {
        public let at: TimeInterval
        public let url: URL
        public let pngData: Data

        public init(at: TimeInterval, url: URL, pngData: Data) {
            self.at = at
            self.url = url
            self.pngData = pngData
        }
    }

    public let resolver: AssetResolver
    /// 快照 PNG 落盘目录（CLI --frames；缺省临时目录）。
    public let framesDirectory: URL
    /// 工具调用步数上限：防自动 tool loop 失控的框架无关兜底。
    public let maxToolCalls: Int

    private let store: EditStore
    private let lock = NSLock()
    private var pendingSnapshots: [SnapshotFrame] = []
    private var toolCallCount = 0

    public init(plan: EditPlan, resolver: AssetResolver, framesDirectory: URL, maxToolCalls: Int = 30) {
        self.store = EditStore(initial: plan)
        self.resolver = resolver
        self.framesDirectory = framesDirectory
        self.maxToolCalls = maxToolCalls
    }

    /// 当前 plan（锁内读）。
    public var plan: EditPlan {
        locked { $0.plan }
    }

    /// 在锁内执行编辑/读取，工具实现统一走这里（EditStore.apply 的唯一触达点）。
    @discardableResult
    public func locked<T>(_ body: (EditStore) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(store)
    }

    /// 步数闸门：每次工具执行前调用；返回 false 表示已超限，工具应返回「请收尾」而不执行。
    public func admitToolCall() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        toolCallCount += 1
        return toolCallCount <= maxToolCalls
    }

    public func enqueueSnapshots(_ frames: [SnapshotFrame]) {
        lock.lock()
        defer { lock.unlock() }
        pendingSnapshots.append(contentsOf: frames)
    }

    /// 取出并清空待回喂快照（outer loop 附图后轮清空）。
    public func drainSnapshots() -> [SnapshotFrame] {
        lock.lock()
        defer { lock.unlock() }
        defer { pendingSnapshots.removeAll() }
        return pendingSnapshots
    }
}
