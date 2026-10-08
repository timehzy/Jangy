import ArgumentParser
import Foundation
import POCCore

@main
struct KadrPOCCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kadrpoc-cli",
        abstract: "Kadr POC: EditPlan JSON → DSL → headless 导出",
        subcommands: [Sample.self, Validate.self, Export.self, GenAssets.self]
    )
}

/// stdout 只走结构化数据；日志/错误走 stderr。exit code: 0 成功 / 1 JSON 解码失败 / 2 语义校验失败 / 3 引擎错误。
enum CLIError {
    static func stderr(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
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
        let plan: EditPlan
        do {
            plan = try PlanLoader.load(from: URL(fileURLWithPath: self.plan))
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
        let plan: EditPlan
        do {
            plan = try PlanLoader.load(from: URL(fileURLWithPath: self.plan))
        } catch let error as PlanLoaderError {
            CLIError.stderr("\(error)")
            throw ExitCode(1)
        }

        let resolver = AssetResolver(directory: URL(fileURLWithPath: assets))
        let issues = EditPlanValidator().validate(plan) + EditPlanValidator().validateAssets(plan, resolver: resolver)
        guard issues.isEmpty else {
            for issue in issues { CLIError.stderr("\(issue)") }
            throw ExitCode(2)
        }

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
