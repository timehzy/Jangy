import Foundation

/// 工程包清单：格式版本 + 项目名（项目名在 meta.json 不入 plan，包内由 manifest 携带）。
public struct PackageManifest: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var exportedAt: Date
    public var appVersion: String
    public var projectName: String

    public init(formatVersion: Int, exportedAt: Date = Date(), appVersion: String, projectName: String) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.projectName = projectName
    }
}

public enum ProjectPackageError: Error, Equatable, CustomStringConvertible {
    case unsupportedFormatVersion(Int)
    case missingManifest
    case missingPlan
    /// 导出时引用素材文件缺失（列出 fileName，不静默跳过）
    case missingAssetFile(String)
    /// 包内声明的素材文件不存在
    case packagedAssetMissing(String)

    public var description: String {
        switch self {
        case .unsupportedFormatVersion(let v): return "工程包格式版本 v\(v) 不受支持（请升级 App）"
        case .missingManifest: return "工程包缺少 manifest.json"
        case .missingPlan: return "工程包缺少 project.json"
        case .missingAssetFile(let name): return "导出失败：引用素材文件缺失 \(name)"
        case .packagedAssetMissing(let name): return "工程包不完整：缺少素材文件 \(name)"
        }
    }
}

extension ProjectPackageError: LocalizedError {
    public var errorDescription: String? { description }
}

/// 工程包导入导出：`<项目名>.jangyproj.zip` = project.json + assets/ + manifest.json。
/// 导入原子性：临时目录解包，全部校验通过才落库，失败不产生半成品项目。
/// 注意：素材文件在登记落库前逐个拷入 Assets/，中途失败可能留下未登记文件
/// （由 AssetLibrary.verify() 暴露为 unregisteredFiles）。
public enum ProjectPackage {
    public static let currentFormatVersion = 1
    public static let fileExtension = "jangyproj.zip"
    public static let manifestFileName = "manifest.json"

    /// 导出：只打包本项目引用的素材（按 plan.assets 收集，不打全库）。
    public static func export(projectID: UUID, from projectStore: ProjectStore,
                              library: AssetLibrary, resolver: AssetResolver,
                              to zipURL: URL) throws {
        let plan = try projectStore.loadProject(id: projectID)
        let meta = try projectStore.loadMeta(id: projectID)
        let fm = FileManager.default

        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging.appendingPathComponent("assets"), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(plan).write(to: staging.appendingPathComponent(ProjectStore.planFileName))

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let manifest = PackageManifest(formatVersion: Self.currentFormatVersion,
                                       appVersion: appVersion, projectName: meta.name)
        try encoder.encode(manifest).write(to: staging.appendingPathComponent(Self.manifestFileName))

        for asset in plan.assets {
            let source = resolver.resolve(asset)
            guard fm.fileExists(atPath: source.path) else {
                throw ProjectPackageError.missingAssetFile(asset.fileName)
            }
            try fm.copyItem(at: source, to: staging.appendingPathComponent("assets/\(asset.fileName)"))
        }
        try ZipArchive.zip(contentsOf: staging, to: zipURL)
    }

    /// 导入：解包 → 校验 → 素材按哈希入库（冲突改写 assetID）→ 新项目登记。
    public static func `import`(from zipURL: URL, into projectStore: ProjectStore,
                                library: AssetLibrary) async throws -> ProjectSummary {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        try ZipArchive.unzip(zipURL, into: staging)

        // 校验：manifest 版本 + plan 可解码且版本不超纲（守卫在此，不走 loadProject）
        let manifestURL = staging.appendingPathComponent(Self.manifestFileName)
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PackageManifest.self, from: manifestData) else {
            throw ProjectPackageError.missingManifest
        }
        guard manifest.formatVersion <= Self.currentFormatVersion else {
            throw ProjectPackageError.unsupportedFormatVersion(manifest.formatVersion)
        }
        let planURL = staging.appendingPathComponent(ProjectStore.planFileName)
        guard fm.fileExists(atPath: planURL.path) else { throw ProjectPackageError.missingPlan }
        var plan = try PlanLoader.load(from: planURL)
        guard plan.version <= ProjectStore.currentSchemaVersion else {
            throw ProjectStoreError.unsupportedVersion(found: plan.version,
                                                       supported: ProjectStore.currentSchemaVersion)
        }

        // 素材入库 + assetID 改写
        var registry = try library.load()
        var idMap: [UUID: UUID] = [:]
        for (index, asset) in plan.assets.enumerated() {
            let packaged = staging.appendingPathComponent("assets/\(asset.fileName)")
            guard fm.fileExists(atPath: packaged.path) else {
                throw ProjectPackageError.packagedAssetMissing(asset.fileName)
            }
            let hash = try AssetHasher.sha256(of: packaged)
            if let existing = registry.first(where: { $0.sha256 != nil && $0.sha256 == hash }) {
                // 同内容已在库：复用既有 assetID
                idMap[asset.id] = existing.id
                plan.assets[index] = existing
                continue
            }
            var item = asset
            item.sha256 = hash
            if registry.contains(where: { $0.id == asset.id }) {
                item.id = UUID()  // id 冲突但内容不同：换新 id
            }
            idMap[asset.id] = item.id
            // fileName 冲突防护：同名不同内容时换新文件名
            var fileName = item.fileName
            let ext = (fileName as NSString).pathExtension
            while fm.fileExists(atPath: library.assetsDir.appendingPathComponent(fileName).path),
                  !registry.contains(where: { $0.fileName == fileName && $0.sha256 == hash }) {
                fileName = "\(UUID().uuidString).\(ext)"
            }
            try fm.createDirectory(at: library.assetsDir, withIntermediateDirectories: true)
            try fm.copyItem(at: packaged, to: library.assetsDir.appendingPathComponent(fileName))
            item.fileName = fileName
            registry.append(item)
            plan.assets[index] = item
        }

        // 改写 plan 内全部引用
        plan.clips = plan.clips.map {
            PlanClip(id: $0.id, assetID: idMap[$0.assetID] ?? $0.assetID,
                     source: $0.source, speed: $0.speed, transitionAfter: $0.transitionAfter)
        }
        if let captions = plan.captions, let mapped = idMap[captions.assetID] {
            plan.captions = CaptionTrack(assetID: mapped, isEnabled: captions.isEnabled, style: captions.style)
        }

        // 一切就绪才落库：登记表 + 新项目（createProject 写空 plan + meta，再覆盖 plan）
        try library.save(registry)
        let summary = try projectStore.createProject(name: projectStore.uniqueName(base: manifest.projectName))
        try projectStore.saveProject(id: summary.id, plan: plan)
        return summary
    }
}
