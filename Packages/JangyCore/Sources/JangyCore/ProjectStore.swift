import Foundation

/// 项目元信息：不放 plan JSON（不动清单：project.json 格式不变），独立 meta.json。
public struct ProjectMeta: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date

    public init(id: UUID, name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// 项目列表条目：扫描 Projects/ 目录派生。无索引文件，无双写。
/// Hashable：项目列表的 navigationDestination(item:) 需要。
public struct ProjectSummary: Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var clipCount: Int
    /// 实测口径总时长（转场重叠已扣除），与导出产物一致
    public var duration: TimeInterval
    public var referencedAssetCount: Int
    public var directory: URL

    /// 封面缓存路径（可能不存在，View 层兜底占位图）
    public var coverURL: URL {
        directory.appendingPathComponent(ProjectStore.coverFileName)
    }
}

public enum ProjectStoreError: Error, Equatable, CustomStringConvertible {
    case projectNotFound(UUID)
    case corruptProject(UUID)
    /// 文件版本比当前代码新：拒绝加载（拒绝优于静默丢字段，原 DraftError 语义平移）
    case unsupportedVersion(found: Int, supported: Int)

    public var description: String {
        switch self {
        case .projectNotFound(let id):
            return "项目不存在: \(id.uuidString.prefix(8))"
        case .corruptProject(let id):
            return "项目工程文件损坏: \(id.uuidString.prefix(8))"
        case .unsupportedVersion(let found, let supported):
            return "工程版本 v\(found) 比当前支持的 v\(supported) 新，拒绝加载（请升级 App）"
        }
    }
}

extension ProjectStoreError: LocalizedError {
    public var errorDescription: String? { description }
}

/// 素材元数据漂移：磁盘文件重新探测的结果与登记表不一致。
public struct AssetDrift: Equatable, Sendable {
    public var assetID: UUID
    public var fileName: String
    /// 漂移字段名：duration / pixelWidth / pixelHeight / hasAudio
    public var field: String
    public var expected: String
    public var actual: String
}

/// 完整性报告：缺失与漂移都显式列出，绝不静默丢弃。（原 DraftIntegrityReport 平移）
public struct ProjectIntegrityReport: Equatable, Sendable {
    public var missing: [AssetItem] = []
    public var drifted: [AssetDrift] = []

    public var isEmpty: Bool { missing.isEmpty && drifted.isEmpty }

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

/// 多项目持久化：Projects/<uuid>/{project.json, meta.json, cover.jpg}。
/// project.json 格式 = EditPlan JSON（与 CLI `sample`、Agent 契约同一份序列化）。
/// 素材实体不归这里管——全局库见 AssetLibrary。
public struct ProjectStore: Sendable {
    public static let projectsDirName = "Projects"
    public static let planFileName = "project.json"
    public static let metaFileName = "meta.json"
    public static let coverFileName = "cover.jpg"
    /// 当前支持的 EditPlan schema 版本（与 EditPlan.version 默认值一致）
    public static let currentSchemaVersion = 4

    /// App 支持目录根（Application Support/Jangy）
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var projectsDir: URL { root.appendingPathComponent(Self.projectsDirName, isDirectory: true) }

    /// 全局素材库目录（v3→v4 迁移期展开 SRT 需要读源文件）。
    var assetsDir: URL { root.appendingPathComponent(AssetLibrary.assetsDirName, isDirectory: true) }

