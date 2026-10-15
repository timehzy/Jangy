import Foundation

public enum ReferenceScanError: Error, Equatable, CustomStringConvertible {
    case corruptProject(UUID)

    public var description: String {
        switch self {
        case .corruptProject(let id):
            return "项目 \(id.uuidString.prefix(8)) 的工程文件损坏，无法确认素材引用情况"
        }
    }
}

extension ReferenceScanError: LocalizedError {
    public var errorDescription: String? { description }
}

/// 素材引用扫描：assetID → 引用它的项目 id 集。
/// 事实源是各项目 plan.assets（项目侧正向引用）；素材侧不物化任何反向数据，
/// 删除保护/信息面板用到时现场扫描。任一项目损坏即抛错——宁可拒绝删除也不误删。
public struct ReferenceScanner: Sendable {
    public let projectStore: ProjectStore

    public init(projectStore: ProjectStore) {
        self.projectStore = projectStore
    }

    /// - Parameters:
    ///   - currentProjectID: 当前打开项目的 id（其内存 plan 覆盖磁盘版本，未落盘编辑也算数）
    ///   - currentPlan: 当前打开项目的内存 plan
    public func scan(currentProjectID: UUID? = nil, currentPlan: EditPlan? = nil) throws -> [UUID: Set<UUID>] {
        var result: [UUID: Set<UUID>] = [:]
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: projectStore.projectsDir,
                                                includingPropertiesForKeys: nil)) ?? []
        for dir in dirs where dir.hasDirectoryPath {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            let plan: EditPlan
            if id == currentProjectID, let currentPlan {
                plan = currentPlan
            } else {
                guard let loaded = try? projectStore.loadProject(id: id) else {
                    throw ReferenceScanError.corruptProject(id)
                }
                plan = loaded.plan
            }
            for asset in plan.assets {
                result[asset.id, default: []].insert(id)
            }
        }
        return result
    }
}
