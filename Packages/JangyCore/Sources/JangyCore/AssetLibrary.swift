import Foundation

/// 素材库一致性报告：登记与磁盘的双向核对。漂移显式列出，不静默处理。
public struct LibraryIntegrityReport: Equatable, Sendable {
    /// 登记有、磁盘无
    public var missingFiles: [AssetItem] = []
    /// 磁盘有、登记无
    public var unregisteredFiles: [String] = []

    public var isEmpty: Bool { missingFiles.isEmpty && unregisteredFiles.isEmpty }

    public var summary: String {
        var parts: [String] = []
        if !missingFiles.isEmpty {
            parts.append("\(missingFiles.count) 个登记素材文件缺失: \(missingFiles.map(\.fileName).joined(separator: ", "))")
        }
        if !unregisteredFiles.isEmpty {
            parts.append("\(unregisteredFiles.count) 个未登记文件: \(unregisteredFiles.joined(separator: ", "))")
        }
        return parts.joined(separator: "；")
    }
}

/// 全局素材库：素材实体的事实源（`library.json` 登记表 + `Assets/` 文件目录）。
/// 与项目解耦——项目 plan.assets 只持有引用子集；删除素材必须经 ReferenceScanner
/// 确认无项目引用（删除保护在 App 层编排，本类型只管登记与文件的同步清理）。
public struct AssetLibrary: Sendable {
    public static let fileName = "library.json"
    public static let assetsDirName = "Assets"

    /// App 支持目录根（Application Support/Jangy）
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var assetsDir: URL { root.appendingPathComponent(Self.assetsDirName, isDirectory: true) }
    public var fileURL: URL { root.appendingPathComponent(Self.fileName) }
    public var resolver: AssetResolver { AssetResolver(directory: assetsDir) }

    /// 加载登记表；文件不存在 = 空库。
    public func load() throws -> [AssetItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([AssetItem].self, from: Data(contentsOf: fileURL))
    }

    /// 原子写入（与 plan 落盘同款 prettyPrinted + sortedKeys）。
    public func save(_ items: [AssetItem]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(items).write(to: fileURL, options: .atomic)
    }

    /// 入库：SHA-256 内容去重——同内容素材复用既有登记（isNew = false），不重复占盘。
    /// sha256 为 nil 的旧登记项不参与匹配（「不知道」不能当「相同」）。
    @discardableResult
    public func importFile(from tempURL: URL, kind: AssetKind, origin: AssetOrigin,
                           displayName: String? = nil) async throws -> (item: AssetItem, isNew: Bool) {
        let hash = try AssetHasher.sha256(of: tempURL)
        var registry = try load()
        if let existing = registry.first(where: { $0.sha256 == hash }) {
            try? FileManager.default.removeItem(at: tempURL)
            return (existing, false)
        }
        let item = try await AssetImporter(directory: assetsDir)
            .importMedia(from: tempURL, kind: kind, origin: origin, displayName: displayName, knownSHA256: hash)
        registry.append(item)
        try save(registry)
        return (item, true)
    }

    /// 删除素材：登记与文件同步清理。调用方负责先做引用检查。
    public func remove(ids: Set<UUID>) throws {
        var registry = try load()
        let targets = registry.filter { ids.contains($0.id) }
        registry.removeAll { ids.contains($0.id) }
        for item in targets {
            try? FileManager.default.removeItem(at: resolver.resolve(item))
        }
        try save(registry)
    }

    /// 登记 ↔ 磁盘双向核对。
    public func verify() throws -> LibraryIntegrityReport {
        let registry = try load()
        var report = LibraryIntegrityReport()
        for item in registry where !resolver.exists(item) {
            report.missingFiles.append(item)
        }
        let registered = Set(registry.map(\.fileName))
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: assetsDir.path)) ?? []
        for name in onDisk where !registered.contains(name) && !name.hasPrefix(".") {
            report.unregisteredFiles.append(name)
        }
        return report
    }
}
