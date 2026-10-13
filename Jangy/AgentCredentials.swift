import Foundation

/// Agent 凭据：开发期从 Application Support/Jangy/agent-config.json 读取（gitignore 手放播种，
/// 与 genassets 同套路）。产品化方案（自备 key / 网关代理 / App Attest）发布前再议。
/// JSON 格式：{"baseURL": "...", "model": "...", "apiKey": "..."}（baseURL 可缺省）
struct AgentCredentials: Codable {
    var baseURL: String?
    var model: String
    var apiKey: String

    static var fileName: String { "agent-config.json" }

    /// 缺失/损坏一律返回 nil（入口禁用态由调用方呈现），不炸启动。
    static func load(from directory: URL) -> AgentCredentials? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AgentCredentials.self, from: data)
    }
}
