import Foundation

/// JSON 层错误：把 DecodingError 翻译成人/Agent 可读的字段路径。
public enum PlanLoaderError: Error, Equatable, CustomStringConvertible {
    case decodingFailed(path: String, message: String)

    public var description: String {
        switch self {
        case .decodingFailed(let path, let message): return "\(path): \(message)"
        }
    }
}

extension PlanLoaderError: LocalizedError {
    public var errorDescription: String? { description }
}

public enum PlanLoader {

    /// 加载结果：plan + 迁移期通知。
    /// **迁移通知必须能流到用户面前**——迁移是静默发生的，丢掉的字幕如果没人报，
    /// 用户只会看到字幕莫名变少（Task 5 的 `MigrationNotice`）。
    public struct LoadResult: Sendable {
        public let plan: EditPlan
        /// 空表示没发生迁移、或迁移无问题。
        public let migrationNotices: [MigrationNotice]
    }

    /// - Parameter assetsDirectory: 提供时，v3 及更早的 plan 会就地迁移（含 SRT 展开）。
    public static func load(from url: URL, assetsDirectory: URL? = nil) throws -> LoadResult {
        let data = try Data(contentsOf: url)
        return try decode(data, assetsDirectory: assetsDirectory)
    }

    static func decode(_ data: Data, assetsDirectory: URL?) throws -> LoadResult {
        let probe: VersionProbe
        do {
            probe = try JSONDecoder().decode(VersionProbe.self, from: data)
        } catch let error as DecodingError {
            let (path, message) = describe(error)
            throw PlanLoaderError.decodingFailed(path: path, message: message)
        }

        if (probe.version ?? 4) >= 4 {
            do {
                return LoadResult(plan: try JSONDecoder().decode(EditPlan.self, from: data),
                                  migrationNotices: [])
            } catch let error as DecodingError {
                let (path, message) = describe(error)
                throw PlanLoaderError.decodingFailed(path: path, message: message)
            }
        }

        let legacy: LegacyPlanV3
        do {
            legacy = try JSONDecoder().decode(LegacyPlanV3.self, from: data)
        } catch let error as DecodingError {
            let (path, message) = describe(error)
            throw PlanLoaderError.decodingFailed(path: path, message: message)
        }
        let parts = PlanMigration.migrate(legacy, assetsDirectory: assetsDirectory)
        let plan = EditPlan(version: 4, assets: parts.assets, tracks: parts.tracks,
                            primaryTrackID: parts.primaryTrackID, preset: parts.preset)
        return LoadResult(plan: plan, migrationNotices: parts.notices)
    }

    struct VersionProbe: Decodable { let version: Int? }

    static func describe(_ error: DecodingError) -> (path: String, message: String) {
        switch error {
        case .keyNotFound(let key, let context):
            return (pathString(context.codingPath + [key]), "缺少字段 \(key.stringValue)")
        case .typeMismatch(_, let context):
            return (pathString(context.codingPath), "类型不匹配: \(context.debugDescription)")
        case .valueNotFound(_, let context):
            return (pathString(context.codingPath), "值为空: \(context.debugDescription)")
        case .dataCorrupted(let context):
            return (pathString(context.codingPath), "数据损坏: \(context.debugDescription)")
        @unknown default:
            return ("(root)", "未知解码错误")
        }
    }

    static func pathString(_ codingPath: [CodingKey]) -> String {
        var result = ""
        for key in codingPath {
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                result += result.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return result.isEmpty ? "(root)" : result
    }
}
