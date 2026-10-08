import AVFoundation
import Foundation
import Observation
import Photos
import POCCore

/// App 侧状态装配：EditStore（编辑状态层）+ PlayerController（预览）+ 导出进度。
/// 所有编辑经 edit() 进入 EditStore.apply —— 校验失败不压栈，撤销栈纹丝不动。
@MainActor
@Observable
final class AppModel {
    let store: EditStore
    let resolver: AssetResolver
    let player: PlayerController

    var exportProgress: Double?
    var exportMessage: String?
    var lastIssues: [ValidationIssue]?

    init(store: EditStore, resolver: AssetResolver) {
        self.store = store
        self.resolver = resolver
        self.player = PlayerController(store: store, resolver: resolver)
    }

    func edit(_ mutate: (inout EditPlan) -> Void) {
        switch store.apply(mutate) {
        case .success:
            lastIssues = nil
            player.rebuild()
        case .failure(let failure):
            lastIssues = failure.issues
        }
    }

    func undo() { lastIssues = nil; store.undo(); player.rebuild() }
    func redo() { lastIssues = nil; store.redo(); player.rebuild() }

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
        rebuildTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            guard let package = try? await PreviewBridge.makePreview(for: store.plan, resolver: resolver) else { return }
            // 重建竞态防护：await 期间可能已被下一次 rebuild 取消，此时不得安装过期 player。
            guard !Task.isCancelled else { return }
            let newPlayer = AVPlayer(playerItem: package.playerItem)
            timePollingTask?.cancel()
            // PlayerController 经 @State 随 App 终身存活，轮询 Task 强引用 newPlayer 无泄漏之虞；
            // @MainActor Task 闭包与 self 同属 MainActor 隔离域，捕获非 Sendable 值合法。
            timePollingTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, !Task.isCancelled else { return }
                    self.currentTime = newPlayer.currentTime().seconds
                }
            }
            player = newPlayer
            cues = package.cues
            newPlayer.play()
        }
    }

    var currentCue: CaptionCue? {
        cues.first { $0.range.contains(currentTime) }
    }
}
