import Foundation
import JangyCore

/// EditStore 触碰点调度器：把「访问 store 的闭包」送到 store 所属的执行域。
/// CLI/测试 = DirectStoreScheduler 原地直通；App = MainActorStoreScheduler 回跳主 actor
///（共享的 EditStore 被 @Observable/SwiftUI 订阅，变更必须发生在主线程）。
/// 串行性依据：provider 顺序执行工具调用（逐个 await）+ MainActor 本身串行，
/// 因此 store 访问不再需要锁串行化。
public protocol AgentStoreScheduler: Sendable {
    func run<T: Sendable>(on context: AgentRunContext,
                          work: @Sendable (EditStore) throws -> T) async rethrows -> T
}

/// CLI/测试用：当前线程原地执行。
/// 硬前提：依赖调用方顺序执行（Anthropic provider 逐个 await 工具调用）；
/// 并发调用方禁用此调度器（无串行化保护，并发触碰 EditStore 是数据竞争）。
public struct DirectStoreScheduler: AgentStoreScheduler {
    public init() {}
    public func run<T: Sendable>(on context: AgentRunContext,
                                 work: @Sendable (EditStore) throws -> T) async rethrows -> T {
        try work(context.store)
    }
}

/// App 用：回跳 MainActor（共享 AppModel 持有的 EditStore 时必选）。
public struct MainActorStoreScheduler: AgentStoreScheduler {
    public init() {}
    public func run<T: Sendable>(on context: AgentRunContext,
                                 work: @Sendable (EditStore) throws -> T) async rethrows -> T {
        try await MainActor.run { try work(context.store) }
    }
}

/// 单次 Agent 任务的共享态：所有工具执行的出入口。
///
/// EditStore 为注入（App 共享 AppModel 那份；CLI 自建临时份）。
/// store 的唯一触碰点是 withStore——经调度器进入 store 所属执行域，
/// 块尾比对 plan，变了则同步触发 didApply（App 接预览重建 + autosave）。
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
    /// plan 变化回调：在调度块内同步触发（App 侧天然已在 MainActor）。
    private let didApply: (@Sendable (EditPlan) -> Void)?

    /// 仅经 scheduler 触碰；internal 供同模块调度器实现访问。
    let store: EditStore
    private let scheduler: any AgentStoreScheduler

    /// 只护 pendingSnapshots / toolCallCount 两个同步小区间。
    private let lock = NSLock()
    private var pendingSnapshots: [SnapshotFrame] = []
    private var toolCallCount = 0

    public init(store: EditStore, resolver: AssetResolver, framesDirectory: URL,
                maxToolCalls: Int = 30,
                scheduler: any AgentStoreScheduler = DirectStoreScheduler(),
                didApply: (@Sendable (EditPlan) -> Void)? = nil) {
        self.store = store
        self.resolver = resolver
        self.framesDirectory = framesDirectory
        self.maxToolCalls = maxToolCalls
        self.scheduler = scheduler
        self.didApply = didApply
    }

    /// 便利构造（CLI/测试）：自建临时 EditStore，原地直通调度。
    public convenience init(plan: EditPlan, resolver: AssetResolver, framesDirectory: URL,
                            maxToolCalls: Int = 30) {
        self.init(store: EditStore(initial: plan), resolver: resolver,
                  framesDirectory: framesDirectory, maxToolCalls: maxToolCalls)
    }

    /// 当前 plan（经调度器读）。
    public var plan: EditPlan {
        get async { await withStore { $0.plan } }
    }

    /// 调度到 store 执行域执行读/写复合操作；块内 plan 发生变化则在块尾同步触发 didApply。
    /// 注意：闭包同步、不可 await（snapshot 渲染等异步工作放块外做）。
    @discardableResult
    public func withStore<T: Sendable>(_ work: @Sendable (EditStore) throws -> T) async rethrows -> T {
        try await scheduler.run(on: self) { [didApply] store in
            let before = store.plan
            let result = try work(store)
            let after = store.plan
            if after != before { didApply?(after) }
            return result
        }
    }

    /// 步数闸门：每次工具执行前调用；返回 false 表示已超限，工具应返回「请收尾」而不执行。
    public func admitToolCall() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        toolCallCount += 1
        return toolCallCount <= maxToolCalls
    }

    /// 每条指令开始时重置步数计数（上限语义 = 防单次指令失控的兜底，不跨指令累计）。
    /// 由 session 层在每条指令（send）开始时调用。
    public func resetToolCallCount() {
        lock.lock()
        defer { lock.unlock() }
        toolCallCount = 0
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