    public func projectDirectory(id: UUID) -> URL {
        projectsDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: - CRUD

    public func createProject(name: String) throws -> ProjectSummary {
        let id = UUID()
        let dir = projectDirectory(id: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try saveMeta(ProjectMeta(id: id, name: name))
        let primary = PlanTrack(kind: .video, placement: .chained)
        try saveProject(id: id, plan: EditPlan(tracks: [primary], primaryTrackID: primary.id))
        return try summary(for: id)
    }

    /// 加载结果：plan + 迁移期通知（v4 plan 加载时通知恒为空）。
    public struct LoadResult: Sendable {
        public let plan: EditPlan
        public let migrationNotices: [MigrationNotice]
    }

    public func loadProject(id: UUID) throws -> LoadResult {
        let url = projectDirectory(id: id).appendingPathComponent(Self.planFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectStoreError.projectNotFound(id)
        }
        let loaded = try PlanLoader.load(from: url, assetsDirectory: assetsDir)
        guard loaded.plan.version <= Self.currentSchemaVersion else {
            throw ProjectStoreError.unsupportedVersion(found: loaded.plan.version,
                                                       supported: Self.currentSchemaVersion)
        }
        return LoadResult(plan: loaded.plan, migrationNotices: loaded.migrationNotices)
    }

    /// 原子写入：先写同目录临时文件再 rename，中途崩溃不留半截 JSON。
    /// 落盘一律标记为当前 schema 版本：旧版本 plan（v2）解码后已是当前模型，
    /// 若沿用旧版本号会写出「旧版本号 + 新格式」的混搭文件——旧代码按版本守卫放行后解码失败。
    public func saveProject(id: UUID, plan: EditPlan) throws {
        var plan = plan
        plan.version = Self.currentSchemaVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(plan)
        let dir = projectDirectory(id: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(Self.planFileName), options: .atomic)
    }

    public func renameProject(id: UUID, to name: String) throws {
        var meta = try loadMeta(id: id)
        meta.name = name
        try saveMeta(meta)
    }

    /// 复制项目：plan 深拷贝生成新项目。全局素材库下素材零拷贝（引用语义）。
    public func duplicateProject(id: UUID) throws -> ProjectSummary {
        let plan = try loadProject(id: id).plan
        let meta = try loadMeta(id: id)
        let newID = UUID()
        let dir = projectDirectory(id: newID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try saveMeta(ProjectMeta(id: newID, name: uniqueName(base: "\(meta.name) 副本")))
        try saveProject(id: newID, plan: plan)
        return try summary(for: newID)
    }

    /// 删除项目：只删项目目录，不动素材库（素材生命周期与项目解耦）。
    public func deleteProject(id: UUID) throws {
        let dir = projectDirectory(id: id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    // MARK: - meta

    public func loadMeta(id: UUID) throws -> ProjectMeta {
        let url = projectDirectory(id: id).appendingPathComponent(Self.metaFileName)
        guard let data = try? Data(contentsOf: url),
              let meta = try? JSONDecoder().decode(ProjectMeta.self, from: data) else {
            // meta 缺失兜底（CLI 播种只有 project.json 的场景）：名称回落默认，创建时间取文件时间
            let planURL = projectDirectory(id: id).appendingPathComponent(Self.planFileName)
            let created = (try? FileManager.default.attributesOfItem(atPath: planURL.path))?[.creationDate] as? Date ?? Date()
            return ProjectMeta(id: id, name: "未命名项目", createdAt: created)
        }
        return meta
    }

    private func saveMeta(_ meta: ProjectMeta) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(meta)
        let dir = projectDirectory(id: meta.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(Self.metaFileName), options: .atomic)
    }

    // MARK: - 列表与命名

    /// 项目列表：扫描目录派生，按修改时间倒序。损坏的项目也列出（名称标注），
    /// 让用户能看到并删除它——删除保护扫描时才做保守拒绝。
    public func listProjects() throws -> [ProjectSummary] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir.path) else { return [] }
        var result: [ProjectSummary] = []
        for name in dirs {
            guard let id = UUID(uuidString: name) else { continue }
            if let summary = try? summary(for: id) {
                result.append(summary)
            } else {
                let dir = projectDirectory(id: id)
                let created = (try? fm.attributesOfItem(atPath: dir.path))?[.creationDate] as? Date ?? Date()
                result.append(ProjectSummary(id: id, name: "（无法读取的项目）", createdAt: created,
                                             modifiedAt: created, clipCount: 0, duration: 0,
                                             referencedAssetCount: 0, directory: dir))
            }
        }
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// 唯一命名：base 已被占用时追加「 2」「 3」…
    public func uniqueName(base: String) -> String {
        let existing = Set(((try? listProjects()) ?? []).map(\.name))
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func summary(for id: UUID) throws -> ProjectSummary {
        let meta = try loadMeta(id: id)
        let plan = try loadProject(id: id).plan
        let planURL = projectDirectory(id: id).appendingPathComponent(Self.planFileName)
        let modified = (try? FileManager.default.attributesOfItem(atPath: planURL.path))?[.modificationDate] as? Date ?? meta.createdAt
        return ProjectSummary(id: id, name: meta.name, createdAt: meta.createdAt, modifiedAt: modified,
                              clipCount: Self.contentCount(of: plan.primaryTrack),
                              duration: plan.renderedDuration,
                              referencedAssetCount: plan.assets.count, directory: projectDirectory(id: id))
    }

    /// 主轨「片段数」= 有内容的元素（删除留下的 gap 不计入）。
    private static func contentCount(of track: PlanTrack?) -> Int {
        track?.elements.filter { if case .content = $0.content { return true } else { return false } }.count ?? 0
    }

    // MARK: - 完整性校验（原 DraftStore.verify 平移）

    /// 存在性（同步）+ 视频素材元数据重探测比对（异步）。
    /// 登记字段为 nil（未探测）或重探测失败的项不参与比对——nil 语义是「不知道」。
    public func verify(plan: EditPlan, resolver: AssetResolver) async -> ProjectIntegrityReport {
        var report = ProjectIntegrityReport()
        for asset in plan.assets {
            guard resolver.exists(asset) else {
                report.missing.append(asset)
                continue
            }
            guard asset.kind == .video else { continue }
            let metadata = await AssetImporter.probeMetadata(of: resolver.resolve(asset))
            compare(asset: asset, field: "duration", expected: asset.duration, actual: metadata.duration,
                    equals: { abs($0 - $1) < 0.05 },  // 帧级容差：±50ms
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
                                       into report: inout ProjectIntegrityReport) {
        guard let expected, let actual, !equals(expected, actual) else { return }
        report.drifted.append(AssetDrift(assetID: asset.id, fileName: asset.fileName, field: field,
                                         expected: "\(expected)", actual: "\(actual)"))
    }

    // MARK: - 旧布局迁移

    /// 旧单草稿布局 → 多项目布局：
    /// ① draft.json → Projects/<新uuid>/project.json（名称「未命名项目」）
    /// ② 散落 root 的素材文件 → Assets/
    /// ③ library.json 从迁移项目的 plan.assets 播种（逐文件算 sha256）
    /// 幂等：无 draft.json 且无散落文件时返回 false。
    @discardableResult
    public func migrateLegacyLayoutIfNeeded() throws -> Bool {
        let fm = FileManager.default
        let library = AssetLibrary(root: root)
        var migrated = false

        let legacyDraft = root.appendingPathComponent("draft.json")
        if fm.fileExists(atPath: legacyDraft.path) {
            let plan = try PlanLoader.load(from: legacyDraft, assetsDirectory: assetsDir).plan
            guard plan.version <= Self.currentSchemaVersion else {
                throw ProjectStoreError.unsupportedVersion(found: plan.version, supported: Self.currentSchemaVersion)
            }
            let id = UUID()
            try fm.createDirectory(at: projectDirectory(id: id), withIntermediateDirectories: true)
            let created = (try? fm.attributesOfItem(atPath: legacyDraft.path))?[.creationDate] as? Date ?? Date()
            try saveMeta(ProjectMeta(id: id, name: uniqueName(base: "未命名项目"), createdAt: created))
            try saveProject(id: id, plan: plan)
            try fm.removeItem(at: legacyDraft)
            migrated = true
        }

        // 散落素材 → Assets/（白名单外的 root 直属文件全部视为素材）
        try fm.createDirectory(at: library.assetsDir, withIntermediateDirectories: true)
        let keep: Set<String> = [Self.projectsDirName, AssetLibrary.assetsDirName,
                                 AssetLibrary.fileName, "agent-config.json", "draft.json"]
        for name in try fm.contentsOfDirectory(atPath: root.path) {
            let url = root.appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            guard !isDir.boolValue, !keep.contains(name), !name.hasPrefix(".") else { continue }
            try fm.moveItem(at: url, to: library.assetsDir.appendingPathComponent(name))
            migrated = true
        }

        // library.json 播种：所有项目的 plan.assets 并集（含 sha256 计算；文件缺失的跳过，
        // 完整性校验会在打开项目时报告）
        if !fm.fileExists(atPath: library.fileURL.path) {
            var registry: [AssetItem] = []
            for summary in (try? listProjects()) ?? [] {
                guard let plan = try? loadProject(id: summary.id).plan else { continue }
                for var asset in plan.assets where !registry.contains(where: { $0.id == asset.id }) {
                    let fileURL = library.resolver.resolve(asset)
                    asset.sha256 = try? AssetHasher.sha256(of: fileURL)
                    registry.append(asset)
                }
            }
            if !registry.isEmpty { try library.save(registry) }
        }
        return migrated
    }
}
