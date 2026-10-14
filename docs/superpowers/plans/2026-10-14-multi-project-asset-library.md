# 多项目 + 素材库管理 UI 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 App 从单草稿演进为「多项目 + 全局素材库」：项目列表首页、素材库管理页（视频/图片/音频入库、预览、删除保护）、素材预览页（trim 上轨）、工程包导入导出。

**Architecture:** 持久层从单个 `draft.json` 演进为 `Projects/<uuid>/project.json` + `meta.json` 目录结构 + 全局 `Assets/` + `library.json` 登记表；plan 格式不变（不动清单）。素材实体事实源在 `library.json`，项目自包含持有引用子集。引用关系不物化，读时扫描。UI 为导航栈：项目列表 → 剪辑页 → 素材库/预览页。

**Tech Stack:** SwiftUI（NavigationStack）、AVFoundation、CryptoKit（SHA-256）、ImageIO（图片元数据）、自研 store-only ZIP（无新依赖）。

**Spec:** [2026-10-14-multi-project-asset-library-design.md](../specs/2026-10-14-multi-project-asset-library-design.md)

**通用命令：**
- 核心层测试：`cd Packages/JangyCore && swift test --filter <测试名>`
- 全量测试：`cd Packages/JangyCore && swift test`（现有 125 个为底线；DraftStoreTests 在 Task 4 迁移为 ProjectStoreTests，总数会变）
- App 构建：`xcodebuild -project Jangy.xcodeproj -scheme Jangy -destination 'generic/platform=iOS Simulator' build -skipMacroValidation`

---

### Task 1: AssetItem.sha256 字段 + AssetHasher

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/AssetHasher.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/AssetItem.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/AssetHasherTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `Packages/JangyCore/Tests/JangyCoreTests/AssetHasherTests.swift`：

```swift
import XCTest
@testable import JangyCore

/// SHA-256 流式哈希 + AssetItem.sha256 字段编解码。
final class AssetHasherTests: XCTestCase {

    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    func testSHA256KnownVector() throws {
        // "abc" 的 SHA-256 是公开测试向量
        let file = workDir.appendingPathComponent("a.bin")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try AssetHasher.sha256(of: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSHA256MatchesAcrossIdenticalContent() throws {
        let a = workDir.appendingPathComponent("a.bin")
        let b = workDir.appendingPathComponent("b.bin")
        let content = Data((0..<5000).map { UInt8($0 % 251) })
        try content.write(to: a)
        try content.write(to: b)
        XCTAssertEqual(try AssetHasher.sha256(of: a), try AssetHasher.sha256(of: b))
    }

    func testAssetItemSHA256RoundTrip() throws {
        let item = AssetItem(kind: .video, fileName: "x.mp4", sha256: "deadbeef")
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(AssetItem.self, from: data), item)
    }

    func testAssetItemDecodesWithoutSHA256() throws {
        // 旧格式 JSON（无 sha256 字段）解码为 nil，向后兼容
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","kind":"video","fileName":"x.mp4"}"#
        let item = try JSONDecoder().decode(AssetItem.self, from: Data(json.utf8))
        XCTAssertNil(item.sha256)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd Packages/JangyCore && swift test --filter AssetHasherTests`
Expected: FAIL — 编译错误，`AssetHasher` 不存在、`sha256` 参数不存在

- [ ] **Step 3: 实现**

创建 `Packages/JangyCore/Sources/JangyCore/AssetHasher.swift`：

```swift
import CryptoKit
import Foundation

/// 文件内容哈希：素材库去重（同一内容只存一份）的依据。
/// 流式读取，4K 大文件不全量进内存。
public enum AssetHasher {
    public static func sha256(of url: URL) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: chunkSize)
            if read < 0 { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
            if read == 0 { break }
            hasher.update(data: Data(bytes: buffer, count: read))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
```

修改 `Packages/JangyCore/Sources/JangyCore/AssetItem.swift`——加 `sha256` 字段，并给 struct 声明加 `Hashable`（Task 12 的 `navigationDestination(item:)` 需要）：

```swift
public struct AssetItem: Codable, Equatable, Hashable, Identifiable, Sendable {
```

```swift
    public var importedAt: Date?
    /// 内容哈希（SHA-256 十六进制）。素材库去重依据；旧数据为 nil（不参与去重判定）。
    public var sha256: String?
```

init 末尾加参数 `sha256: String? = nil` 与赋值 `self.sha256 = sha256`；CodingKeys 加 `sha256`；宽容解码末尾加：

```swift
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd Packages/JangyCore && swift test --filter AssetHasherTests`
Expected: PASS（4 个测试）

- [ ] **Step 5: Commit**

```bash
git add Packages/JangyCore/Sources/JangyCore/AssetHasher.swift Packages/JangyCore/Sources/JangyCore/AssetItem.swift Packages/JangyCore/Tests/JangyCoreTests/AssetHasherTests.swift
git commit -m "Core: AssetItem 增加 sha256 字段 + AssetHasher 流式哈希——素材库内容去重的数据基础

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 2: AssetImporter 泛化（图片/音频入库 + 元数据探测）

**Files:**
- Modify: `Packages/JangyCore/Sources/JangyCore/AssetImporter.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/AssetImporterTests.swift`

背景：`importVideo` 保持不动（现有测试与语义依赖它，不算 sha256）。新增 `importMedia` 支持三类素材并计算 sha256。

- [ ] **Step 1: 写失败测试**

在 `AssetImporterTests.swift` 末尾追加（文件头部已有 import，直接加测试类）：

```swift
/// importMedia 泛化入库：三类素材的元数据探测 + sha256 登记。
final class AssetImporterMediaTests: XCTestCase {

    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    /// 最小合法 PNG（1x1 红点），CGImageSource 可读尺寸
    private func makePNG() throws -> URL {
        let url = workDir.appendingPathComponent("pixel.png")
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        try data.write(to: url)
        return url
    }

    /// 最小 WAV（PCM 头 + 0.5 秒 8kHz 单声道静音）
    private func makeWAV() throws -> URL {
        let url = workDir.appendingPathComponent("tone.wav")
        let sampleRate: UInt32 = 8000
        let samples = Int(sampleRate / 2)
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLE(UInt32(36 + samples))
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.appendLE(UInt32(16))          // fmt 块长
        data.appendLE(UInt16(1))           // PCM
        data.appendLE(UInt16(1))           // 单声道
        data.appendLE(sampleRate)
        data.appendLE(sampleRate)          // byteRate = rate * 1 * 1
        data.appendLE(UInt16(1))           // blockAlign
        data.appendLE(UInt16(8))           // 8bit
        data.append(contentsOf: "data".utf8)
        data.appendLE(UInt32(samples))
        data.append(Data(repeating: 128, count: samples))  // 8bit PCM 静音 = 128
        try data.write(to: url)
        return url
    }

    func testImportImageProbesPixelSize() async throws {
        let source = try makePNG()
        let importer = AssetImporter(directory: workDir.appendingPathComponent("Assets"))
        let item = try await importer.importMedia(from: source, kind: .image, origin: .files)
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.pixelWidth, 1)
        XCTAssertEqual(item.pixelHeight, 1)
        XCTAssertNil(item.duration)
        XCTAssertNotNil(item.sha256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: importer.directory.appendingPathComponent(item.fileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "move 语义：源文件不留残余")
    }

    func testImportAudioProbesDuration() async throws {
        let source = try makeWAV()
        let importer = AssetImporter(directory: workDir.appendingPathComponent("Assets"))
        let item = try await importer.importMedia(from: source, kind: .audio, origin: .files)
        XCTAssertEqual(item.kind, .audio)
        XCTAssertEqual(item.duration ?? 0, 0.5, accuracy: 0.05)
        XCTAssertNotNil(item.sha256)
    }

    func testImportMediaComputesSHA256UnlessKnown() async throws {
        let source = try makePNG()
        let importer = AssetImporter(directory: workDir.appendingPathComponent("Assets"))
        let item = try await importer.importMedia(from: source, kind: .image, origin: .files,
                                                  knownSHA256: "preset-hash")
        XCTAssertEqual(item.sha256, "preset-hash", "调用方已算好哈希时不重复读盘")
    }
}

/// Data 小端追加助手（WAV 头构造用）
private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: MemoryLayout<T>.size))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd Packages/JangyCore && swift test --filter AssetImporterMediaTests`
Expected: FAIL — 编译错误，`importMedia` 不存在

- [ ] **Step 3: 实现**

在 `AssetImporter.swift` 中，`importVideo` 之后追加（顶部 import 加 `ImageIO`）：

```swift
    /// 图片元数据探测：ImageIO 读像素尺寸（不解码像素，快）。无时长/音频概念。
    public static func probeImageMetadata(of url: URL) -> AssetMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return AssetMetadata()
        }
        return AssetMetadata(
            duration: nil,
            pixelWidth: props[kCGImagePropertyPixelWidth] as? Int,
            pixelHeight: props[kCGImagePropertyPixelHeight] as? Int,
            hasAudio: nil
        )
    }

    /// 音频元数据探测：只取时长。
    public static func probeAudioMetadata(of url: URL) async -> AssetMetadata {
        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration)
        return AssetMetadata(duration: duration.flatMap { $0.isNumeric ? $0.seconds : nil },
                             pixelWidth: nil, pixelHeight: nil, hasAudio: nil)
    }

    /// 通用素材入库：视频/图片/音频。sha256 在 move 前计算（素材库去重判定的依据）；
    /// 调用方已算过可经 knownSHA256 传入，避免大文件重复读盘。
    @discardableResult
    public func importMedia(from sourceURL: URL, kind: AssetKind, origin: AssetOrigin,
                            displayName: String? = nil, knownSHA256: String? = nil) async throws -> AssetItem {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = try knownSHA256 ?? AssetHasher.sha256(of: sourceURL)

        let ext = sourceURL.pathExtension.isEmpty ? Self.defaultExtension(for: kind) : sourceURL.pathExtension
        let fileName = "\(UUID().uuidString).\(ext)"
        let destination = directory.appendingPathComponent(fileName)
        try fm.moveItem(at: sourceURL, to: destination)

        let metadata: AssetMetadata
        switch kind {
        case .video: metadata = await Self.probeMetadata(of: destination)
        case .image: metadata = Self.probeImageMetadata(of: destination)
        case .audio: metadata = await Self.probeAudioMetadata(of: destination)
        case .subtitle: metadata = AssetMetadata()
        }

        return AssetItem(
            kind: kind,
            fileName: fileName,
            displayName: displayName ?? sourceURL.deletingPathExtension().lastPathComponent,
            origin: origin,
            duration: metadata.duration,
            pixelWidth: metadata.pixelWidth,
            pixelHeight: metadata.pixelHeight,
            hasAudio: metadata.hasAudio,
            importedAt: Date(),
            sha256: hash
        )
    }

    private static func defaultExtension(for kind: AssetKind) -> String {
        switch kind {
        case .video: return "mp4"
        case .image: return "jpg"
        case .audio: return "m4a"
        case .subtitle: return "srt"
        }
    }
```

同时把文件顶部 `import AVFoundation / import Foundation` 处补上 `import ImageIO`。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd Packages/JangyCore && swift test --filter AssetImporter`
Expected: PASS（新旧测试全绿，含原 AssetImporterTests）

- [ ] **Step 5: Commit**

```bash
git add Packages/JangyCore/Sources/JangyCore/AssetImporter.swift Packages/JangyCore/Tests/JangyCoreTests/AssetImporterTests.swift
git commit -m "Core: AssetImporter 泛化 importMedia——图片(ImageIO 尺寸)/音频(时长)入库 + sha256 登记；importVideo 保持不动

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 3: AssetLibrary 全局素材登记表

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/AssetLibrary.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/AssetLibraryTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `Packages/JangyCore/Tests/JangyCoreTests/AssetLibraryTests.swift`：

```swift
import XCTest
@testable import JangyCore
@testable import JangyTestSupport

/// 全局素材库登记表：library.json 读写、哈希去重入库、删除清理、一致性校验。
final class AssetLibraryTests: XCTestCase {

