import Foundation
import JangyAgent
import JangyCore

/// 对话流条目：IM 形态渲染的数据源。
struct AgentChatItem: Identifiable {
    enum Content {
        case user(String)
        case assistant(String)
        /// 工具卡片：name + 参数摘要；status 由 toolResult 事件回填（pending → ok/error）
        case tool(name: String, summary: String, status: Status)
        case snapshot(path: String, at: TimeInterval)
        case done(turns: Int)
        case error(String)
        case stopped
    }
    enum Status { case pending, ok, error }
    let id = UUID()
    var content: Content
}

/// 剪辑 Agent 的 App 侧装配（L1）：session 生命周期、分组撤销边界、事件流 → 对话模型。
/// 连续对话：session lazy 创建后长活（内存态，不持久化——spec 拍板 #5）。
@MainActor
@Observable
final class AgentController {
    private(set) var items: [AgentChatItem] = []
    private(set) var isRunning = false
    let isConfigured: Bool

    private let store: EditStore
    private let resolver: AssetResolver
    private let credentials: AgentCredentials?
    /// plan 变化联动（AppModel 注入：预览重建 + autosave）
    private let onAppliedEdit: () -> Void
    private var session: EditAgentSession?
    private var runTask: Task<Void, Never>?
    /// 待回填状态的工具卡片：key = turn:name，值 FIFO 队列——同一轮同名工具可多次调用，
    /// 单值会被覆盖导致卡片状态交叉，故一对多、toolResult 取最旧匹配。
    private var pendingToolItems: [String: [UUID]] = [:]

    init(store: EditStore, resolver: AssetResolver, credentials: AgentCredentials?,
         onAppliedEdit: @escaping () -> Void) {
        self.store = store
        self.resolver = resolver
        self.credentials = credentials
        self.isConfigured = credentials != nil
        self.onAppliedEdit = onAppliedEdit
    }

    func send(_ text: String) {
        let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !isRunning, let credentials else { return }
        // baseURL 解析失败不再静默回退官方端点：显式报错，避免把真实流量打到错误端点之外的地方
        if let baseURLString = credentials.baseURL, URL(string: baseURLString) == nil {
            items.append(AgentChatItem(content: .error("凭据 baseURL 格式错误：\(baseURLString)")))
            return
        }
        // 清掉上一轮（可能因取消残留）的 pending 条目，避免脏键串扰本轮回填
        pendingToolItems.removeAll()
        items.append(AgentChatItem(content: .user(instruction)))
        isRunning = true
        // 整任务一步撤销（spec 拍板 #1）：分组边界 = 一条指令的完整 run。
        // 契约：分组期间的手动编辑会并入本组撤销步，正确性依赖 UI 层在运行中
        // 禁用全部编辑入口（Task 7 接线，store.isGrouping 已为此暴露）。
        store.beginGrouping()
        let session = self.session ?? makeSession(credentials: credentials)
        self.session = session
        runTask = Task { @MainActor in
            defer {
                store.endGrouping()
                isRunning = false
            }
            do {
                let turns = try await session.send(instruction)
                items.append(AgentChatItem(content: .done(turns: turns)))
            } catch is CancellationError {
                items.append(AgentChatItem(content: .stopped))
            } catch AgentRunError.turnLimitExceeded(let limit) {
                items.append(AgentChatItem(content: .error("轮次耗尽（\(limit)）仍未收尾，已生效的编辑可用「撤销」整体回退")))
            } catch {
                items.append(AgentChatItem(content: .error("LLM 接入错误：\(error.localizedDescription)")))
            }
        }
    }

    func stop() {
        runTask?.cancel()
    }

    private func makeSession(credentials: AgentCredentials) -> EditAgentSession {
        let context = AgentRunContext(
            store: store,
            resolver: resolver,
            framesDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("jangy-agent-frames", isDirectory: true),
            scheduler: MainActorStoreScheduler(),
            didApply: { [onAppliedEdit] _ in
                // didApply 在 MainActor 调度块内同步触发，直接联动即可
                MainActor.assumeIsolated { onAppliedEdit() }
            }
        )
        return EditAgentSession(
            context: context,
            configuration: AgentRunConfiguration(
                model: credentials.model,
                baseURL: credentials.baseURL.flatMap { URL(string: $0) },
                apiKey: credentials.apiKey
            ),
            hasInitialPlan: !store.plan.clips.isEmpty,
            onEvent: { [weak self] event in
                // 事件顺序依赖 MainActor 队列 FIFO（发射端串行发射）：
                // toolResult 对 toolCall 卡片的回填依赖此保序，换并发分发会交叉。
                Task { @MainActor in self?.handle(event) }
            }
        )
    }

    /// AgentEvent → 对话流条目（事件从后台线程来，已在 send/makeSession 处归一 MainActor）。
    private func handle(_ event: AgentEvent) {
        switch event {
        case .start:
            break
        case .assistant(_, let content):
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { items.append(AgentChatItem(content: .assistant(text))) }
        case .toolCall(let turn, let name, let arguments):
            let item = AgentChatItem(content: .tool(name: name,
                                                    summary: Self.truncate(arguments),
                                                    status: .pending))
            items.append(item)
            pendingToolItems["\(turn):\(name)", default: []].append(item.id)
        case .toolResult(let turn, let name, let status, let summary):
            let key = "\(turn):\(name)"
            guard var pending = pendingToolItems[key], !pending.isEmpty,
                  let id = pending.first else { return }
            pending.removeFirst()
            pendingToolItems[key] = pending.isEmpty ? nil : pending
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].content = .tool(name: name, summary: Self.truncate(summary),
                                         status: status == "ok" ? .ok : .error)
        case .snapshot(_, let at, let path):
            items.append(AgentChatItem(content: .snapshot(path: path, at: at)))
        case .done:
            break  // CLI 契约事件；App 侧由 send 的返回路径追加 done 卡片
        case .error(let kind, let message):
            items.append(AgentChatItem(content: .error("[\(kind.rawValue)] \(message)")))
        }
    }

    private static func truncate(_ text: String, limit: Int = 140) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
