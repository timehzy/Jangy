import AVFoundation
import Foundation
import Observation
import Photos
import POCCore

/// App 侧状态装配：EditStore（编辑状态层）+ PlayerController（预览）+ 导入/导出进度。
/// 所有编辑经 edit() 进入 EditStore.apply —— 校验失败不压栈，撤销栈纹丝不动。
@MainActor
@Observable
final class AppModel {
    let store: EditStore
    let resolver: AssetResolver
    let player: PlayerController
    private let importer: AssetImporter
    private let draftStore: DraftStore
    private var autosaveTask: Task<Void, Never>?

    var exportProgress: Double?
    var exportMessage: String?
    var importProgress: Double?
    var importMessage: String?
    var lastIssues: [ValidationIssue]?
    /// 草稿相关提示：恢复失败原因 / 完整性报告 / 保存失败
    var draftMessage: String?

    init(store: EditStore, resolver: AssetResolver, draftStore: DraftStore, restoreNotice: String? = nil) {
        self.store = store
        self.resolver = resolver
        self.player = PlayerController(store: store, resolver: resolver)
        self.importer = AssetImporter(directory: resolver.directory)
        self.draftStore = draftStore
        self.draftMessage = restoreNotice
        verifyDraftIntegrity()
    }

    /// 启动后异步核对登记表与磁盘素材：缺失/漂移显式报告，不静默丢。
    private func verifyDraftIntegrity() {
        Task { @MainActor in
            let report = await draftStore.verify(plan: store.plan, resolver: resolver)
            guard !report.isEmpty else { return }
            draftMessage = "草稿完整性：\(report.summary)"
        }
    }

    /// 编辑成功后的防抖自动保存：连续编辑合并为一次写盘；保存失败不阻塞编辑。
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let plan = store.plan
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                try draftStore.save(plan: plan)
            } catch {
                draftMessage = "草稿保存失败: \(error.localizedDescription)"
            }
        }
    }

    func edit(_ mutate: (inout EditPlan) -> Void) {
        switch store.apply(mutate) {
        case .success:
            lastIssues = nil
            player.rebuild()
            scheduleAutosave()
        case .failure(let failure):
            lastIssues = failure.issues
        }
    }

    func undo() { lastIssues = nil; store.undo(); player.rebuild(); scheduleAutosave() }
    func redo() { lastIssues = nil; store.redo(); player.rebuild(); scheduleAutosave() }

    /// 新建草稿：经 EditStore.apply 整体替换为样例工程（单撤销步，可撤销），
    /// autosave 随即覆盖旧 draft.json。素材文件保留在素材库，登记表清空即不再引用。
    func resetDraft() {
        edit { $0 = SamplePlan.make() }
        draftMessage = nil
    }

    /// 从相册导入视频：授权 → 逐个解析（iCloud 自动下载）→ move 进素材库 →
    /// 一次 apply 登记素材 + 追加片段（单撤销步）。失败的单个素材不阻断其余导入。
    func importVideos(assetIdentifiers: [String]) {
        guard !assetIdentifiers.isEmpty else { return }
        importProgress = 0
        importMessage = nil
        let total = Double(assetIdentifiers.count)
        Task { @MainActor in
            guard await PhotosBridge.requestReadAccess() else {
                importProgress = nil
                importMessage = "没有相册读取权限（请在系统设置中允许访问相册）"
                return
            }
            var items: [AssetItem] = []
            var failures = 0
            for (index, identifier) in assetIdentifiers.enumerated() {
                do {
                    let tempFile = try await PhotosBridge.resolveVideoFile(assetIdentifier: identifier) { fraction in
                        Task { @MainActor in
                            self.importProgress = (Double(index) + fraction) / total
                        }
                    }
                    let item = try await importer.importVideo(from: tempFile, origin: .photoLibrary)
                    items.append(item)
                } catch {
                    failures += 1
                }
                importProgress = Double(index + 1) / total
            }
            if !items.isEmpty {
                edit {
                    $0.assets.append(contentsOf: items)
                    for item in items {
                        // duration 探测失败时不追加片段（避免 range 无依据），素材仍入库
                        if let duration = item.duration {
                            $0.clips.append(PlanClip(assetID: item.id, range: 0...duration))
                        }
                    }
                }
            }
            importProgress = nil
            if failures > 0 {
                importMessage = "\(failures) 个素材导入失败（iCloud 下载或格式不支持）"
            }
        }
    }

    /// 导出：先渲染到临时文件，完成后写入系统相册，方便真机直接验证成片。
    func export() {
        exportProgress = 0
        exportMessage = nil
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("poc-export-\(Int(Date().timeIntervalSince1970)).mp4")
        Task {
            do {
                for try await event in ExportRunner.export(plan: store.plan, resolver: resolver, to: out) {
                    switch event {
                    case .progress(let fraction):
                        exportProgress = fraction
                    case .done(let url, let ms):
                        do {
                            try await Self.saveToPhotoLibrary(url)
                            exportProgress = nil
                            exportMessage = "已导出到相册（\(ms)ms）"
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
            throw NSError(domain: "JangyPOC", code: 1, userInfo: [
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

/// 预览播放器：plan 变化 → PreviewBridge 重建 playerItem；周期性时间观察驱动字幕叠加层。
@MainActor
@Observable
final class PlayerController {
    private(set) var player: AVPlayer?
    private(set) var currentTime: TimeInterval = 0
    private(set) var cues: [CaptionCue] = []

    private var timePollingTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private let store: EditStore
    private let resolver: AssetResolver

    init(store: EditStore, resolver: AssetResolver) {
        self.store = store
        self.resolver = resolver
        rebuild()
    }

    func rebuild() {
        rebuildTask?.cancel()
        // 换 player 前同步停掉旧的：旧实例的回收依赖 dealloc（时机不受控），
        // 不主动 pause 就会出现「界面无播放器却有声音」的孤儿播放。
        let wasPlaying = player.map { $0.rate > 0 } ?? true  // 首次装载视为自动播放
        player?.pause()
        timePollingTask?.cancel()
        rebuildTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            guard let package = try? await PreviewBridge.makePreview(for: store.plan, resolver: resolver) else { return }
            // 重建竞态防护：await 期间可能已被下一次 rebuild 取消，此时不得安装过期 player。
            guard !Task.isCancelled else { return }
            let newPlayer = AVPlayer(playerItem: package.playerItem)
            // 轮询 Task 弱捕获 player：Task 若因任何原因未被取消（如控制器被整体丢弃），
            // 也不会把旧 player 钉在内存里继续出声。
            // @MainActor Task 闭包与 self 同属 MainActor 隔离域，捕获非 Sendable 值合法。
            timePollingTask = Task { @MainActor [weak self, weak newPlayer] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, let newPlayer, !Task.isCancelled else { return }
                    self.currentTime = newPlayer.currentTime().seconds
                }
            }
            player = newPlayer
            cues = package.cues
            // 保留播放状态：编辑前已暂停/播完，则新 player 不自动出声
            if wasPlaying { newPlayer.play() }
        }
    }

    var currentCue: CaptionCue? {
        cues.first { $0.range.contains(currentTime) }
    }
}
