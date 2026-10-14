import Foundation
import Observation
import JangyCore

/// 项目列表页状态：扫描项目目录 + 多选操作 + 工程包导入导出协调。
@MainActor
@Observable
final class ProjectListModel {
    let projectStore: ProjectStore
    let library: AssetLibrary
    let resolver: AssetResolver

    private(set) var projects: [ProjectSummary] = []
    var isSelecting = false
    var selection: Set<UUID> = []
    var message: String?
    /// 待分享的工程包 URL 列表（View 层据此弹出分享面板）
    var packagesToShare: [URL]?

    init(projectStore: ProjectStore, library: AssetLibrary, resolver: AssetResolver) {
        self.projectStore = projectStore
        self.library = library
        self.resolver = resolver
    }

    func reload() {
        projects = (try? projectStore.listProjects()) ?? []
    }

    /// 新建项目（默认名「未命名项目 N」），返回供导航进剪辑页。
    func createProject() -> ProjectSummary? {
        do {
            let summary = try projectStore.createProject(name: projectStore.uniqueName(base: "未命名项目"))
            reload()
            return summary
        } catch {
            message = "新建项目失败: \(error.localizedDescription)"
            return nil
        }
    }

    func delete(ids: Set<UUID>) {
        var failures = 0
        for id in ids {
            do { try projectStore.deleteProject(id: id) } catch { failures += 1 }
        }
        if failures > 0 { message = "\(failures) 个项目删除失败" }
        exitSelection()
        reload()
    }

    func duplicate(ids: Set<UUID>) {
        for id in ids {
            do { _ = try projectStore.duplicateProject(id: id) } catch {
                message = "复制失败: \(error.localizedDescription)"
            }
        }
        exitSelection()
        reload()
    }

    func rename(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        try? projectStore.renameProject(id: id, to: trimmed)
        reload()
    }

    /// 导出工程包：选中几个就生成几个 zip，一次分享面板带出。
    /// 引用素材缺失的包导出失败并跳过，最后汇总提示。
    /// 打包是同步 IO + 全量内存 zip，放后台线程跑，完成回主线程更新状态。
    /// 同名项目的目标文件追加 id 前缀段去重，防止互相覆盖。
    func exportPackages(ids: Set<UUID>) {
        // 主线程快照：项目名 + id（后台任务只依赖 Sendable 的 store/library/resolver）
        let targets = ids.compactMap { id -> (UUID, String)? in
            guard let summary = projects.first(where: { $0.id == id }) else { return nil }
            return (id, summary.name)
        }
        let projectStore = self.projectStore
        let library = self.library
        let resolver = self.resolver
        Task.detached { [weak self] in
            var urls: [URL] = []
            var failures: [String] = []
            var usedNames: Set<String> = []
            for (id, name) in targets {
                // 同名冲突时追加 id 前 8 位，避免 tmp 下互相覆盖
                var fileName = name
                if usedNames.contains(fileName) { fileName = "\(name)-\(id.uuidString.prefix(8))" }
                usedNames.insert(fileName)
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(fileName).\(ProjectPackage.fileExtension)")
                do {
                    try ProjectPackage.export(projectID: id, from: projectStore,
                                              library: library, resolver: resolver, to: dest)
                    urls.append(dest)
                } catch {
                    failures.append("\(name): \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                guard let self else { return }
                if !urls.isEmpty { self.packagesToShare = urls }
                if !failures.isEmpty { self.message = failures.joined(separator: "\n") }
                self.exitSelection()
            }
        }
    }

    /// 导入工程包：解包校验入库，失败不产生半成品。
    func importPackage(from url: URL) {
        Task { @MainActor in
            do {
                let summary = try await ProjectPackage.import(from: url, into: projectStore, library: library)
                message = "已导入项目「\(summary.name)」"
            } catch {
                message = "导入失败: \(error.localizedDescription)"
            }
            reload()
        }
    }

    /// 「查看信息」的占用空间：本项目引用素材的体积和。
    func referencedStorageSize(of id: UUID) -> Int64 {
        guard let plan = try? projectStore.loadProject(id: id) else { return 0 }
        let fm = FileManager.default
        return plan.assets.reduce(Int64(0)) { total, asset in
            let url = resolver.resolve(asset)
            let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
            return total + size
        }
    }

    func toggleSelection(of id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func exitSelection() {
        isSelecting = false
        selection.removeAll()
    }
}
