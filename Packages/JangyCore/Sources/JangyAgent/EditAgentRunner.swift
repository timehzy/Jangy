import AnyLanguageModel
import Foundation
import JangyCore

/// Agent 运行配置。
public struct AgentRunConfiguration: Sendable {
    /// 模型 ID（如 claude-sonnet-5-5）。
    public var model: String
    /// API base URL（缺省官方；公司网关在此覆盖）。
    public var baseURL: URL?
    public var apiKey: String
    /// 最大轮次：一轮 = 一次模型响应（内含的自动 tool loop 不计轮次，另有工具步数上限兜底）。
    public var maxTurns: Int
    /// 单次响应 token 上限。思维链模型（如 K2.8 thinking-only）会先烧思考预算，
    /// 框架缺省 1024 极易在思考中途截断 → 空响应静默收尾，必须放大。
    public var maxResponseTokens: Int

    public init(model: String, baseURL: URL? = nil, apiKey: String, maxTurns: Int = 10,
                maxResponseTokens: Int = 32768) {
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.maxTurns = maxTurns
        self.maxResponseTokens = maxResponseTokens
    }
}

public enum AgentRunError: Error, Equatable {
    /// 轮次耗尽仍未收尾（显式报错，不像参考实现那样静默退出）。
    case turnLimitExceeded(turns: Int)
    /// 空响应催促后仍为空（模型静默，通常是 token 预算或端点异常）。
    case emptyResponse
}

/// 编排层：agent loop。单轮任务制——一次 run 一个自然语言指令。
///
/// 注意 AnyLanguageModel 的 Anthropic provider **不在 respond 内续轮**：
/// 一次 respond = 一次 HTTP 请求，工具执行完（结果入 transcript）即返回，
/// 续轮是调用方的职责。因此本 outer loop 就是 agent loop 本体：续轮、
/// 轮次上限、快照图片回喂（tool result 不能带图，下一轮 respond 附图）、终止判定、事件发射。
public final class EditAgentRunner {
    private let context: AgentRunContext
    private let configuration: AgentRunConfiguration
    private let hasInitialPlan: Bool
    private let onEvent: (AgentEvent) -> Void

    public init(context: AgentRunContext, configuration: AgentRunConfiguration,
                hasInitialPlan: Bool, onEvent: @escaping (AgentEvent) -> Void) {
        self.context = context
        self.configuration = configuration
        self.hasInitialPlan = hasInitialPlan
        self.onEvent = onEvent
    }