    private var root: URL!
    private var library: AssetLibrary!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = AssetLibrary(root: root)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        library = nil
    }

    private func makeTempVideo() throws -> URL {
        // 复用测试素材合成器产物做导入源（拷贝到独立临时文件，importFile 是 move 语义）
        let sourceDir = root.appendingPathComponent("src-\(UUID().uuidString)")
        _ = try AssetSynthesizer.synthesize(into: sourceDir)
        return sourceDir.appendingPathComponent(AssetSynthesizer.clipFileNames[0])
    }

    func testEmptyLibraryLoadsEmpty() throws {
        XCTAssertEqual(try library.load(), [])
    }

    func testImportRegistersAndSaves() async throws {
        let source = try makeTempVideo()
        let (item, isNew) = try await library.importFile(from: source, kind: .video, origin: .files)
        XCTAssertTrue(isNew)
        XCTAssertEqual(try library.load(), [item])
        XCTAssertTrue(library.resolver.exists(item))
    }

    func testDuplicateContentReusesExistingEntry() async throws {
        let first = try await library.importFile(from: makeTempVideo(), kind: .video, origin: .files)
        let second = try await library.importFile(from: makeTempVideo(), kind: .video, origin: .files)
        XCTAssertTrue(first.isNew)
        XCTAssertFalse(second.isNew)
        XCTAssertEqual(first.item.id, second.item.id, "同内容复用同一 assetID")
        XCTAssertEqual(try library.load().count, 1, "登记表不重复")
        let files = try FileManager.default.contentsOfDirectory(atPath: library.assetsDir.path)
        XCTAssertEqual(files.count, 1, "磁盘只占一份")
    }

    func testRemoveCleansRegistryAndFile() async throws {
        let (item, _) = try await library.importFile(from: makeTempVideo(), kind: .video, origin: .files)
        try library.remove(ids: [item.id])
        XCTAssertEqual(try library.load(), [])
        XCTAssertFalse(library.resolver.exists(item))
    }

    func testVerifyReportsMissingAndUnregistered() async throws {
        let (item, _) = try await library.importFile(from: makeTempVideo(), kind: .video, origin: .files)
        // 手删磁盘文件 → missing；丢一个未登记文件 → unregistered
        try FileManager.default.removeItem(at: library.resolver.resolve(item))
        try Data("orphan".utf8).write(to: library.assetsDir.appendingPathComponent("orphan.bin"))
        let report = try library.verify()
        XCTAssertEqual(report.missingFiles.map(\.id), [item.id])
        XCTAssertEqual(report.unregisteredFiles, ["orphan.bin"])
        XCTAssertFalse(report.isEmpty)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd Packages/JangyCore && swift test --filter AssetLibraryTests`
Expected: FAIL — 编译错误，`AssetLibrary` 不存在

- [ ] **Step 3: 实现**

创建 `Packages/JangyCore/Sources/JangyCore/AssetLibrary.swift`：

```swift
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
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd Packages/JangyCore && swift test --filter AssetLibraryTests`
Expected: PASS（5 个测试）

- [ ] **Step 5: Commit**

```bash
git add Packages/JangyCore/Sources/JangyCore/AssetLibrary.swift Packages/JangyCore/Tests/JangyCoreTests/AssetLibraryTests.swift
git commit -m "Core: AssetLibrary 全局素材登记表——library.json 事实源 + SHA-256 去重入库 + 双向一致性校验

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 4: ProjectStore（多项目持久层）+ DraftStore 删除

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/ProjectStore.swift`
- Delete: `Packages/JangyCore/Sources/JangyCore/DraftStore.swift`
- Delete: `Packages/JangyCore/Tests/JangyCoreTests/DraftStoreTests.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/ProjectStoreTests.swift`

背景：DraftStore 的使用方只有 AppModel/JangyApp（CLI 不依赖），ProjectStore 吸收其全部职责（save/load/版本守卫/完整性校验），按删改原则整体删除。`DraftIntegrityReport`/`AssetDrift` 类型平移到 ProjectStore.swift。

- [ ] **Step 1: 写失败测试**

创建 `Packages/JangyCore/Tests/JangyCoreTests/ProjectStoreTests.swift`（覆盖 DraftStoreTests 原有场景 + 多项目新场景）：

```swift
import XCTest
@testable import JangyCore
@testable import JangyTestSupport

/// ProjectStore：项目 CRUD / 列表扫描 / 版本守卫 / 完整性校验 / 旧布局迁移。
final class ProjectStoreTests: XCTestCase {

    private var root: URL!
    private var store: ProjectStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(root: root)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        store = nil
    }

    func testCreateAndLoadRoundTrip() throws {
        let summary = try store.createProject(name: "测试项目")
        XCTAssertEqual(summary.name, "测试项目")
        XCTAssertEqual(try store.loadProject(id: summary.id), EditPlan(clips: []))
        XCTAssertEqual(try store.loadMeta(id: summary.id).name, "测试项目")
    }

    func testSaveLoadPlanRoundTrip() throws {
        let summary = try store.createProject(name: "A")
        let plan = SamplePlan.make()
        try store.saveProject(id: summary.id, plan: plan)
        XCTAssertEqual(try store.loadProject(id: summary.id), plan)
    }

    func testRepeatedSavesAreByteIdentical() throws {
        let summary = try store.createProject(name: "A")
        let plan = SamplePlan.make()
        try store.saveProject(id: summary.id, plan: plan)
        let url = store.projectDirectory(id: summary.id).appendingPathComponent(ProjectStore.planFileName)
        let first = try Data(contentsOf: url)
        try store.saveProject(id: summary.id, plan: plan)
        XCTAssertEqual(first, try Data(contentsOf: url), "sortedKeys 格式下未变更的两次保存应字节一致")
    }

    func testSchemaGuardRejectsNewerVersion() throws {
        let summary = try store.createProject(name: "A")
        var plan = EditPlan(clips: [])
        plan.version = ProjectStore.currentSchemaVersion + 1
        try store.saveProject(id: summary.id, plan: plan)
        XCTAssertThrowsError(try store.loadProject(id: summary.id)) { error in
            guard case ProjectStoreError.unsupportedVersion(let found, _) = error else {
                return XCTFail("应抛 unsupportedVersion，实际: \(error)")
            }
            XCTAssertEqual(found, ProjectStore.currentSchemaVersion + 1)
        }
    }

    func testListProjectsSortedByModifiedDesc() throws {
        let a = try store.createProject(name: "A")
        let b = try store.createProject(name: "B")
        // 触碰 A 使其修改时间更新
        try store.saveProject(id: a.id, plan: EditPlan(clips: []))
        let names = try store.listProjects().map(\.name)
        XCTAssertEqual(names, ["A", "B"], "修改时间倒序；同秒精度下后写入的 A 在前")
        _ = b
    }

    func testUniqueName() throws {
        _ = try store.createProject(name: "未命名项目")
        _ = try store.createProject(name: store.uniqueName(base: "未命名项目"))
        let names = try store.listProjects().map(\.name)
        XCTAssertTrue(names.contains("未命名项目"))
        XCTAssertTrue(names.contains("未命名项目 2"))
    }

    func testRename() throws {
        let summary = try store.createProject(name: "旧名")
        try store.renameProject(id: summary.id, to: "新名")
        XCTAssertEqual(try store.loadMeta(id: summary.id).name, "新名")
    }

    func testDuplicateCopiesPlanNotAssets() throws {
        let summary = try store.createProject(name: "原始")
        try store.saveProject(id: summary.id, plan: SamplePlan.make())
        let copy = try store.duplicateProject(id: summary.id)
        XCTAssertEqual(copy.name, "原始 副本")
        XCTAssertEqual(try store.loadProject(id: copy.id), SamplePlan.make(), "plan 深拷贝（引用语义下无需拷素材）")
        XCTAssertNotEqual(copy.id, summary.id)
    }

    func testDelete() throws {
        let summary = try store.createProject(name: "A")
        try store.deleteProject(id: summary.id)
        XCTAssertEqual(try store.listProjects(), [])
        XCTAssertThrowsError(try store.loadProject(id: summary.id))
    }

    func testVerifyReportsMissingAsset() async throws {
        let summary = try store.createProject(name: "A")
        let plan = SamplePlan.make()  // 引用 clip1/2/3.mp4 + sample.srt，但 Assets 目录为空
        let report = await store.verify(plan: plan, resolver: AssetLibrary(root: root).resolver)
        XCTAssertEqual(report.missing.count, plan.assets.count)
        XCTAssertFalse(report.isEmpty)
        _ = summary
    }

    /// 旧布局迁移：draft.json → Projects/<uuid>/project.json；散落素材 → Assets/；
    /// library.json 从迁移项目的 plan.assets 播种（含 sha256 计算）。
    func testMigrateLegacyLayout() async throws {
        // 摆出旧布局：draft.json + 散落素材文件 + agent-config.json 同级
        let plan = SamplePlan.make()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(plan).write(to: root.appendingPathComponent("draft.json"))
        _ = try AssetSynthesizer.synthesize(into: root)  // 素材直接散落 root（旧布局）
        try Data("{}".utf8).write(to: root.appendingPathComponent("agent-config.json"))

        let migrated = try store.migrateLegacyLayoutIfNeeded()
        XCTAssertTrue(migrated)

        // draft.json 消失，项目出现
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("draft.json").path))
        let projects = try store.listProjects()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].name, "未命名项目")
        XCTAssertEqual(try store.loadProject(id: projects[0].id), plan)

        // 素材进 Assets/，agent-config.json 原地不动
        let library = AssetLibrary(root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.assetsDir.appendingPathComponent("clip1.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("agent-config.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("clip1.mp4").path))

        // library.json 从迁移项目播种
        let registry = try library.load()
        XCTAssertEqual(Set(registry.map(\.id)), Set(plan.assets.map(\.id)))

        // 幂等：再跑一遍无变化
        XCTAssertFalse(try store.migrateLegacyLayoutIfNeeded())
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd Packages/JangyCore && swift test --filter ProjectStoreTests`
Expected: FAIL — 编译错误，`ProjectStore` 不存在

- [ ] **Step 3: 实现**

创建 `Packages/JangyCore/Sources/JangyCore/ProjectStore.swift`：

```swift
import Foundation

