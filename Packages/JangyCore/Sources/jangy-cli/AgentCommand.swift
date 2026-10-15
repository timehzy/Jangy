import ArgumentParser
import Foundation
import JangyAgent
import JangyCore

struct Agent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "剪辑 Agent：自然语言指令 → EditPlan（headless，LLM function calling）"
    )

    @Argument(help: "自然语言剪辑指令")
    var instruction: String

    @Option(help: "初始 EditPlan JSON 路径；缺省从空时间线起步")
    var plan: String?

    @Option(help: "素材目录，默认 ./Assets")
    var assets: String = "./Assets"

    @Option(help: "模型 ID，默认 claude-sonnet-5-5")
    var model: String = "claude-sonnet-5-5"

    @Option(help: "LLM API base URL（缺省官方；网关场景在此覆盖）")
    var baseURL: String?

    @Option(help: "最大轮次（一轮 = 一次模型响应），默认 10")
    var maxTurns: Int = 10

    @Option(help: "工具调用步数上限，默认 30")
    var maxToolCalls: Int = 30

    @Option(name: .shortAndLong, help: "最终 plan 输出路径（缺省不落盘）")
    var output: String?

    @Option(help: "任务完成后导出 mp4 到该路径")
    var export: String?

    @Option(help: "快照 PNG 输出目录，默认临时目录")
    var frames: String = FileManager.default.temporaryDirectory
        .appendingPathComponent("jangy-agent-frames", isDirectory: true).path

    mutating func run() async throws {
        let emit: (AgentEvent) -> Void = { event in
            try? JSONLines.print(event)
        }

        // 初始 plan：有路径则加载 + 校验（exit 1/2 与既有子命令同契约）；缺省空时间线起步
        let resolver = AssetResolver(directory: URL(fileURLWithPath: assets))
        let emptyPrimary = PlanTrack(kind: .video, placement: .chained)
        var initialPlan = EditPlan(tracks: [emptyPrimary], primaryTrackID: emptyPrimary.id)
        if let plan {
            (initialPlan, _) = try loadValidatedPlan(plan, assets: assets)
        }

        guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !apiKey.isEmpty else {
            CLIError.stderr("缺少 ANTHROPIC_API_KEY 环境变量")
            emit(.error(kind: .llm, message: "missing ANTHROPIC_API_KEY"))
            throw ExitCode(4)
        }

        emit(.start(instruction: instruction, model: model, hasInitialPlan: plan != nil))

        let context = AgentRunContext(
            plan: initialPlan,
            resolver: resolver,
            framesDirectory: URL(fileURLWithPath: frames),
            maxToolCalls: maxToolCalls
        )
        let session = EditAgentSession(
            context: context,
            configuration: AgentRunConfiguration(
                model: model,
                baseURL: baseURL.map { URL(string: $0) } ?? nil,
                apiKey: apiKey,
                maxTurns: maxTurns
            ),
            hasInitialPlan: plan != nil,
            onEvent: emit
        )

        let turns: Int
        do {
            turns = try await session.send(instruction)
        } catch AgentRunError.turnLimitExceeded(let limit) {
            CLIError.stderr("轮次耗尽（\(limit)）仍未收尾")
            emit(.error(kind: .turnLimit, message: "turn limit \(limit) exceeded"))
            throw ExitCode(4)
        } catch {
            CLIError.stderr("LLM 接入错误: \(error)")
            emit(.error(kind: .llm, message: "\(error)"))
            throw ExitCode(4)
        }

        // 收尾：最终 plan 过全量校验（结构 + 素材存在性），失败 exit 2
        let finalPlan = await context.plan
        let issues = EditPlanValidator().validate(finalPlan)
            + EditPlanValidator().validateAssets(finalPlan, resolver: resolver)
        guard issues.isEmpty else {
            let failure = ValidationFailure(issues: issues)
            let data = try JSONEncoder().encode(failure)
            CLIError.stderr(String(decoding: data, as: UTF8.self))
            emit(.error(kind: .validation, message: String(decoding: data, as: UTF8.self)))
            throw ExitCode(2)
        }

        // 落最终 plan（与 EditStore.json() 同一份 byte-stable 序列化，可被 validate/export 子命令直接消费）
        if let output {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(finalPlan).write(to: URL(fileURLWithPath: output))
        }

        // 可选导出（exit 3 与 export 子命令同契约）
        if let export {
            do {
                for try await event in ExportRunner.export(plan: finalPlan, resolver: resolver,
                                                           to: URL(fileURLWithPath: export)) {
                    switch event {
                    case .progress(let fraction):
                        try JSONLines.print(JSONLines.ProgressLine(progress: (fraction * 100).rounded() / 100))
                    case .done(let url, let ms):
                        try JSONLines.print(JSONLines.DoneLine(done: url.path, durationMs: ms))
                    }
                }
            } catch {
                CLIError.stderr("引擎错误: \(error)")
                emit(.error(kind: .engine, message: "\(error)"))
                throw ExitCode(3)
            }
        }

        emit(.done(turns: turns, planPath: output, exported: export))
    }
}
