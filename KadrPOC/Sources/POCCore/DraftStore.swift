import AVFoundation
import Foundation

/// 草稿层错误。解码失败直接透传 PlanLoaderError（字段路径翻译已就位），
/// 这里只新增 schema 版本守卫一类。
public enum DraftError: Error, Equatable, CustomStringConvertible {
    /// 文件版本比当前代码新：拒绝加载。借鉴 kadr-persistence——
    /// 「尽力读取未来格式 = 下次保存静默擦掉不认识的字段」，拒绝是唯一不毁数据的行为。
    case unsupportedVersion(found: Int, supported: Int)

    public var description: String {
        switch self {
        case .unsupportedVersion(let found, let supported):
            return "草稿版本 v\(found) 比当前支持的 v\(supported) 新，拒绝加载（请升级 App）"
        }
    }
}

extension DraftError: LocalizedError {
    public var errorDescription: String? { description }
}

/// 素材元数据漂移：磁盘文件重新探测的结果与登记表不一致（同名文件被替换等）。
public struct AssetDrift: Equatable, Sendable {
    public var assetID: UUID
    public var fileName: String
    /// 漂移字段名：duration / pixelWidth / pixelHeight / hasAudio
    public var field: String
    public var expected: String
    public var actual: String
}

/// 完整性报告：缺失与漂移都显式列出，绝不静默丢弃。
public struct DraftIntegrityReport: Equatable, Sendable {
    public var missing: [AssetItem] = []
    public var drifted: [AssetDrift] = []

    public var isEmpty: Bool { missing.isEmpty && drifted.isEmpty }

    /// 人/Agent 可读的一句话摘要（UI 横幅、CLI stderr 通用）。
    public var summary: String {
        var parts: [String] = []
        if !missing.isEmpty {
            parts.append("\(missing.count) 个素材文件缺失: \(missing.map(\.fileName).joined(separator: ", "))")
        }
        if !drifted.isEmpty {
            parts.append("\(drifted.count) 处素材元数据漂移: \(drifted.map { "\($0.fileName) 的 \($0.field)（登记 \($0.expected) → 实测 \($0.actual)）" }.joined(separator: ", "))")
        }
        return parts.joined(separator: "；")
    }
}

/// 草稿持久化：EditPlan JSON 落盘/恢复/完整性校验。
///
/// 草稿格式与 CLI `sample`、Agent 契约同一份（prettyPrinted + sortedKeys，
/// 未变更的两次保存字节一致）。草稿文件 `draft.json` 与素材同目录，
/// 迁移/清理以目录为单位。
public struct DraftStore: Sendable {
    /// 当前支持的 EditPlan schema 版本（与 EditPlan.version 默认值一致）
    public static let currentSchemaVersion = 2

    public static let fileName = "draft.json"

    /// 素材目录（= AssetResolver.directory）
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var fileURL: URL {
        directory.appendingPathComponent(Self.fileName)
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// 原子写入：先写同目录临时文件再 rename（Data.write 的 .atomic 语义），
    /// 中途断电/崩溃不留半截 JSON，旧草稿完好。
    public func save(plan: EditPlan) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(plan)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    /// 加载草稿。文件不存在返回 nil；损坏抛 PlanLoaderError（字段路径翻译）；
    /// 版本过新抛 DraftError.unsupportedVersion（拒绝优于静默丢字段）。
    public func load() throws -> EditPlan? {
        guard exists else { return nil }
        let plan = try PlanLoader.load(from: fileURL)
        guard plan.version <= Self.currentSchemaVersion else {
            throw DraftError.unsupportedVersion(found: plan.version, supported: Self.currentSchemaVersion)
        }
        return plan
    }

    public func delete() throws {
        guard exists else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    /// 完整性校验：存在性（同步）+ 视频素材元数据重探测比对（异步）。
    /// 登记表字段为 nil（未探测）或重探测失败的项不参与比对——nil 语义是「不知道」，
    /// 不能拿「不知道」去指控漂移。
    public func verify(plan: EditPlan, resolver: AssetResolver) async -> DraftIntegrityReport {
        var report = DraftIntegrityReport()
        for asset in plan.assets {
            guard resolver.exists(asset) else {
                report.missing.append(asset)
                continue
            }
            guard asset.kind == .video else { continue }
            let metadata = await AssetImporter.probeMetadata(of: resolver.resolve(asset))
            compare(asset: asset, field: "duration", expected: asset.duration, actual: metadata.duration,
                    equals: { abs($0 - $1) < 0.05 },  // 帧级容差：容器时长与登记值允许 ±50ms
                    into: &report)
            compare(asset: asset, field: "pixelWidth", expected: asset.pixelWidth, actual: metadata.pixelWidth, into: &report)
            compare(asset: asset, field: "pixelHeight", expected: asset.pixelHeight, actual: metadata.pixelHeight, into: &report)
            compare(asset: asset, field: "hasAudio", expected: asset.hasAudio, actual: metadata.hasAudio, into: &report)
        }
        return report
    }

    private func compare<T: Equatable>(asset: AssetItem, field: String,
                                       expected: T?, actual: T?,
                                       equals: (T, T) -> Bool = { $0 == $1 },
                                       into report: inout DraftIntegrityReport) {
        guard let expected, let actual, !equals(expected, actual) else { return }
        report.drifted.append(AssetDrift(assetID: asset.id, fileName: asset.fileName, field: field,
                                         expected: "\(expected)", actual: "\(actual)"))
    }
}