/// 项目元信息：不放 plan JSON（不动清单：draft.json 格式不变），独立 meta.json。
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
    public static let currentSchemaVersion = 2

    /// App 支持目录根（Application Support/Jangy）
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var projectsDir: URL { root.appendingPathComponent(Self.projectsDirName, isDirectory: true) }

    public func projectDirectory(id: UUID) -> URL {
        projectsDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: - CRUD

    public func createProject(name: String) throws -> ProjectSummary {
        let id = UUID()
        let dir = projectDirectory(id: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try saveMeta(ProjectMeta(id: id, name: name))
        try saveProject(id: id, plan: EditPlan(clips: []))
        return try summary(for: id)
    }

    public func loadProject(id: UUID) throws -> EditPlan {
        let url = projectDirectory(id: id).appendingPathComponent(Self.planFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectStoreError.projectNotFound(id)
        }
        let plan = try PlanLoader.load(from: url)
        guard plan.version <= Self.currentSchemaVersion else {
            throw ProjectStoreError.unsupportedVersion(found: plan.version, supported: Self.currentSchemaVersion)
        }
        return plan
    }

    /// 原子写入：先写同目录临时文件再 rename，中途崩溃不留半截 JSON。
    public func saveProject(id: UUID, plan: EditPlan) throws {
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
        let plan = try loadProject(id: id)
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
        let plan = try loadProject(id: id)
        let planURL = projectDirectory(id: id).appendingPathComponent(Self.planFileName)
        let modified = (try? FileManager.default.attributesOfItem(atPath: planURL.path))?[.modificationDate] as? Date ?? meta.createdAt
        return ProjectSummary(id: id, name: meta.name, createdAt: meta.createdAt, modifiedAt: modified,
                              clipCount: plan.clips.count, duration: plan.renderedDuration,
                              referencedAssetCount: plan.assets.count, directory: projectDirectory(id: id))
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
            let plan = try PlanLoader.load(from: legacyDraft)
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
                guard let plan = try? loadProject(id: summary.id) else { continue }
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
```

- [ ] **Step 4: 删除 DraftStore**

```bash
rm Packages/JangyCore/Sources/JangyCore/DraftStore.swift
rm Packages/JangyCore/Tests/JangyCoreTests/DraftStoreTests.swift
```

同步修改 `Packages/JangyCore/Sources/JangyCore/AssetImporter.swift` 中引用 DraftStore 的注释（`probeMetadata` 的 doc comment）：「DraftStore 完整性比对与 importVideo 共用此入口」→「ProjectStore 完整性比对与 importVideo 共用此入口」。

- [ ] **Step 5: 跑测试确认通过**

Run: `cd Packages/JangyCore && swift test --filter ProjectStoreTests`
Expected: PASS（11 个测试）

再跑全量确认无遗漏引用：`cd Packages/JangyCore && swift test`
Expected: 全绿（DraftStoreTests 的 6 个场景已被 ProjectStoreTests 覆盖，总数变化属预期）

- [ ] **Step 6: Commit**

```bash
git add -A Packages/JangyCore
git commit -m "Core: DraftStore 演进为 ProjectStore——多项目目录结构 + 列表扫描派生 + 旧布局迁移（draft.json→Projects、散落素材→Assets、library.json 播种）

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 5: ReferenceScanner（引用关系读时扫描）

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/ReferenceScanner.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/ReferenceScannerTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `Packages/JangyCore/Tests/JangyCoreTests/ReferenceScannerTests.swift`：

```swift
import XCTest
@testable import JangyCore
@testable import JangyTestSupport

/// 引用扫描：assetID → 引用它的项目集。素材侧不存反向数据，用到时扫。
final class ReferenceScannerTests: XCTestCase {

    private var root: URL!
    private var store: ProjectStore!
    private var scanner: ReferenceScanner!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(root: root)
        scanner = ReferenceScanner(projectStore: store)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil; store = nil; scanner = nil
    }

    func testScanCollectsAssetReferences() throws {
        let a = try store.createProject(name: "A")
        let b = try store.createProject(name: "B")
        try store.saveProject(id: a.id, plan: SamplePlan.make())
        try store.saveProject(id: b.id, plan: EditPlan(clips: []))

        let refs = try scanner.scan()
        // SamplePlan 的全部素材都引用自项目 A；空项目 B 不产生任何条目
        for asset in SamplePlan.make().assets {
            XCTAssertEqual(refs[asset.id], Set([a.id]))
        }
        XCTAssertFalse(refs.values.contains { $0.contains(b.id) })
    }

    func testInMemoryPlanOverridesDisk() throws {
        let a = try store.createProject(name: "A")
        try store.saveProject(id: a.id, plan: SamplePlan.make())
        // 内存 plan 已是空时间线（未落盘）：扫描应以内存为准
        let refs = try scanner.scan(currentProjectID: a.id, currentPlan: EditPlan(clips: []))
        XCTAssertTrue(refs.isEmpty, "当前项目的未落盘编辑要参与扫描")
    }

    func testCorruptProjectFailsScan() throws {
        let a = try store.createProject(name: "A")
        // 写坏 project.json
        try Data("not json".utf8).write(to: store.projectDirectory(id: a.id)
            .appendingPathComponent(ProjectStore.planFileName))
        XCTAssertThrowsError(try scanner.scan()) { error in
            guard case ReferenceScanError.corruptProject(let id) = error else {
                return XCTFail("应抛 corruptProject，实际: \(error)")
            }
            XCTAssertEqual(id, a.id)
        }
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd Packages/JangyCore && swift test --filter ReferenceScannerTests`
Expected: FAIL — 编译错误，`ReferenceScanner` 不存在

- [ ] **Step 3: 实现**

创建 `Packages/JangyCore/Sources/JangyCore/ReferenceScanner.swift`：

```swift
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
                plan = loaded
            }
            for asset in plan.assets {
                result[asset.id, default: []].insert(id)
            }
        }
        return result
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd Packages/JangyCore && swift test --filter ReferenceScannerTests`
Expected: PASS（3 个测试）

- [ ] **Step 5: Commit**

```bash
git add Packages/JangyCore/Sources/JangyCore/ReferenceScanner.swift Packages/JangyCore/Tests/JangyCoreTests/ReferenceScannerTests.swift
git commit -m "Core: ReferenceScanner——素材引用读时扫描（assetID→项目集），损坏项目保守拒删

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 6: ZipArchive（store-only 最小 ZIP 读写）

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/ZipArchive.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/ZipArchiveTests.swift`

背景：工程包格式是 zip。不引第三方依赖——媒体文件本身已压缩，store（不压缩）几乎无体积损失；自产自读的包只需支持 method 0。防 zip slip（拒绝含 `..` 的条目名）。

- [ ] **Step 1: 写失败测试**

创建 `Packages/JangyCore/Tests/JangyCoreTests/ZipArchiveTests.swift`：

```swift
import XCTest
@testable import JangyCore

/// store-only ZIP 读写：round-trip 字节一致、嵌套目录、zip slip 防护。
final class ZipArchiveTests: XCTestCase {

    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    func testRoundTrip() throws {
        let src = workDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("assets"),
                                                withIntermediateDirectories: true)
        let files: [(String, Data)] = [
            ("project.json", Data(#"{"clips":[]}"#.utf8)),
            ("assets/a.mp4", Data((0..<3000).map { UInt8($0 % 241) })),
            ("assets/b.jpg", Data("jpeg-bytes".utf8)),
        ]
        for (name, data) in files {
            try data.write(to: src.appendingPathComponent(name))
        }

        let zip = workDir.appendingPathComponent("pkg.zip")
        try ZipArchive.zip(contentsOf: src, to: zip)

        let dst = workDir.appendingPathComponent("dst")
        try ZipArchive.unzip(zip, into: dst)

        for (name, data) in files {
            XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent(name)), data,
                           "\(name) round-trip 应字节一致")
        }
    }

    func testRejectsZipSlip() throws {
        // 手工构造一个条目名为 "../evil" 的最小 zip（store 方法）
        let name = "../evil"
        let payload = Data("x".utf8)
        let crc = ZipArchive.crc32(payload)
        var zip = Data()
        // local file header
        zip.appendLE(UInt32(0x04034b50)); zip.appendLE(UInt16(20)); zip.appendLE(UInt16(0))
        zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
        zip.appendLE(crc); zip.appendLE(UInt32(payload.count)); zip.appendLE(UInt32(payload.count))
        zip.appendLE(UInt16(name.utf8.count)); zip.appendLE(UInt16(0))
        zip.append(contentsOf: name.utf8); zip.append(payload)
        let centralOffset = UInt32(zip.count)
        // central directory
        zip.appendLE(UInt32(0x02014b50)); zip.appendLE(UInt16(20)); zip.appendLE(UInt16(20))
        zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
        zip.appendLE(crc); zip.appendLE(UInt32(payload.count)); zip.appendLE(UInt32(payload.count))
        zip.appendLE(UInt16(name.utf8.count)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
        zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0)); zip.appendLE(UInt32(0)); zip.appendLE(UInt32(0))
        zip.append(contentsOf: name.utf8)
        // EOCD
        zip.appendLE(UInt32(0x06054b50)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
        zip.appendLE(UInt16(1)); zip.appendLE(UInt16(1))
        zip.appendLE(UInt32(zip.count - Int(centralOffset))); zip.appendLE(centralOffset)
        zip.appendLE(UInt16(0))

        let zipURL = workDir.appendingPathComponent("evil.zip")
        try zip.write(to: zipURL)
        XCTAssertThrowsError(try ZipArchive.unzip(zipURL, into: workDir.appendingPathComponent("out"))) { error in
            guard case ZipArchive.ZipError.unsafeEntryName = error else {
                return XCTFail("应抛 unsafeEntryName，实际: \(error)")
            }
        }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: MemoryLayout<T>.size))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd Packages/JangyCore && swift test --filter ZipArchiveTests`
Expected: FAIL — 编译错误，`ZipArchive` 不存在

- [ ] **Step 3: 实现**

创建 `Packages/JangyCore/Sources/JangyCore/ZipArchive.swift`：

```swift
import Foundation

/// 最小 ZIP 读写：工程包容器。写 = store（不压缩——媒体文件本身已压缩，压缩无收益）；
/// 读 = 仅支持 store 条目（本 App 自产包）。防 zip slip（拒绝含 ".." 的条目名）。
public enum ZipArchive {

    public enum ZipError: Error, Equatable, CustomStringConvertible {
        case unsupportedCompression(String)
        case malformedArchive
        case unsafeEntryName(String)
        case crcMismatch(String)

        public var description: String {
            switch self {
            case .unsupportedCompression(let name):
                return "不支持的压缩条目（仅支持 store）: \(name)"
            case .malformedArchive:
                return "zip 文件损坏或格式不符"
            case .unsafeEntryName(let name):
                return "zip 包含不安全的路径条目: \(name)"
            case .crcMismatch(let name):
                return "zip 条目校验失败（数据损坏）: \(name)"
            }
        }
    }

    // MARK: - CRC32

    private static let crcTable: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB88320 : c >> 1 }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - 写

    /// 把目录内全部文件（递归）打进 zip。条目名用相对路径（/ 分隔）。
    public static func zip(contentsOf directory: URL, to zipURL: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return }

        var entries: [(name: String, data: Data, crc: UInt32, offset: UInt32)] = []
        var out = Data()
        for case let fileURL as URL in enumerator {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fileURL.path, isDirectory: &isDir)
            guard !isDir.boolValue else { continue }
            let name = String(fileURL.path.dropFirst(directory.path.count + 1))
            let data = try Data(contentsOf: fileURL)
            let crc = crc32(data)
            entries.append((name, data, crc, UInt32(out.count)))

            out.appendLE(UInt32(0x04034b50))  // local header sig
            out.appendLE(UInt16(20))          // version needed
            out.appendLE(UInt16(0))           // flags
            out.appendLE(UInt16(0))           // method: store
            out.appendLE(UInt16(0)); out.appendLE(UInt16(0))  // mod time/date（不记录）
            out.appendLE(crc)
            out.appendLE(UInt32(data.count)); out.appendLE(UInt32(data.count))
            out.appendLE(UInt16(name.utf8.count)); out.appendLE(UInt16(0))
            out.append(contentsOf: name.utf8)
            out.append(data)
        }

        let centralOffset = UInt32(out.count)
        for entry in entries {            out.appendLE(UInt32(0x02014b50))  // central sig
            out.appendLE(UInt16(20)); out.appendLE(UInt16(20))
            out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
            out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
            out.appendLE(entry.crc)
            out.appendLE(UInt32(entry.data.count)); out.appendLE(UInt32(entry.data.count))
            out.appendLE(UInt16(entry.name.utf8.count))
            out.appendLE(UInt16(0)); out.appendLE(UInt16(0))  // comment/extra
            out.appendLE(UInt16(0)); out.appendLE(UInt16(0))  // disk/internal attrs
            out.appendLE(UInt32(0))                            // external attrs
            out.appendLE(entry.offset)
            out.append(contentsOf: entry.name.utf8)
        }

        let centralSize = UInt32(out.count - Int(centralOffset))  // 先算长度再写 EOCD
        out.appendLE(UInt32(0x06054b50))  // EOCD sig
        out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count)); out.appendLE(UInt16(entries.count))
        out.appendLE(centralSize); out.appendLE(centralOffset)
        out.appendLE(UInt16(0))
        try out.write(to: zipURL, options: .atomic)
    }

    // MARK: - 读

    /// 解包到目录（自动创建）。只支持 store 条目；CRC 校验；拒绝 ".." 路径。
    public static func unzip(_ zipURL: URL, into directory: URL) throws {
        let data = try Data(contentsOf: zipURL)
        // 从尾部找 EOCD（无 comment 的自产包直接在末尾，宽容起见扫最后 64KB）
        let searchStart = max(0, data.count - 65536 - 22)
        var eocdOffset: Int?
        var i = data.count - 22
        while i >= searchStart {
            if data[i] == 0x50 && data[i + 1] == 0x4B && data[i + 2] == 0x05 && data[i + 3] == 0x06 {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard let eocd = eocdOffset else { throw ZipError.malformedArchive }

        let entryCount = Int(readUInt16(data, at: eocd + 10))
        var offset = Int(readUInt32(data, at: eocd + 16))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for _ in 0..<entryCount {
            guard readUInt32(data, at: offset) == 0x02014b50 else { throw ZipError.malformedArchive }
            let method = readUInt16(data, at: offset + 10)
            let crc = readUInt32(data, at: offset + 16)
            let size = Int(readUInt32(data, at: offset + 20))
            let nameLen = Int(readUInt16(data, at: offset + 28))
            let extraLen = Int(readUInt16(data, at: offset + 30))
            let commentLen = Int(readUInt16(data, at: offset + 32))
            let localOffset = Int(readUInt32(data, at: offset + 42))
            let name = String(decoding: data[(offset + 46)..<(offset + 46 + nameLen)], as: UTF8.self)

            guard !name.contains("..") && !name.hasPrefix("/") else {
                throw ZipError.unsafeEntryName(name)
            }
            guard method == 0 else { throw ZipError.unsupportedCompression(name) }

            // local header：跳过其可变长 name/extra 取数据
            guard readUInt32(data, at: localOffset) == 0x04034b50 else { throw ZipError.malformedArchive }
            let localNameLen = Int(readUInt16(data, at: localOffset + 26))
            let localExtraLen = Int(readUInt16(data, at: localOffset + 28))
            let dataStart = localOffset + 30 + localNameLen + localExtraLen
            let payload = Data(data[dataStart..<(dataStart + size)])
            guard crc32(payload) == crc else { throw ZipError.crcMismatch(name) }

            let dest = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try payload.write(to: dest)

            offset += 46 + nameLen + extraLen + commentLen
        }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: MemoryLayout<T>.size))
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd Packages/JangyCore && swift test --filter ZipArchiveTests`
Expected: PASS（2 个测试）

- [ ] **Step 5: Commit**

```bash
git add Packages/JangyCore/Sources/JangyCore/ZipArchive.swift Packages/JangyCore/Tests/JangyCoreTests/ZipArchiveTests.swift
git commit -m "Core: ZipArchive——store-only 最小 ZIP 读写（工程包容器，无新依赖，防 zip slip）

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 7: ProjectPackage（工程包导出/导入）

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/ProjectPackage.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/ProjectPackageTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `Packages/JangyCore/Tests/JangyCoreTests/ProjectPackageTests.swift`：

```swift
import XCTest
@testable import JangyCore
@testable import JangyTestSupport

/// 工程包：导出 → 导入往返等价、assetID 冲突改写、哈希去重、原子性。
final class ProjectPackageTests: XCTestCase {

    private var root: URL!
    private var store: ProjectStore!
    private var library: AssetLibrary!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ProjectStore(root: root)
        library = AssetLibrary(root: root)
        // 素材入库（SamplePlan 引用的 clip1/2/3.mp4 + sample.srt）
        let srcDir = root.appendingPathComponent("src")
        _ = try AssetSynthesizer.synthesize(into: srcDir)
        let plan = SamplePlan.make()
        for asset in plan.assets {
            let temp = root.appendingPathComponent("tmp-\(asset.fileName)")
            try FileManager.default.copyItem(at: srcDir.appendingPathComponent(asset.fileName), to: temp)
            _ = try await library.importFile(from: temp, kind: asset.kind, origin: asset.origin)
        }
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil; store = nil; library = nil
    }

    /// 素材已入库后造一个引用它们的项目
    private func makeProject(name: String) throws -> ProjectSummary {
        let summary = try store.createProject(name: name)
        let libraryItems = try library.load()
        // setUp 按 plan.assets 顺序导入；入库后 fileName 变成 UUID 名，
        // 按 kind + 未占用顺序对应回原素材
        var plan = SamplePlan.make()
        var used: Set<UUID> = []
        var idMap: [UUID: UUID] = [:]
        for (index, asset) in plan.assets.enumerated() {
            let lib = libraryItems.first { $0.kind == asset.kind && !used.contains($0.id) }!
            used.insert(lib.id)
            idMap[asset.id] = lib.id
            plan.assets[index] = lib
        }
        plan.clips = plan.clips.map { PlanClip(id: $0.id, assetID: idMap[$0.assetID]!,
                                               range: $0.range, speed: $0.speed,
                                               transitionAfter: $0.transitionAfter) }
        if let captions = plan.captions {
            plan.captions = CaptionTrack(assetID: idMap[captions.assetID]!,
                                         isEnabled: captions.isEnabled, style: captions.style)
        }
        try store.saveProject(id: summary.id, plan: plan)
        return summary
    }

    func testExportImportRoundTrip() async throws {
        let project = try makeProject(name: "我的项目")
        let zip = root.appendingPathComponent("out.jangyproj.zip")
        try ProjectPackage.export(projectID: project.id, from: store,
                                  library: library, resolver: library.resolver, to: zip)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))

        let expectedPlan = try store.loadProject(id: project.id)
        let imported = try await ProjectPackage.import(from: zip, into: store, library: library)
        XCTAssertEqual(imported.name, "我的项目 2", "名称冲突加后缀")
        XCTAssertEqual(try store.loadProject(id: imported.id), expectedPlan,
                       "同库导入：素材哈希全部命中，plan 引用不变")
    }

    func testImportIntoFreshEnvironment() async throws {
        let project = try makeProject(name: "P")
        let zip = root.appendingPathComponent("out.jangyproj.zip")
        try ProjectPackage.export(projectID: project.id, from: store,
                                  library: library, resolver: library.resolver, to: zip)

        // 全新环境（另一个 root）
        let root2 = root.appendingPathComponent("env2")
        try FileManager.default.createDirectory(at: root2, withIntermediateDirectories: true)
        let store2 = ProjectStore(root: root2)
        let library2 = AssetLibrary(root: root2)
        let imported = try await ProjectPackage.import(from: zip, into: store2, library: library2)
        let plan = try store2.loadProject(id: imported.id)
        let registry = try library2.load()
        XCTAssertEqual(registry.count, plan.assets.count, "素材全部入库")
        for clip in plan.clips {
            XCTAssertTrue(registry.contains { $0.id == clip.assetID }, "clip 引用有效")
        }
        for asset in plan.assets {
            XCTAssertTrue(library2.resolver.exists(asset), "素材文件已落盘")
        }
    }

    func testDoubleImportDoesNotDuplicateAssets() async throws {
        let project = try makeProject(name: "P")
        let zip = root.appendingPathComponent("out.jangyproj.zip")
        try ProjectPackage.export(projectID: project.id, from: store,
                                  library: library, resolver: library.resolver, to: zip)
        let before = try library.load().count
        _ = try await ProjectPackage.import(from: zip, into: store, library: library)
        XCTAssertEqual(try library.load().count, before, "同内容素材不重复入库")
        let fileCount = try FileManager.default.contentsOfDirectory(atPath: library.assetsDir.path).count
        XCTAssertEqual(fileCount, before, "磁盘文件不重复")
    }

    func testExportFailsOnMissingAsset() throws {
        let project = try makeProject(name: "P")
        // 删掉一个被引用的素材文件
        let plan = try store.loadProject(id: project.id)
        try FileManager.default.removeItem(at: library.resolver.resolve(plan.assets[0]))
        XCTAssertThrowsError(try ProjectPackage.export(projectID: project.id, from: store,
                                                       library: library, resolver: library.resolver,
                                                       to: root.appendingPathComponent("x.zip"))) { error in
            guard case ProjectPackageError.missingAssetFile = error else {
                return XCTFail("应抛 missingAssetFile，实际: \(error)")
            }
        }
    }

    func testImportRejectsCorruptPackage() async throws {
        let junk = root.appendingPathComponent("junk.jangyproj.zip")
        try Data("not a zip".utf8).write(to: junk)
        await XCTAssertAsyncThrowsError(try await ProjectPackage.import(from: junk, into: store, library: library))
        XCTAssertEqual(try store.listProjects().count, 0, "失败不产生半成品项目")
    }
}

