import Foundation
import Observation
import UniformTypeIdentifiers
import JangyCore

/// 素材删除结果。
enum DeleteOutcome: Equatable {
    case deleted(Int)
    /// 被引用，拒绝删除（值为引用项目名列表）
    case blocked([String])
    /// 扫描失败（损坏项目等，保守拒删）
    case scanFailed(String)
}

/// 素材库页状态：全局登记表 + 导入管线（从 AppModel 迁入并泛化到三类素材）。
/// attachedEditor 非 nil = 剪辑页语境（素材格显示 ＋ 上轨、预览页显示添加按钮）。
@MainActor
@Observable
final class LibraryModel {
    private let library: AssetLibrary
    let resolver: AssetResolver
    private let projectStore: ProjectStore

    /// 剪辑页语境：进入剪辑页时设置，回项目列表时清空
    var attachedEditor: AppModel?
    /// 素材库条目（导入时间倒序）
    private(set) var items: [AssetItem] = []
    /// 最近一次导入入库的素材 id（素材格高亮用；下次 reload 保留，再次导入时替换）
    private(set) var recentlyImported: Set<UUID> = []
    var importProgress: Double?
    var importMessage: String?
    /// 登记表与磁盘的一致性漂移
    var libraryMessage: String?
    /// 「已添加到时间线」toast 触发（View 层消费后置 nil）
    var toastMessage: String?
    /// toast 递增序号：View 层 .task(id:) 依此重启计时（否则连续上轨时 toast 不重弹）
    private(set) var toastSequence = 0

    init(library: AssetLibrary, resolver: AssetResolver, projectStore: ProjectStore) {
        self.library = library
        self.resolver = resolver
        self.projectStore = projectStore
    }

    /// 重载登记表 + 一致性校验。登记表读不出来显式报告，不静默当作空库。
    func reload() {
        do {
            items = try library.load().sorted {
                ($0.importedAt ?? .distantPast) > ($1.importedAt ?? .distantPast)
            }
        } catch {
            items = []
            libraryMessage = "素材库登记表读取失败: \(error.localizedDescription)"
            return
        }
        Task { @MainActor in
            do {
                let report = try library.verify()
                libraryMessage = report.isEmpty ? nil : "素材库一致性：\(report.summary)"
            } catch {
                libraryMessage = "素材库一致性校验失败: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - 导入

    /// 从相册导入（视频 + 图片）：授权 → 按类型解析临时文件 → 逐个入库。
    /// 只入库不上轨；单个失败不阻断其余。
    func importFromPhotos(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        importProgress = 0
        importMessage = nil
        Task { @MainActor in
            guard await PhotosBridge.requestReadAccess() else {
                importProgress = nil
                importMessage = "没有相册读取权限（请在系统设置中允许访问相册）"
                return
            }
            let total = Double(identifiers.count)
            var failures = 0
            var importedIDs: Set<UUID> = []
            for (index, identifier) in identifiers.enumerated() {
                do {
                    let kind = PhotosBridge.mediaType(of: identifier) ?? .video
                    let temp: URL
                    switch kind {
                    case .image:
                        temp = try await PhotosBridge.resolveImageFile(assetIdentifier: identifier) { fraction in
                            Task { @MainActor in self.importProgress = (Double(index) + fraction) / total }
                        }
                    default:
                        temp = try await PhotosBridge.resolveVideoFile(assetIdentifier: identifier) { fraction in
                            Task { @MainActor in self.importProgress = (Double(index) + fraction) / total }
                        }
                    }
                    let (item, _) = try await library.importFile(from: temp, kind: kind, origin: .photoLibrary)
                    importedIDs.insert(item.id)
                } catch {
                    failures += 1
                }
                importProgress = Double(index + 1) / total
            }
            importProgress = nil
            if failures > 0 {
                importMessage = "\(failures) 个素材导入失败（iCloud 下载或格式不支持）"
            }
            recentlyImported = importedIDs
            reload()
        }
    }

    /// 从文件 App 导入（视频/图片/音频）：picker（asCopy）已拷入临时目录，直接入库。
    func importFromFiles(urls: [URL]) {
        guard !urls.isEmpty else { return }
        importProgress = 0
        importMessage = nil
        Task { @MainActor in
            var failures = 0
            var importedIDs: Set<UUID> = []
            for (index, url) in urls.enumerated() {
                do {
                    guard let kind = Self.kindForFile(url) else {
                        throw CocoaError(.fileReadUnsupportedScheme)
                    }
                    let (item, _) = try await library.importFile(from: url, kind: kind, origin: .files)
                    importedIDs.insert(item.id)
                } catch {
                    failures += 1
                }
                importProgress = Double(index + 1) / Double(urls.count)
            }
            importProgress = nil
            if failures > 0 {
                importMessage = "\(failures) 个素材导入失败（文件拷贝或格式不支持）"
            }
            recentlyImported = importedIDs
            reload()
        }
    }

    /// 文件类型判定：UTType 一致性推断。不支持的类型返回 nil。
    static func kindForFile(_ url: URL) -> AssetKind? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }

    // MARK: - 上轨（剪辑页语境）

    /// 素材格 ＋：全长追加到当前项目时间线末尾。
    func quickAdd(_ item: AssetItem) {
        guard let editor = attachedEditor else { return }
        editor.appendAssetToTimeline(item)
        toastMessage = "已添加到时间线"
        toastSequence += 1
    }

    /// 预览页 trim 后上轨。
    func addToTimeline(_ item: AssetItem, range: ClosedRange<TimeInterval>) {
        guard let editor = attachedEditor else { return }
        editor.appendAssetToTimeline(item, range: range)
        toastMessage = "已添加到时间线"
        toastSequence += 1
    }

    // MARK: - 删除保护 / 引用查询

    /// 删除素材：先引用扫描（当前打开项目用内存 plan），有引用则拒删。
    func delete(ids: Set<UUID>) -> DeleteOutcome {
        let editor = attachedEditor
        do {
            let refs = try ReferenceScanner(projectStore: projectStore)
                .scan(currentProjectID: editor?.projectID, currentPlan: editor?.store.plan)
            let blockedIDs = ids.filter { refs[$0]?.isEmpty == false }
            guard blockedIDs.isEmpty else {
                let projectIDs = Set(blockedIDs.flatMap { refs[$0] ?? [] })
                let names = (try? projectStore.listProjects())?
                    .filter { projectIDs.contains($0.id) }.map(\.name) ?? []
                return .blocked(names)
            }
            try library.remove(ids: ids)
            reload()
            return .deleted(ids.count)
        } catch {
            return .scanFailed(error.localizedDescription)
        }
    }

    /// 集合中未被任何项目引用的子集（删除受阻时「只删未引用的」用）。扫描失败返回空集（保守）。
    func unreferencedIDs(in ids: Set<UUID>) -> Set<UUID> {
        let editor = attachedEditor
        guard let refs = try? ReferenceScanner(projectStore: projectStore)
            .scan(currentProjectID: editor?.projectID, currentPlan: editor?.store.plan) else { return [] }
        return ids.filter { refs[$0]?.isEmpty != false }
    }

    /// 素材信息面板的「被哪些项目引用」。
    func referencingProjects(of assetID: UUID) -> [String] {
        let editor = attachedEditor
        guard let refs = try? ReferenceScanner(projectStore: projectStore)
            .scan(currentProjectID: editor?.projectID, currentPlan: editor?.store.plan),
              let projectIDs = refs[assetID], !projectIDs.isEmpty else { return [] }
        return ((try? projectStore.listProjects()) ?? [])
            .filter { projectIDs.contains($0.id) }.map(\.name)
    }
}
