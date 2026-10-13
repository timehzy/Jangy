import Foundation

/// Agent 运行事件：CLI stdout 的 JSONL 契约（每事件一行，日志走 stderr）。
public enum AgentEvent: Encodable, Sendable {
    public enum ErrorKind: String, Encodable, Sendable {
        case llm
        case validation
        case engine
        case turnLimit = "turn_limit"
    }

    case start(instruction: String, model: String, hasInitialPlan: Bool)
    case assistant(turn: Int, content: String)
    case toolCall(turn: Int, name: String, arguments: String)
    case toolResult(turn: Int, name: String, status: String, summary: String)
    case snapshot(turn: Int, at: TimeInterval, path: String)
    case done(turns: Int, planPath: String?, exported: String?)
    case error(kind: ErrorKind, message: String)

    private enum CodingKeys: String, CodingKey {
        case event, instruction, model, hasInitialPlan, turn, content, name, arguments, status, summary, turns, planPath, exported, kind, message, at, path
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .start(let instruction, let model, let hasInitialPlan):
            try container.encode("start", forKey: .event)
            try container.encode(instruction, forKey: .instruction)
            try container.encode(model, forKey: .model)
            try container.encode(hasInitialPlan, forKey: .hasInitialPlan)
        case .assistant(let turn, let content):
            try container.encode("assistant", forKey: .event)
            try container.encode(turn, forKey: .turn)
            try container.encode(content, forKey: .content)
        case .toolCall(let turn, let name, let arguments):
            try container.encode("tool_call", forKey: .event)
            try container.encode(turn, forKey: .turn)
            try container.encode(name, forKey: .name)
            try container.encode(arguments, forKey: .arguments)
        case .toolResult(let turn, let name, let status, let summary):
            try container.encode("tool_result", forKey: .event)
            try container.encode(turn, forKey: .turn)
            try container.encode(name, forKey: .name)
            try container.encode(status, forKey: .status)
            try container.encode(summary, forKey: .summary)
        case .snapshot(let turn, let at, let path):
            try container.encode("snapshot", forKey: .event)
            try container.encode(turn, forKey: .turn)
            try container.encode(at, forKey: .at)
            try container.encode(path, forKey: .path)
        case .done(let turns, let planPath, let exported):
            try container.encode("done", forKey: .event)
            try container.encode(turns, forKey: .turns)
            try container.encodeIfPresent(planPath, forKey: .planPath)
            try container.encodeIfPresent(exported, forKey: .exported)
        case .error(let kind, let message):
            try container.encode("error", forKey: .event)
            try container.encode(kind, forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }
}