/// XCTest 无原生 async throws 断言，补一个
func XCTAssertAsyncThrowsError(_ expression: @autoclosure () async throws -> some Any,
                               file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("应抛错", file: file, line: line)
    } catch {}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd Packages/JangyCore && swift test --filter ProjectPackageTests`
Expected: FAIL — 编译错误，`ProjectPackage` 不存在

- [ ] **Step 3: 实现**

创建 `Packages/JangyCore/Sources/JangyCore/ProjectPackage.swift`：

```swift
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

        // 校验：manifest 版本 + plan 可解码（版本守卫在 loadProject 内）
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
                     range: $0.range, speed: $0.speed, transitionAfter: $0.transitionAfter)
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
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd Packages/JangyCore && swift test --filter ProjectPackageTests`
Expected: PASS（5 个测试）

- [ ] **Step 5: 全量回归**

Run: `cd Packages/JangyCore && swift test`
Expected: 全绿

- [ ] **Step 6: Commit**

```bash
git add Packages/JangyCore/Sources/JangyCore/ProjectPackage.swift Packages/JangyCore/Tests/JangyCoreTests/ProjectPackageTests.swift
git commit -m "Core: ProjectPackage 工程包导入导出——zip 容器 + manifest 版本守卫 + 哈希去重入库 + assetID 冲突改写 + 原子落库

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 8: CoverGenerator + PhotosBridge 图片支持

**Files:**
- Create: `Packages/JangyCore/Sources/JangyCore/CoverGenerator.swift`
- Modify: `Packages/JangyCore/Sources/JangyCore/PhotosBridge.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/CoverGeneratorTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `Packages/JangyCore/Tests/JangyCoreTests/CoverGeneratorTests.swift`：

```swift
import XCTest
@testable import JangyCore
@testable import JangyTestSupport

/// 项目封面：第一片段素材首帧 → JPEG。
final class CoverGeneratorTests: XCTestCase {

    private var workDir: URL!
    private var resolver: AssetResolver!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        resolver = try AssetSynthesizer.synthesize(into: workDir.appendingPathComponent("Assets"))
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil; resolver = nil
    }

    func testGeneratesCoverForFirstClip() async throws {
        let cover = workDir.appendingPathComponent("cover.jpg")
        await CoverGenerator.generate(for: SamplePlan.make(), resolver: resolver, to: cover)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cover.path))
        let data = try Data(contentsOf: cover)
        XCTAssertTrue(data.starts(with: [0xFF, 0xD8]), "应为 JPEG（FFD8 魔数）")
    }

    func testEmptyPlanRemovesCover() async throws {
        let cover = workDir.appendingPathComponent("cover.jpg")
        try Data("old".utf8).write(to: cover)
        await CoverGenerator.generate(for: EditPlan(clips: []), resolver: resolver, to: cover)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cover.path), "空时间线清掉旧封面")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd Packages/JangyCore && swift test --filter CoverGeneratorTests`
Expected: FAIL — 编译错误，`CoverGenerator` 不存在

- [ ] **Step 3: 实现**

创建 `Packages/JangyCore/Sources/JangyCore/CoverGenerator.swift`：

```swift
import AVFoundation
import UIKit

