import ArgumentParser
import Foundation
import JangyCore
import JangyTestSupport

@main
struct JangyCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jangy-cli",
        abstract: "Jangy: EditPlan JSON → DSL → headless 导出",
        subcommands: [Sample.self, Validate.self, Export.self, Snapshot.self, GenAssets.self, Agent.self]
    )
}

/// stdout 只走结构化数据；日志/错误走 stderr。exit code: 0 成功 / 1 JSON 解码失败 / 2 语义校验失败 / 3 引擎错误 / 4 LLM 接入错误（agent 子命令）。
enum CLIError {
    static func stderr(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

/// 加载 + 校验 plan 的公共前置：JSON 解码失败 exit 1，语义校验失败 exit 2（issues JSON 走 stderr）。
func loadValidatedPlan(_ path: String, assets: String) throws -> (plan: EditPlan, resolver: AssetResolver) {
    let plan: EditPlan
    do {
        plan = try PlanLoader.load(from: URL(fileURLWithPath: path))
    } catch let error as PlanLoaderError {
        CLIError.stderr("\(error)")
        throw ExitCode(1)
    }

    let resolver = AssetResolver(directory: URL(fileURLWithPath: assets))
    let issues = EditPlanValidator().validate(plan) + EditPlanValidator().validateAssets(plan, resolver: resolver)
    guard issues.isEmpty else {
        let failure = ValidationFailure(issues: issues)
        let data = try JSONEncoder().encode(failure)
        CLIError.stderr(String(decoding: data, as: UTF8.self))
        throw ExitCode(2)
    }
    return (plan, resolver)
}

struct JSONLines {
    struct ProgressLine: Encodable { let progress: Double }
    struct DoneLine: Encodable { let done: String; let durationMs: Int }

    static func print<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        Swift.print(String(decoding: data, as: UTF8.self))
    }
}

struct Sample: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "输出内置演示工程的 EditPlan JSON（Agent few-shot 样例 / schema 活文档）")

    mutating func run() async throws {
        Swift.print(try SamplePlan.json())
    }
}

struct GenAssets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "genassets", abstract: "生成测试素材（3 段视频 + sample.srt）到指定目录")

    @Option(help: "素材输出目录，默认 ./Assets")
    var to: String = "./Assets"

    mutating func run() async throws {
        let resolver = try AssetSynthesizer.synthesize(into: URL(fileURLWithPath: to))
        struct Result: Encodable { let directory: String; let files: [String] }
        try JSONLines.print(Result(directory: resolver.directory.path,
                                   files: AssetSynthesizer.clipFileNames + [AssetSynthesizer.srtFileName]))
    }
}

struct Validate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "校验 EditPlan JSON（结构 + 素材存在性），不导出")

    @Argument(help: "EditPlan JSON 文件路径")
    var plan: String

    @Option(help: "素材目录，默认 ./Assets")
    var assets: String = "./Assets"

    mutating func run() async throws {
        _ = try loadValidatedPlan(plan, assets: assets)
        struct ValidLine: Encodable { let valid: Bool }
        try JSONLines.print(ValidLine(valid: true))
    }
}

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "完整管线：EditPlan JSON → DSL → headless 导出 mp4")

    @Argument(help: "EditPlan JSON 文件路径")
    var plan: String

    @Option(name: .shortAndLong, help: "输出 mp4 路径")
    var output: String

    @Option(help: "素材目录，默认 ./Assets")
    var assets: String = "./Assets"

    mutating func run() async throws {
        let (plan, resolver) = try loadValidatedPlan(plan, assets: assets)

        do {
            for try await event in ExportRunner.export(plan: plan, resolver: resolver, to: URL(fileURLWithPath: output)) {
                switch event {
                case .progress(let fraction):
                    try JSONLines.print(JSONLines.ProgressLine(progress: (fraction * 100).rounded() / 100))
                case .done(let url, let ms):
                    try JSONLines.print(JSONLines.DoneLine(done: url.path, durationMs: ms))
                }
            }
        } catch {
            CLIError.stderr("引擎错误: \(error)")
            throw ExitCode(3)
        }
    }
}

struct Snapshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "导出帧快照：走完整导出管线渲真值，抽指定时刻帧为 PNG（人工比对 / Agent 视觉自检）")

    @Argument(help: "EditPlan JSON 文件路径")
    var plan: String

    @Option(help: "快照时刻（秒，合成时间轴）；可多次指定，共享一次导出")
    var at: [TimeInterval] = []

    @Option(help: "素材目录，默认 ./Assets")
    var assets: String = "./Assets"

    @Option(name: .shortAndLong, help: "PNG 输出目录，默认 ./Frames")
    var output: String = "./Frames"

    struct SnapshotLine: Encodable { let snapshot: String; let at: Double }

    mutating func run() async throws {
        let (plan, resolver) = try loadValidatedPlan(plan, assets: assets)
        guard !at.isEmpty else {
            CLIError.stderr("至少指定一个 --at 时刻（秒）")
            throw ExitCode(2)
        }

        do {
            let frames = try await FrameSnapshotter.snapshots(plan: plan, resolver: resolver, at: at)
            let dir = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for t in at {
                let url = dir.appendingPathComponent(String(format: "t%.2f.png", t))
                try frames[t]?.write(to: url)
                try JSONLines.print(SnapshotLine(snapshot: url.path, at: t))
            }
        } catch FrameSnapshotter.Failure.timeOutOfRange(let t, let duration) {
            CLIError.stderr("时刻 \(t)s 超出渲染时长 \(duration)s")
            throw ExitCode(2)
        } catch {
            CLIError.stderr("引擎错误: \(error)")
            throw ExitCode(3)
        }
    }
}