    /// 跑完返回消耗轮次。LLM 接入错误（key/网络/API）原样抛出，由调用方归类。
    @discardableResult
    public func run(instruction: String) async throws -> Int {
        // 先落局部变量：AnthropicLanguageModel 的 apiKey 是 @Sendable autoclosure，
        // 直接引用 self.configuration 会触发隐式 self 捕获（非 Sendable）
        let apiKey = configuration.apiKey
        let modelName = configuration.model
        let model: AnthropicLanguageModel
        if let baseURL = configuration.baseURL {
            model = AnthropicLanguageModel(baseURL: baseURL, apiKey: apiKey, model: modelName)
        } else {
            model = AnthropicLanguageModel(apiKey: apiKey, model: modelName)
        }

        let session = LanguageModelSession(
            model: model,
            tools: AgentToolSet.make(context: context),
            instructions: AgentPromptBuilder.instructions(hasInitialPlan: hasInitialPlan)
        )
        let forwarder = EventForwarder(onEvent: onEvent)
        session.toolExecutionDelegate = forwarder

        var prompt = instruction
        var images: [Transcript.ImageSegment] = []
        var nudged = false
        let options = GenerationOptions(maximumResponseTokens: configuration.maxResponseTokens)
        for turn in 1...configuration.maxTurns {
            forwarder.beginTurn(turn)
            let response: LanguageModelSession.Response<String>
            if images.isEmpty {
                response = try await session.respond(to: prompt, options: options)
            } else {
                response = try await session.respond(to: prompt, images: images, options: options)
            }
            onEvent(.assistant(turn: turn, content: response.content))

            // 终止判定优先级：待回喂快照 > 工具续轮 > 文字收尾 > 空响应催促
            let pending = context.drainSnapshots()
            if !pending.isEmpty {
                images = pending.map { Transcript.ImageSegment(data: $0.pngData, mimeType: "image/png") }
                prompt = "以上图片是当前时间线在指定时刻的真实渲染画面（导出保真，含字幕烧录）。请检查是否符合用户预期：符合则用文字总结收尾；不符合则继续调用工具修正。"
                continue
            }

            // 本轮有工具调用 = 结果刚入 transcript、模型还没看到，必须续轮让它消化
            if forwarder.madeToolCallsThisTurn() {
                images = []
                prompt = "工具已执行完毕，结果已返回。请继续：任务未完成则继续调用工具，已完成则用文字总结编辑结果。"
                continue
            }

            let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { return turn }

            // 空响应且无工具调用 = 模型静默：催一次，再空显式报错
            guard !nudged else { throw AgentRunError.emptyResponse }
            nudged = true
            prompt = "你的上一次响应为空。请继续完成任务：调用编辑工具，或用文字总结当前编辑结果。"
            images = []
        }
        throw AgentRunError.turnLimitExceeded(turns: configuration.maxTurns)
    }
}

/// 框架 delegate → AgentEvent 的转发器（JSONL 事件流的发射点）。
private final class EventForwarder: ToolExecutionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var turn = 0
    private var madeToolCalls = false
    private let onEvent: (AgentEvent) -> Void

    init(onEvent: @escaping (AgentEvent) -> Void) {
        self.onEvent = onEvent
    }

    func beginTurn(_ turn: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.turn = turn
        madeToolCalls = false
    }

    private func currentTurn() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return turn
    }

    func madeToolCallsThisTurn() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return madeToolCalls
    }

    func didGenerateToolCalls(_ toolCalls: [Transcript.ToolCall], in session: LanguageModelSession) async {
        let turn = lock.withLock {
            madeToolCalls = true
            return self.turn
        }
        for call in toolCalls {
            onEvent(.toolCall(turn: turn, name: call.toolName, arguments: call.arguments.jsonString))
        }
    }

    func didExecuteToolCall(_ toolCall: Transcript.ToolCall, output: Transcript.ToolOutput, in session: LanguageModelSession) async {
        let (status, summary) = Self.summarize(output)
        onEvent(.toolResult(turn: currentTurn(), name: toolCall.toolName, status: status, summary: summary))
    }

    func didFailToolCall(_ toolCall: Transcript.ToolCall, error: any Error, in session: LanguageModelSession) async {
        onEvent(.toolResult(turn: currentTurn(), name: toolCall.toolName, status: "error",
                            summary: "工具执行异常: \(error.localizedDescription)"))
    }

    /// 从工具输出提取信封 status（我们的工具返回 {"status":"ok"|"error"} JSON）与摘要文本。
    private static func summarize(_ output: Transcript.ToolOutput) -> (status: String, summary: String) {
        let text = output.segments.compactMap { segment -> String? in
            switch segment {
            case .text(let textSegment):
                return textSegment.content
            case .structure(let structured):
                // String 输出会被框架收进 structure 段（String 是 ConvertibleToGeneratedContent），还原原始字符串
                if let string = try? String(structured.content) { return string }
                return structured.content.jsonString
            case .image:
                return nil
            }
        }.joined(separator: " ")

        struct EnvelopeHead: Decodable { let status: String? }
        let status = (try? JSONDecoder().decode(EnvelopeHead.self, from: Data(text.utf8)))?.status ?? "ok"
        let summary = text.count > 500 ? String(text.prefix(500)) + "…" : text
        return (status, summary)
    }
}