/// 项目封面：第一片段素材的首帧 JPEG，缓存到 Projects/<id>/cover.jpg。
/// 失败静默（封面是锦上添花，不阻断任何流程）；空时间线清掉旧封面。
public enum CoverGenerator {
    public static func generate(for plan: EditPlan, resolver: AssetResolver, to url: URL) async {
        let fm = FileManager.default
        guard let first = plan.clips.first,
              let asset = plan.asset(withID: first.assetID),
              resolver.exists(asset) else {
            try? fm.removeItem(at: url)
            return
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: resolver.resolve(asset)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        guard let cgImage = try? await generator.image(at: .zero).image,
              let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
```

修改 `PhotosBridge.swift`，在 `resolveVideoFile` 后追加图片支持：

```swift
    /// 相册素材类型探测：picker 返回的 identifier → 素材类别（视频/图片）。
    /// 解析不到 PHAsset 返回 nil（调用方按 video 路径走，会在 resolve 阶段报 assetNotFound）。
    public static func mediaType(of assetIdentifier: String) -> AssetKind? {
        guard let asset = PhotoPickerResult(assetIdentifier: assetIdentifier).resolveAsset() else {
            return nil
        }
        switch asset.mediaType {
        case .image: return .image
        case .video: return .video
        default: return nil
        }
    }

    /// 把相册图片解析成磁盘文件 URL（原始数据直出，不重编码）。
    /// 产物在临时目录，调用方负责 move 进素材库。
    @MainActor
    public static func resolveImageFile(assetIdentifier: String,
                                        progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        guard let asset = PhotoPickerResult(assetIdentifier: assetIdentifier).resolveAsset() else {
            throw BridgeError.assetNotFound(assetIdentifier)
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true   // iCloud 素材自动下载
        options.deliveryMode = .highQualityFormat
        options.progressHandler = { fraction, _, _, _ in progress?(fraction) }

        let (data, uti): (Data, String) = try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, info in
                if let data {
                    continuation.resume(returning: (data, uti ?? "public.jpeg"))
                } else {
                    let message = info?[PHImageErrorKey] as? Error
                    continuation.resume(throwing: message ?? BridgeError.assetNotFound(assetIdentifier))
                }
            }
        }
        let ext = (UTType(uti)?.preferredFilenameExtension) ?? "jpg"
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jangy-photo-\(UUID().uuidString).\(ext)")
        try data.write(to: temp)
        return temp
    }
```

（`PhotosBridge.swift` 顶部需补 `import UniformTypeIdentifiers`。）

- [ ] **Step 4: 跑测试确认通过**

Run: `cd Packages/JangyCore && swift test --filter CoverGeneratorTests`
Expected: PASS（2 个测试）。`resolveImageFile`/`mediaType` 依赖系统相册，无单测，真机验证。

- [ ] **Step 5: Commit**

```bash
git add Packages/JangyCore/Sources/JangyCore/CoverGenerator.swift Packages/JangyCore/Sources/JangyCore/PhotosBridge.swift Packages/JangyCore/Tests/JangyCoreTests/CoverGeneratorTests.swift
git commit -m "Core: CoverGenerator 项目封面（首帧 JPEG）+ PhotosBridge 图片解析（原始数据直出）与类型探测

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 9: AppModel 改造（按项目生命周期）

**Files:**
- Modify: `Jangy/AppModel.swift`

无单测（App 层），验证靠 App 构建 + Task 15 真机清单。

- [ ] **Step 1: 改写 AppModel**

`AppModel.swift` 的 AppModel 类整体替换为（PlayerController 部分保持原样不动）：

```swift
import AVFoundation
import Foundation
import Observation
import Photos
import JangyCore

/// App 侧状态装配：EditStore（编辑状态层）+ PlayerController（预览）+ 导出进度。
/// 一个实例对应一个打开的项目；切换项目 = 丢弃旧实例新建（撤销栈随之清空）。
/// 所有编辑经 edit() 进入 EditStore.apply —— 校验失败不压栈，撤销栈纹丝不动。
@MainActor
@Observable
final class AppModel {
    let projectID: UUID
    let store: EditStore
    let resolver: AssetResolver
    let player: PlayerController
    private let projectStore: ProjectStore
    private var autosaveTask: Task<Void, Never>?

    var exportProgress: Double?
    var exportMessage: String?
    var lastIssues: [ValidationIssue]?
    /// 剪辑 Agent 入口（L1）：sheet 对话 UI 的数据源；凭据缺失时 isConfigured = false。
    /// lazy：初始化器捕获 self，须待 init 完成后首次访问时执行。
    @ObservationIgnored private(set) lazy var agent = AgentController(
        store: store,
        resolver: resolver,
        credentials: AgentCredentials.load(from: projectStore.root),
        onAppliedEdit: { [weak self] in self?.handleAgentAppliedEdit() }
    )
    /// 项目相关提示：完整性报告 / 保存失败
    var projectMessage: String?

    init(projectID: UUID, store: EditStore, resolver: AssetResolver,
         projectStore: ProjectStore, restoreNotice: String? = nil) {
        self.projectID = projectID
        self.store = store
        self.resolver = resolver
        self.player = PlayerController(store: store, resolver: resolver)
        self.projectStore = projectStore
        self.projectMessage = restoreNotice
        verifyIntegrity()
    }

    /// 打开项目后异步核对登记表与磁盘素材：缺失/漂移显式报告，不静默丢。
    private func verifyIntegrity() {
        Task { @MainActor in
            let report = await projectStore.verify(plan: store.plan, resolver: resolver)
            guard !report.isEmpty else { return }
            projectMessage = "工程完整性：\(report.summary)"
        }
    }

    /// 编辑成功后的防抖自动保存：连续编辑合并为一次写盘；保存失败不阻塞编辑。
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let plan = store.plan
        let projectID = projectID
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                try projectStore.saveProject(id: projectID, plan: plan)
            } catch {
                projectMessage = "保存失败: \(error.localizedDescription)"
            }
        }
    }

    /// plan 变更后的统一下行联动：校验提示清零 + 预览重建 + 防抖落盘。
    private func afterPlanMutation() {
        lastIssues = nil
        player.rebuild()
        scheduleAutosave()
    }

    func edit(_ mutate: (inout EditPlan) -> Void) {
        switch store.apply(mutate) {
        case .success:
            afterPlanMutation()
        case .failure(let failure):
            lastIssues = failure.issues
        }
    }

    private func handleAgentAppliedEdit() {
        afterPlanMutation()
    }

    func undo() { store.undo(); afterPlanMutation() }
    func redo() { store.redo(); afterPlanMutation() }

    /// 素材从素材库上轨：登记（若未登记）+ 全长追加片段，同一次 apply（公约 §3 单撤销步）。
    /// duration 未探测的素材只登记不追加（range 无依据）。
    func appendAssetToTimeline(_ item: AssetItem) {
        edit { plan in
            if plan.asset(withID: item.id) == nil {
                plan.assets.append(item)
            }
            if let duration = item.duration {
                plan.clips.append(PlanClip(assetID: item.id, range: 0...duration))
            }
        }
    }

    /// trim 后上轨：同上，但片段区间取 trim 结果。
    func appendAssetToTimeline(_ item: AssetItem, range: ClosedRange<TimeInterval>) {
        edit { plan in
            if plan.asset(withID: item.id) == nil {
                plan.assets.append(item)
            }
            plan.clips.append(PlanClip(assetID: item.id, range: range))
        }
    }

    /// 重命名当前项目（导航栏点击项目名）。
    func renameProject(to name: String) {
        try? projectStore.renameProject(id: projectID, to: name)
    }

    /// 离开剪辑页时刷新封面缓存（第一片段首帧）。
    func updateCover() {
        let plan = store.plan
        let coverURL = projectStore.projectDirectory(id: projectID)
            .appendingPathComponent(ProjectStore.coverFileName)
        let resolver = resolver
        Task { await CoverGenerator.generate(for: plan, resolver: resolver, to: coverURL) }
    }

    /// 导出成片：先渲染到临时文件，完成后写入系统相册。
    /// 配置来自导出面板（ExportPanel）：HDR 直通 / SDR 降级等选项见 ExportOptions。
    func export(options: ExportOptions = .default) {
        exportProgress = 0
        exportMessage = nil
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("jangy-export-\(Int(Date().timeIntervalSince1970)).mp4")
        Task {
            do {
                for try await event in ExportRunner.export(plan: store.plan, resolver: resolver, to: out, options: options) {
                    switch event {
                    case .progress(let fraction):
                        exportProgress = fraction
                    case .done(let url, let ms):
                        do {
                            try await Self.saveToPhotoLibrary(url)
                            exportProgress = nil
                            exportMessage = "已导出到相册（\(ms)ms，\(options.hdrPassthrough ? "HDR" : "SDR")）"
                        } catch {
                            exportProgress = nil
                            exportMessage = "已渲染但保存相册失败: \(error.localizedDescription)\n文件: \(url.path)"
                        }
                    }
                }
            } catch {
                exportProgress = nil
                exportMessage = "导出失败: \(error.localizedDescription)"
            }
        }
    }

    /// 相册写入封装：申请 add-only 授权后把渲染产物注册为视频资源。
    private static func saveToPhotoLibrary(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "Jangy", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "没有相册写入权限（请在系统设置中允许访问相册）"
            ])
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        }
        try? FileManager.default.removeItem(at: url)
    }
}
```

要点（相对旧版的删除与变更）：
- 删除 `resetDraft`、`importPipeline`、`importVideos`、`importVideosFromFiles`、`draftMessage`（改名 `projectMessage`）、`importer`——导入管线迁往 LibraryModel（Task 10）
- Agent 凭据路径从 `resolver.directory` 改为 `projectStore.root`（agent-config.json 留在支持目录根，Assets/ 子目录只放素材）
- `verifyDraftIntegrity` → `verifyIntegrity`（ProjectStore.verify）

- [ ] **Step 2: 构建确认编译错误只来自未改造的文件**

Run: `xcodebuild -project Jangy.xcodeproj -scheme Jangy -destination 'generic/platform=iOS Simulator' build -skipMacroValidation`
Expected: FAIL — ContentView/JangyApp 引用已删除的符号。本步骤只为确认 AppModel 自身无误；错误应全部来自 ContentView.swift / JangyApp.swift。AppModel 随 Task 10 的 commit 入库，完整构建验证在 Task 14。

---

### Task 10: LibraryModel（导入管线迁移 + 三类素材）+ 选择器扩展

**Files:**
- Create: `Jangy/LibraryModel.swift`
- Modify: `Jangy/PhotoLibraryPicker.swift`（filter 放开图片）
- Modify: `Jangy/FilesPicker.swift`（contentTypes 参数化）

- [ ] **Step 1: 实现 LibraryModel**

创建 `Jangy/LibraryModel.swift`：

```swift
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

    init(library: AssetLibrary, resolver: AssetResolver, projectStore: ProjectStore) {
        self.library = library
        self.resolver = resolver
        self.projectStore = projectStore
    }

    /// 重载登记表 + 一致性校验。
    func reload() {
        items = ((try? library.load()) ?? []).sorted {
            ($0.importedAt ?? .distantPast) > ($1.importedAt ?? .distantPast)
        }
        Task { @MainActor in
            if let report = try? library.verify(), !report.isEmpty {
                libraryMessage = "素材库一致性：\(report.summary)"
            } else {
                libraryMessage = nil
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
    }

    /// 预览页 trim 后上轨。
    func addToTimeline(_ item: AssetItem, range: ClosedRange<TimeInterval>) {
        guard let editor = attachedEditor else { return }
        editor.appendAssetToTimeline(item, range: range)
        toastMessage = "已添加到时间线"
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
```

- [ ] **Step 2: 扩展选择器**

`PhotoLibraryPicker.swift`：filter 一行改为：

```swift
        configuration.filter = .any(of: [.videos, .images])
```

`FilesPicker.swift`：contentTypes 参数化——struct 加属性与 init，makeUIViewController 用它：

```swift
struct FilesPicker: UIViewControllerRepresentable {
    /// 完成回调：选中文件的临时 URL 列表；取消/未选则为空数组
    let onFinish: ([URL]) -> Void
    /// 可选类型（素材库导入传 [.movie, .image, .audio]；工程包导入传 [.zip]）
    var contentTypes: [UTType] = [.movie]

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }
    // Coordinator 部分不变
}
```

- [ ] **Step 3: Commit**

```bash
git add Jangy/AppModel.swift Jangy/LibraryModel.swift Jangy/PhotoLibraryPicker.swift Jangy/FilesPicker.swift
git commit -m "App: AppModel 按项目生命周期改造（删除 resetDraft/导入管线）+ LibraryModel 承接三类素材导入与删除保护 + 选择器类型放开

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

（说明：AppModel 与 LibraryModel 一起提交，因为旧 ContentView 在 Task 14 才替换——中间态编译不过属预期，最终 Task 14 后构建验证。若团队习惯每个 commit 可编译，可将本任务与 Task 14 的 commit 合并。）

---

### Task 11: 项目列表页（ProjectListView + ProjectListModel + ShareSheet）

**Files:**
- Create: `Jangy/ProjectListModel.swift`
- Create: `Jangy/ProjectListView.swift`
- Create: `Jangy/ShareSheet.swift`

- [ ] **Step 1: 实现 ProjectListModel**

创建 `Jangy/ProjectListModel.swift`：

```swift
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
        for id in ids { try? projectStore.deleteProject(id: id) }
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
    func exportPackages(ids: Set<UUID>) {
        var urls: [URL] = []
        var failures: [String] = []
        for id in ids {
            guard let summary = projects.first(where: { $0.id == id }) else { continue }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(summary.name).\(ProjectPackage.fileExtension)")
            do {
                try ProjectPackage.export(projectID: id, from: projectStore,
                                          library: library, resolver: resolver, to: dest)
                urls.append(dest)
            } catch {
                failures.append("\(summary.name): \(error.localizedDescription)")
            }
        }
        if !urls.isEmpty { packagesToShare = urls }
        if !failures.isEmpty { message = failures.joined(separator: "\n") }
        exitSelection()
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
```

- [ ] **Step 2: 实现 ShareSheet**

创建 `Jangy/ShareSheet.swift`：

```swift
import SwiftUI
import UIKit

/// 系统分享面板（UIActivityViewController）的薄封装：工程包导出分享用。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
```

- [ ] **Step 3: 实现 ProjectListView**

创建 `Jangy/ProjectListView.swift`：

```swift
import SwiftUI
import JangyCore

/// 首页：项目列表（单列大卡）。点卡片进剪辑页；多选模式批量删除/复制/导出工程包。
struct ProjectListView: View {
    @State var model: ProjectListModel
    @State var libraryModel: LibraryModel

    @State private var openedProject: ProjectSummary?
    @State private var showLibrary = false
    @State private var showPackagePicker = false
    @State private var renameTarget: ProjectSummary?
    @State private var renameText = ""
    @State private var infoTarget: ProjectSummary?
    @State private var pendingDelete: Set<UUID>?
    @State private var showShareSheet = false

    var body: some View {
        Group {
            if model.projects.isEmpty {
                emptyState
            } else {
                projectList
            }
        }
        .navigationTitle("项目")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.isSelecting {
                    Button("完成") { model.exitSelection() }
                } else {
                    HStack(spacing: 16) {
                        Button("素材库") { showLibrary = true }
                        Menu {
                            Button("导入工程包") { showPackagePicker = true }
                        } label: { Image(systemName: "ellipsis.circle") }
                        Button("多选") { model.isSelecting = true }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isSelecting {
                selectionBar
            } else {
                Button { if let p = model.createProject() { openedProject = p } } label: {
                    Label("新建项目", systemImage: "plus")
                        .padding(.horizontal, 24).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            // 首页可见 = 不在任何项目内：清空剪辑页语境，防止素材库出现 stale 的 ＋
            libraryModel.attachedEditor = nil
            model.reload()
        }
        .navigationDestination(item: $openedProject) { summary in
            EditorView(model: makeEditorModel(for: summary),
                       libraryModel: libraryModel, projectName: summary.name)
        }
        .navigationDestination(isPresented: $showLibrary) {
            LibraryView(model: libraryModel)
        }
        .sheet(isPresented: $showShareSheet, onDismiss: { model.packagesToShare = nil }) {
            if let urls = model.packagesToShare { ShareSheet(items: urls) }
        }
        .onChange(of: model.packagesToShare != nil) { _, has in showShareSheet = has }
        .sheet(isPresented: $showPackagePicker) {
            FilesPicker(contentTypes: [.zip]) { urls in
                showPackagePicker = false
                if let url = urls.first { model.importPackage(from: url) }
            }
            .ignoresSafeArea()
        }
        .sheet(item: $infoTarget) { summary in
            ProjectInfoSheet(summary: summary, storageSize: model.referencedStorageSize(of: summary.id))
                .presentationDetents([.medium])
        }
        .alert("重命名项目", isPresented: renameBinding) {
            TextField("项目名", text: $renameText)
            Button("确定") { if let t = renameTarget { model.rename(id: t.id, to: renameText) } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除后不可恢复（素材库不受影响）", isPresented: deleteBinding, titleVisibility: .visible) {
            Button("删除 \(pendingDelete?.count ?? 0) 个项目", role: .destructive) {
                if let ids = pendingDelete { model.delete(ids: ids) }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("提示", isPresented: messageBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("还没有项目").foregroundStyle(.secondary)
            Button { if let p = model.createProject() { openedProject = p } } label: {
                Label("新建你的第一个项目", systemImage: "plus")
                    .padding(.horizontal, 24).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    private var projectList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(model.projects) { summary in
                    ProjectCard(summary: summary, isSelecting: model.isSelecting,
                                isSelected: model.selection.contains(summary.id))
                        .onTapGesture {
                            if model.isSelecting {
                                model.toggleSelection(of: summary.id)
                            } else {
                                openedProject = summary
                            }
                        }
                        .contextMenu {
                            if !model.isSelecting {
                                Button("重命名") { renameTarget = summary; renameText = summary.name }
                                Button("复制") { model.duplicate(ids: [summary.id]) }
                                Button("查看信息") { infoTarget = summary }
                                Button("导出工程包") { model.exportPackages(ids: [summary.id]) }
                                Button("删除", role: .destructive) { pendingDelete = [summary.id] }
                            }
                        }
                }
            }
            .padding()
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 32) {
            Button("删除") { pendingDelete = model.selection }
                .foregroundStyle(.red).disabled(model.selection.isEmpty)
            Button("复制") { model.duplicate(ids: model.selection) }
                .disabled(model.selection.isEmpty)
            Button("导出工程包") { model.exportPackages(ids: model.selection) }
                .disabled(model.selection.isEmpty)
        }
        .padding(.vertical, 10)
    }

    private func makeEditorModel(for summary: ProjectSummary) -> AppModel {
        do {
            let plan = try model.projectStore.loadProject(id: summary.id)
            return AppModel(projectID: summary.id, store: EditStore(initial: plan),
                            resolver: model.resolver, projectStore: model.projectStore)
        } catch {
            return AppModel(projectID: summary.id, store: EditStore(initial: EditPlan(clips: [])),
                            resolver: model.resolver, projectStore: model.projectStore,
                            restoreNotice: "工程恢复失败（\(error.localizedDescription)），已从空时间线起步")
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var messageBinding: Binding<Bool> {
        Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
    }
}

/// 项目大卡：封面帧 + 名称 + 时长 + 修改时间。
private struct ProjectCard: View {
    let summary: ProjectSummary
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let image = UIImage(contentsOfFile: summary.coverURL.path) {
                        Image(uiImage: image).resizable().aspectRatio(16.0/9, contentMode: .fill)
                    } else {
                        Rectangle().fill(Color(.secondarySystemFill))
                            .aspectRatio(16.0/9, contentMode: .fill)
                            .overlay { Image(systemName: "film").foregroundStyle(.secondary) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? Color.accentColor : .white)
                        .padding(8)
                }
            }
            Text(summary.name).font(.headline)
            Text("\(summary.duration, format: .number.precision(.fractionLength(1)))s · \(summary.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 项目信息半屏 sheet。
private struct ProjectInfoSheet: View {
    let summary: ProjectSummary
    let storageSize: Int64

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("名称", value: summary.name)
                LabeledContent("时长", value: "\(summary.duration, format: .number.precision(.fractionLength(1)))s")
                LabeledContent("片段数", value: "\(summary.clipCount)")
                LabeledContent("引用素材", value: "\(summary.referencedAssetCount) 个")
                LabeledContent("创建时间", value: summary.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("修改时间", value: summary.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("引用素材体积", value: ByteCountFormatter.string(fromByteCount: storageSize, countStyle: .file))
            }
            .navigationTitle("项目信息")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
```

（`EditorView`、`LibraryView` 在 Task 12–14 创建，此步骤先存在引用错误属预期。）

- [ ] **Step 4: Commit（与 Task 14 合并验证构建；本步只暂存文件）**

```bash
git add Jangy/ProjectListModel.swift Jangy/ProjectListView.swift Jangy/ShareSheet.swift
git commit -m "App: 项目列表页——单列大卡 + 多选（删除/复制/导出工程包）+ 导入工程包 + 信息 sheet

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 12: 素材库页（LibraryView + ThumbnailLoader）

**Files:**
- Create: `Jangy/LibraryView.swift`
- Create: `Jangy/ThumbnailLoader.swift`
- Modify: `Jangy/LibraryModel.swift`（加 `unreferencedIDs`）

- [ ] **Step 1: LibraryModel 加「只删未引用」支持**

在 `LibraryModel.swift` 的 `delete(ids:)` 之后追加：

```swift
    /// 集合中未被任何项目引用的子集（删除受阻时「只删未引用的」用）。扫描失败返回空集（保守）。
    func unreferencedIDs(in ids: Set<UUID>) -> Set<UUID> {
        let editor = attachedEditor
        guard let refs = try? ReferenceScanner(projectStore: projectStore)
            .scan(currentProjectID: editor?.projectID, currentPlan: editor?.store.plan) else { return [] }
        return ids.filter { refs[$0]?.isEmpty != false }
    }
```

- [ ] **Step 2: 实现 ThumbnailLoader**

创建 `Jangy/ThumbnailLoader.swift`：

```swift
import AVFoundation
import ImageIO
import UIKit
import JangyCore

/// 素材缩略图：视频抽首帧、图片降采样；NSCache 按 assetID 缓存。
enum ThumbnailLoader {
    private static let cache = NSCache<NSUUID, UIImage>()

    static func load(item: AssetItem, resolver: AssetResolver) async -> UIImage? {
        if let cached = cache.object(forKey: item.id as NSUUID) { return cached }
        let url = resolver.resolve(item)
        let image: UIImage?
        switch item.kind {
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            image = (try? await generator.image(at: .zero).image).map { UIImage(cgImage: $0) }
        case .image:
            image = downsample(url: url, maxPixel: 240)
        default:
            image = nil
        }
        if let image { cache.setObject(image, forKey: item.id as NSUUID) }
        return image
    }

    /// ImageIO 降采样：不加载全尺寸像素进内存。
    private static func downsample(url: URL, maxPixel: Int) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
```

- [ ] **Step 3: 实现 LibraryView**

创建 `Jangy/LibraryView.swift`：

```swift
import SwiftUI
import JangyCore

/// 素材库：类型 tab + 三列网格。首页进入 = 纯管理；剪辑页进入（attachedEditor 非 nil）
/// = 视频格带 ＋ 快捷上轨。多选模式只有删除（引用保护）。
struct LibraryView: View {
    @State var model: LibraryModel

    @State private var tab: AssetKind = .video
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var showPhotoPicker = false
    @State private var showFilesPicker = false
    @State private var previewItem: AssetItem?
    @State private var showDeleteConfirm = false
    @State private var blockedNames: [String]?
    @State private var scanFailure: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    private var filtered: [AssetItem] {
        model.items.filter { $0.kind == tab }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("类型", selection: $tab) {
                Text("视频").tag(AssetKind.video)
                Text("图片").tag(AssetKind.image)
                Text("音频").tag(AssetKind.audio)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.vertical, 8)

            if filtered.isEmpty {
                emptyState
            } else {
                grid
            }

            if let progress = model.importProgress {
                ProgressView(value: progress) { Text("导入素材…").font(.caption) }.padding(.horizontal)
            }
            if let message = model.importMessage ?? model.libraryMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
        }
        .navigationTitle("素材库")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSelecting {
                    Button("完成") { exitSelection() }
                } else {
                    HStack(spacing: 16) {
                        Menu("导入") {
                            Button("从相册导入") { showPhotoPicker = true }
                            Button("从文件导入") { showFilesPicker = true }
                        }
                        Button("多选") { isSelecting = true }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                Button("删除 \(selection.count) 个素材") { showDeleteConfirm = true }
                    .foregroundStyle(.red)
                    .disabled(selection.isEmpty)
                    .padding(.vertical, 10)
            }
        }
        .onAppear { model.reload() }
        .navigationDestination(item: $previewItem) { item in
            AssetPreviewView(item: item, resolver: model.resolver, model: model)
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPicker { identifiers in
                showPhotoPicker = false
                model.importFromPhotos(identifiers: identifiers)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showFilesPicker) {
            FilesPicker(contentTypes: [.movie, .image, .audio]) { urls in
                showFilesPicker = false
                model.importFromFiles(urls: urls)
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("从素材库删除（不影响项目内已有片段的播放，被引用的素材会被拦截）",
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) { performDelete() }
            Button("取消", role: .cancel) {}
        }
        .alert("无法删除被引用的素材", isPresented: blockedBinding) {
            Button("只删除未引用的") { deleteUnreferencedOnly() }
            Button("好", role: .cancel) {}
        } message: {
            Text("以下项目正在使用所选素材：\((blockedNames ?? []).joined(separator: "、"))")
        }
        .alert("删除失败", isPresented: scanFailureBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(scanFailure ?? "")
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toastMessage {
                Text(toast)
                    .font(.caption).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 60)
                    .task { try? await Task.sleep(for: .seconds(1.5)); model.toastMessage = nil }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("还没有素材").foregroundStyle(.secondary)
            Menu("＋ 导入素材") {
                Button("从相册导入") { showPhotoPicker = true }
                Button("从文件导入") { showFilesPicker = true }
            }
            .font(.body)
            Spacer()
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(filtered) { item in
                    AssetCell(item: item, resolver: model.resolver,
                              isSelecting: isSelecting, isSelected: selection.contains(item.id),
                              isNew: model.recentlyImported.contains(item.id),
                              showQuickAdd: model.attachedEditor != nil && tab == .video && item.duration != nil,
                              onQuickAdd: { model.quickAdd(item) })
                        .onTapGesture {
                            if isSelecting {
                                if selection.contains(item.id) { selection.remove(item.id) }
                                else { selection.insert(item.id) }
                            } else {
                                previewItem = item
                            }
                        }
                }
            }
            .padding(4)
        }
    }

    private func performDelete() {
        switch model.delete(ids: selection) {
        case .deleted:
            exitSelection()
        case .blocked(let names):
            blockedNames = names
        case .scanFailed(let reason):
            scanFailure = reason
        }
    }

    private func deleteUnreferencedOnly() {
        let removable = model.unreferencedIDs(in: selection)
        guard !removable.isEmpty else { return }
        _ = model.delete(ids: removable)
        exitSelection()
    }

    private func exitSelection() {
        isSelecting = false
        selection.removeAll()
    }

    private var blockedBinding: Binding<Bool> {
        Binding(get: { blockedNames != nil }, set: { if !$0 { blockedNames = nil } })
    }

    private var scanFailureBinding: Binding<Bool> {
        Binding(get: { scanFailure != nil }, set: { if !$0 { scanFailure = nil } })
    }
}

/// 素材格：缩略图（音频为图标）+ 时长角标 + 剪辑页语境的 ＋ 快捷上轨。
/// isNew = 本次导入的新素材，accent 色描边高亮。
private struct AssetCell: View {
    let item: AssetItem
    let resolver: AssetResolver
    let isSelecting: Bool
    let isSelected: Bool
    let isNew: Bool
    let showQuickAdd: Bool
    let onQuickAdd: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Rectangle().fill(Color(.secondarySystemFill))
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else if item.kind == .audio {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(.secondary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()

            if let duration = item.duration {
                Text("\(duration, format: .number.precision(.fractionLength(0)))s")
                    .font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(4)
            }
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(6)
            }
            if showQuickAdd && !isSelecting {
                Button(action: onQuickAdd) {
                    Image(systemName: "plus")
                        .font(.caption.bold())
                        .frame(width: 26, height: 26)
                        .background(Color.accentColor, in: Circle())
                        .foregroundStyle(.white)
                }
                .padding(5)
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            if isNew {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .task { thumbnail = await ThumbnailLoader.load(item: item, resolver: resolver) }
        .accessibilityLabel(item.displayName)
    }
}
```

（`AssetPreviewView` 在 Task 13 创建。）

- [ ] **Step 4: Commit**

```bash
git add Jangy/LibraryView.swift Jangy/ThumbnailLoader.swift Jangy/LibraryModel.swift
git commit -m "App: 素材库页——类型 tab + 网格 + ＋快捷上轨（剪辑页语境）+ 多选删除（引用保护/只删未引用）

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 13: 素材预览页（AssetPreviewView + VideoTrimView + 信息面板）

**Files:**
- Create: `Jangy/AssetPreviewView.swift`
- Create: `Jangy/VideoTrimView.swift`

- [ ] **Step 1: 实现 VideoTrimView（iOS 相册风格 trim 条）**

创建 `Jangy/VideoTrimView.swift`：

```swift
import AVFoundation
import SwiftUI

/// 视频 trim 条：样式参照 iOS 相册视频裁剪——胶片条缩略图 + 黄色选中边框 + 首尾把手。
/// 拖把手调区间，最小选区 0.5s。
struct VideoTrimView: View {
    let url: URL
    let duration: TimeInterval
    @Binding var range: ClosedRange<TimeInterval>

    @State private var thumbnails: [UIImage] = []
    private let minLength = 0.5
    private let handleWidth: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                filmstrip(width: width)
                dimming(width: width)
                selectionFrame(width: width)
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .frame(height: 44)
        .task { await loadThumbnails() }
    }

    /// 胶片条：均匀抽帧铺满
    private func filmstrip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(thumbnails.indices, id: \.self) { index in
                Image(uiImage: thumbnails[index])
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: width / CGFloat(max(thumbnails.count, 1)), height: 44)
                    .clipped()
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(.secondarySystemFill)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// 选区外暗化
    private func dimming(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(.black.opacity(0.55)).frame(width: xOffset(of: range.lowerBound, width: width))
            Spacer()
            Rectangle().fill(.black.opacity(0.55)).frame(width: width - xOffset(of: range.upperBound, width: width))
        }
        .allowsHitTesting(false)
    }

    /// 黄色选中框 + 把手
    private func selectionFrame(width: CGFloat) -> some View {
        let left = xOffset(of: range.lowerBound, width: width)
        let right = xOffset(of: range.upperBound, width: width)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.yellow, lineWidth: 3)
                .frame(width: max(right - left, handleWidth * 2), height: 44)
                .offset(x: left)
                .allowsHitTesting(false)
            // 左把手
            handle
                .offset(x: left)
                .gesture(DragGesture().onChanged { value in
                    let seconds = clamp(seconds(at: value.location.x, width: width),
                                        min: 0, max: range.upperBound - minLength)
                    range = seconds...range.upperBound
                })
            // 右把手
            handle
                .offset(x: max(right - handleWidth, left + handleWidth))
                .gesture(DragGesture().onChanged { value in
                    let seconds = clamp(seconds(at: value.location.x + handleWidth, width: width),
                                        min: range.lowerBound + minLength, max: duration)
                    range = range.lowerBound...seconds
                })
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.yellow)
            .frame(width: handleWidth, height: 44)
            .overlay { Image(systemName: "chevron.compact.left").font(.caption2).foregroundStyle(.black.opacity(0.6)) }
            .contentShape(Rectangle())
    }

    private func xOffset(of seconds: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(seconds / duration) * width
    }

    private func seconds(at x: CGFloat, width: CGFloat) -> TimeInterval {
        TimeInterval(x / width) * duration
    }

    private func clamp(_ v: TimeInterval, min: TimeInterval, max: TimeInterval) -> TimeInterval {
        Swift.max(min, Swift.min(max, v))
    }

    /// 抽 8 帧铺胶片条
    private func loadThumbnails() async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 120, height: 88)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        var images: [UIImage] = []
        for i in 0..<8 {
            let time = CMTime(seconds: duration * Double(i) / 8.0, preferredTimescale: 600)
            if let cgImage = try? await generator.image(at: time).image {
                images.append(UIImage(cgImage: cgImage))
            }
        }
        thumbnails = images
    }
}
```

- [ ] **Step 2: 实现 AssetPreviewView**

创建 `Jangy/AssetPreviewView.swift`：

```swift
import AVKit
import SwiftUI
import JangyCore

/// 素材预览页：视频（播放 + trim + 添加）、图片（缩放预览）、音频（播放示意）。
/// 添加按钮仅剪辑页语境 + 视频类型显示；图片上轨属 Spec ②，音频维持后置。
/// 信息面板：元数据 + 引用项目列表。预览页不提供删除。
struct AssetPreviewView: View {
    let item: AssetItem
    let resolver: AssetResolver
    @State var model: LibraryModel

    @State private var player: AVPlayer?
    @State private var trimRange: ClosedRange<TimeInterval> = 0...0
    @State private var isPlaying = false
    @State private var zoomScale: CGFloat = 1
    @State private var showInfo = false
    @State private var referencingProjects: [String] = []

    private var fileURL: URL { resolver.resolve(item) }
    private var canAdd: Bool {
        model.attachedEditor != nil && item.kind == .video && item.duration != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            if item.kind == .video, let duration = item.duration {
                VStack(alignment: .leading, spacing: 4) {
                    VideoTrimView(url: fileURL, duration: duration, range: $trimRange)
                    Text("已选 \(trimRange.lowerBound, format: .number.precision(.fractionLength(1)))s ~ \(trimRange.upperBound, format: .number.precision(.fractionLength(1)))s / 共 \(duration, format: .number.precision(.fractionLength(1)))s")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }

            if canAdd {
                Button {
                    model.addToTimeline(item, range: trimRange)
                } label: {
                    Text("添加到时间线")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimRange.upperBound <= trimRange.lowerBound)  // 等 trimRange 初始化完成
                .padding()
            }
        }
        .navigationTitle(item.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("信息") {
                    referencingProjects = model.referencingProjects(of: item.id)
                    showInfo = true
                }
            }
        }
        .sheet(isPresented: $showInfo) { infoSheet }
        .onDisappear { player?.pause() }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .video:
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().tint(.white)
                    .task {
                        trimRange = 0...(item.duration ?? 0)
                        player = AVPlayer(url: fileURL)
                    }
            }
        case .image:
            if let image = UIImage(contentsOfFile: fileURL.path) {
                Image(uiImage: image)
                    .resizable().aspectRatio(contentMode: .fit)
                    .scaleEffect(zoomScale)
                    .gesture(MagnifyGesture().onChanged { zoomScale = $0.magnification }
                        .onEnded { _ in withAnimation { zoomScale = 1 } })
            } else {
                Text("无法读取图片").foregroundStyle(.secondary)
            }
        case .audio:
            VStack(spacing: 20) {
                // 波形示意（确定性伪随机，装饰用途；真实波形留待音频专项）
                HStack(spacing: 3) {
                    ForEach(0..<40, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5)
                            .frame(width: 3, height: 8 + 28 * pseudoRandom(i))
                    }
                }
                .foregroundStyle(Color.accentColor)
                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 48))
                }
                Text("音频上轨将在后续版本开放")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .subtitle:
            Text("字幕文件请在剪辑页使用").foregroundStyle(.secondary)
        }
    }

    /// 确定性伪随机（同一种子同一波形）
    private func pseudoRandom(_ i: Int) -> CGFloat {
        CGFloat((i * 2654435761 &* 40503) % 1000) / 1000.0
    }

    private func togglePlay() {
        if player == nil { player = AVPlayer(url: fileURL) }
        if isPlaying { player?.pause() } else { player?.play() }
        isPlaying.toggle()
    }

    private var infoSheet: some View {
        NavigationStack {
            List {
                LabeledContent("名称", value: item.displayName)
                LabeledContent("类型", value: kindLabel)
                if let duration = item.duration {
                    LabeledContent("时长", value: "\(duration, format: .number.precision(.fractionLength(1)))s")
                }
                if let w = item.pixelWidth, let h = item.pixelHeight {
                    LabeledContent("分辨率", value: "\(w) × \(h)")
                }
                if let size = fileSize {
                    LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                if let importedAt = item.importedAt {
                    LabeledContent("导入时间", value: importedAt.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("被引用", value: referencingProjects.isEmpty ? "无" : referencingProjects.joined(separator: "、"))
            }
            .navigationTitle("素材信息")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private var kindLabel: String {
        switch item.kind {
        case .video: return "视频"
        case .image: return "图片"
        case .audio: return "音频"
        case .subtitle: return "字幕"
        }
    }

    private var fileSize: Int64? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int64
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Jangy/AssetPreviewView.swift Jangy/VideoTrimView.swift
git commit -m "App: 素材预览页——视频播放+trim（iOS 相册样式）上轨、图片缩放预览、音频播放示意；信息面板含引用项目列表

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 14: 剪辑页改造 + 时间线横排浮动＋ + JangyApp 装配

**Files:**
- Create: `Jangy/EditorView.swift`
- Modify: `Jangy/TimelineView.swift`（整体改写）
- Modify: `Jangy/JangyApp.swift`（整体改写）
- Delete: `Jangy/ContentView.swift`

- [ ] **Step 1: 实现 EditorView**

创建 `Jangy/EditorView.swift`：

```swift
import SwiftUI
import JangyCore

/// 剪辑页：导航栈推送页。预览 + 操作条 + 时间线。
/// 素材入口统一走素材库页（操作条按钮 / 时间线浮动＋ / 空态大按钮）。
struct EditorView: View {
    @State var model: AppModel
    @State var libraryModel: LibraryModel
    @State private var projectName: String

    @State private var showExportPanel = false
    @State private var showAgent = false
    @State private var showLibrary = false
    @State private var showRename = false
    @State private var renameText = ""

    init(model: AppModel, libraryModel: LibraryModel, projectName: String) {
        self._model = State(initialValue: model)
        self._libraryModel = State(initialValue: libraryModel)
        self._projectName = State(initialValue: projectName)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                PreviewView(player: model.player)
                if model.store.plan.clips.isEmpty {
                    VStack(spacing: 12) {
                        Button { showLibrary = true } label: {
                            Label("添加素材", systemImage: "plus")
                                .padding(.horizontal, 20).padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        Text("从素材库挑选素材开始剪辑")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                }
            }

            // 操作条：撤销/重做 + 字幕开关 + 素材库 + Agent + 导出成片
            HStack {
                Button("撤销") { model.undo() }.disabled(!model.store.canUndo || model.agent.isRunning)
                Button("重做") { model.redo() }.disabled(!model.store.canRedo || model.agent.isRunning)
                Spacer()
                Button(model.store.plan.captions?.isEnabled == true ? "字幕：开" : "字幕：关") {
                    model.edit { $0.captions?.isEnabled.toggle() }
                }
                .disabled(model.store.plan.captions == nil || model.agent.isRunning)
                Button("素材库") { showLibrary = true }
                Button("Agent") { showAgent = true }
                    .disabled(!model.agent.isConfigured)
                Button("导出成片") { showExportPanel = true }
                    .disabled(model.exportProgress != nil || model.agent.isRunning || model.store.plan.clips.isEmpty)
            }
            .padding(.horizontal)

            if let progress = model.exportProgress {
                ProgressView(value: progress).padding(.horizontal)
            }
            if let message = model.projectMessage {
                Text(message).font(.caption).foregroundStyle(.orange).padding(.horizontal)
            }
            if let message = model.exportMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            if let issues = model.lastIssues {
                Text(issues.map(\.description).joined(separator: "\n"))
                    .font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            TimelineView(model: model, onAdd: { showLibrary = true })
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { renameText = projectName; showRename = true } label: {
                    Text(projectName).font(.headline).foregroundStyle(.primary)
                }
            }
        }
        .onAppear { libraryModel.attachedEditor = model }
        .onDisappear { model.updateCover() }
        .navigationDestination(isPresented: $showLibrary) {
            LibraryView(model: libraryModel)
        }
        .sheet(isPresented: $showExportPanel) {
            ExportPanel { options in
                showExportPanel = false
                model.export(options: options)
            }
        }
        .sheet(isPresented: $showAgent) {
            AgentChatView(controller: model.agent)
        }
        .alert("重命名项目", isPresented: $showRename) {
            TextField("项目名", text: $renameText)
            Button("确定") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    model.renameProject(to: name)
                    projectName = name
                }
            }
            Button("取消", role: .cancel) {}
        }
    }
}
```

注意：字幕开关加了 `captions == nil` 禁用（旧版 toggling nil 是 no-op，显式禁用更准确）。

- [ ] **Step 2: 改写 TimelineView 为横排固定宽度 + 浮动＋**

`Jangy/TimelineView.swift` 整体替换：

```swift
import SwiftUI
import JangyCore

/// 时间线（简化版）：水平排布、每段固定宽度。点片段弹操作（裁剪/变速/转场/删除）。
/// 「＋」浮动在可见区域右缘（不随轨道滚动），点击进素材库追加素材。
/// 精细化（缩放/拖拽排序/可变宽度）留给时间线专项。
struct TimelineView: View {
    let model: AppModel
    var onAdd: () -> Void

    @State private var actionIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 总时长用实测口径（dissolve 重叠扣除），与导出产物时长一致
            Text("总时长 \(model.store.plan.renderedDuration, format: .number.precision(.fractionLength(1)))s")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            ZStack(alignment: .trailing) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(model.store.plan.clips.enumerated()), id: \.element.id) { index, clip in
                            clipBlock(index: index, clip: clip)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.trailing, 56)  // 给浮动＋让位
                }

                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.body.bold())
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor, in: Circle())
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                }
                .padding(.trailing, 8)
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("片段 \((actionIndex ?? 0) + 1)", isPresented: actionBinding, titleVisibility: .visible) {
            Button("裁剪") { if let i = actionIndex { toggleTrim(i) } }
            Button("变速") { if let i = actionIndex { cycleSpeed(i) } }
            if let i = actionIndex, i < model.store.plan.clips.count - 1 {
                Button(model.store.plan.clips[i].transitionAfter == nil ? "加转场" : "去转场") { toggleTransition(i) }
            }
            Button("删除", role: .destructive) { if let i = actionIndex { delete(i) } }
            Button("取消", role: .cancel) {}
        }
    }

    private func clipBlock(index: Int, clip: PlanClip) -> some View {
        Button { actionIndex = index } label: {
            VStack(spacing: 2) {
                Text(displayName(for: clip))
                    .font(.caption2)
                    .lineLimit(1)
                Text("\(clip.outputDuration, format: .number.precision(.fractionLength(1)))s · \(clip.speed.rate, format: .number.precision(.fractionLength(2)))x")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if clip.transitionAfter != nil {
                    Text("⇄ 转场").font(.caption2).foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 72, height: 56)
            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        // Agent 运行中禁用：分组期间手动编辑会并入 Agent 撤销组
        .disabled(model.agent.isRunning)
    }

    private var actionBinding: Binding<Bool> {
        Binding(get: { actionIndex != nil }, set: { if !$0 { actionIndex = nil } })
    }

    /// 片段标题：素材登记表里的 displayName；登记项缺失时兜底显示 ID 前 8 位
    private func displayName(for clip: PlanClip) -> String {
        model.store.plan.asset(withID: clip.assetID)?.displayName
            ?? String(clip.assetID.uuidString.prefix(8))
    }

    private func toggleTrim(_ index: Int) {
        model.edit {
            let clip = $0.clips[index]
            $0.clips[index].range = clip.range.lowerBound == 0 ? 0.5...2.5 : 0...3
        }
    }

    private func cycleSpeed(_ index: Int) {
        model.edit {
            let current = $0.clips[index].speed.rate
            let next: Double = current == 1.0 ? 0.5 : (current == 0.5 ? 2.0 : 1.0)
            $0.clips[index].speed = .flat(next)
        }
    }

    private func toggleTransition(_ index: Int) {
        model.edit {
            $0.clips[index].transitionAfter = $0.clips[index].transitionAfter == nil ? .dissolve(duration: 0.5) : nil
        }
    }

    private func delete(_ index: Int) {
        model.edit {
            $0.clips.remove(at: index)
            // 删除后若新的末位片段挂着转场，一并清掉（否则校验失败）
            if let last = $0.clips.indices.last, $0.clips[last].transitionAfter != nil {
                $0.clips[last].transitionAfter = nil
            }
        }
    }
}
```

- [ ] **Step 3: 改写 JangyApp + 删除 ContentView**

`Jangy/JangyApp.swift` 整体替换：

```swift
import SwiftUI
import JangyCore

@main
@MainActor
struct JangyApp: App {
    @State private var projectListModel: ProjectListModel
    @State private var libraryModel: LibraryModel

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jangy", isDirectory: true)
        // 启动只做廉价装配：目录预建 + 旧布局迁移（幂等）
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let projectStore = ProjectStore(root: support)
        try? projectStore.migrateLegacyLayoutIfNeeded()
        let library = AssetLibrary(root: support)
        let resolver = library.resolver
        _projectListModel = State(initialValue: ProjectListModel(
            projectStore: projectStore, library: library, resolver: resolver))
        _libraryModel = State(initialValue: LibraryModel(
            library: library, resolver: resolver, projectStore: projectStore))
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ProjectListView(model: projectListModel, libraryModel: libraryModel)
            }
        }
    }
}
```

删除旧文件：

```bash
rm Jangy/ContentView.swift
```

- [ ] **Step 4: 构建验证**

Run: `xcodebuild -project Jangy.xcodeproj -scheme Jangy -destination 'generic/platform=iOS Simulator' build -skipMacroValidation`
Expected: BUILD SUCCEEDED。若有编译错误，多为签名/命名笔误，逐个修复再跑。

- [ ] **Step 5: Commit**

```bash
git add Jangy/EditorView.swift Jangy/TimelineView.swift Jangy/JangyApp.swift
git rm Jangy/ContentView.swift 2>/dev/null || true
git commit -m "App: 剪辑页改造（素材库入口替代导入/导出成片文案/点标题重命名）+ 时间线横排固定宽度+浮动＋ + JangyApp 装配多项目导航栈（ContentView 删除）

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 15: 全量验证 + 文档收口

**Files:**
- Modify: `AGENTS.md`（播种命令）
- Modify: `docs/roadmap-path-a.md`（勾选素材库管理 UI）

- [ ] **Step 1: 全量测试**

Run: `cd Packages/JangyCore && swift test`
Expected: 全绿（核心层新增约 30 个测试；DraftStoreTests 已被 ProjectStoreTests 覆盖）

- [ ] **Step 2: App 构建**

Run: `xcodebuild -project Jangy.xcodeproj -scheme Jangy -destination 'generic/platform=iOS Simulator' build -skipMacroValidation`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: 更新 AGENTS.md 播种命令**

「模拟器手动验证要样例内容」一节改为（素材进 Assets/ 子目录，项目为目录结构，meta.json 缺失时列表有兜底名）：

```bash
# APP_DIR=$(模拟器上本 App 的 Application Support/Jangy 目录)
swift run jangy-cli genassets --to "$APP_DIR/Assets"
PRJ="$APP_DIR/Projects/$(uuidgen | tr 'A-F' 'a-f')"
mkdir -p "$PRJ" && swift run jangy-cli sample > "$PRJ/project.json"
```

Agent 凭据播种命令不变（agent-config.json 仍在 APP_DIR 根）。

- [ ] **Step 4: 勾选 roadmap**

`docs/roadmap-path-a.md` 的「素材库管理 UI」条目勾掉，附完成日期与验收结果（素材库网格展示 + 删除未引用素材后 plan 完整性校验通过 + 多项目化/工程包往返为超原条目的扩展范围）。

- [ ] **Step 5: 真机/模拟器手动验证清单**

- [ ] 启动 → 项目列表（旧 draft.json 自动迁移为「未命名项目」，素材进素材库）
- [ ] 新建项目 → 空时间线 + 预览区「添加素材」大按钮 → 进素材库
- [ ] 素材库导入：相册（视频+图片混选）、文件（mp4/jpg/mp3 各一）→ 入库高亮，不上轨
- [ ] 剪辑页进素材库 → 视频格 ＋ 上轨 → toast，停留素材库页 → 返回剪辑页片段已在
- [ ] 点视频素材 → 预览页播放 + trim → 添加到时间线（trim 区间生效）
- [ ] 多选删除：选中被引用素材 → 拦截弹窗列项目名 → 「只删除未引用的」
- [ ] 项目列表：复制/重命名/查看信息/删除/导出工程包（分享面板存到文件 App）
- [ ] 导入工程包：把导出的 zip 导回 → 新项目出现、素材不重复入库
- [ ] 导出成片不受影响（ExportPanel 流程回归）

- [ ] **Step 6: Commit**

```bash
git add AGENTS.md docs/roadmap-path-a.md
git commit -m "docs: 播种命令对齐多项目布局（Assets/ + Projects/）；roadmap 勾选素材库管理 UI

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## 风险与备注

- **中间态编译断裂**：Task 9/11/12/13 的 commit 之间 App target 编译不过（旧 ContentView 引用已删符号、新 View 引用未建类型），Task 14 才恢复可编译。按任务顺序执行即可；如需每个 commit 可编译，把 Task 9–14 合并为一个大 commit。
- **ZIP 自研的边界**：只支持 store 条目。第三方工具重新打包的工程包（带 deflate）会报「不支持的压缩条目」——v1 可接受，manifest 版本守卫挡住未来演进。
- **音频波形是装饰**：真实波形需要读 PCM 采样，留待音频专项（与音轨一起做）。
- **测试素材**：Core 测试全部用 `AssetSynthesizer` 合成（已在 JangyTestSupport），无二进制资产进 git。


