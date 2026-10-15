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

    /// 素材从素材库上轨：登记（若未登记）+ 追加片段，同一次 apply（公约 §3 单撤销步）。
    /// 视频全长上轨（duration 未探测则不追加）；图片以默认时长上轨。
    func appendAssetToTimeline(_ item: AssetItem) {
        edit { plan in
            if plan.asset(withID: item.id) == nil {
                plan.assets.append(item)
            }
            switch item.kind {
            case .image:
                plan.clips.append(PlanClip(assetID: item.id, source: .still(duration: Self.defaultStillDuration)))
            case .video:
                if let duration = item.duration {
                    plan.clips.append(PlanClip(assetID: item.id, source: .video(0...duration)))
                }
            case .audio, .subtitle:
                break
            }
        }
    }

    /// trim 后上轨：片段区间取 trim 结果。
    func appendAssetToTimeline(_ item: AssetItem, range: ClosedRange<TimeInterval>) {
        edit { plan in
            if plan.asset(withID: item.id) == nil {
                plan.assets.append(item)
            }
            plan.clips.append(PlanClip(assetID: item.id, source: .video(range)))
        }
    }

    /// 图片上轨：以指定时长追加（预览页时长选择器）。
    func appendImageToTimeline(_ item: AssetItem, duration: TimeInterval) {
        edit { plan in
            if plan.asset(withID: item.id) == nil {
                plan.assets.append(item)
            }
            plan.clips.append(PlanClip(assetID: item.id, source: .still(duration: duration)))
        }
    }

    /// 图片上轨默认时长（秒）。
    static let defaultStillDuration: TimeInterval = 3.0

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

/// 预览播放器：plan 变化 → PreviewBridge 重建 playerItem；周期性时间观察驱动字幕叠加层。
///
/// **播放状态模型（本类的健壮性核心，改这里之前先读完）**：
/// - 意图 = `wantsPlaying && isPageActive`，由 `applyDesired()` 单点收敛到 AVPlayer。
///   任何「谁该在播」的判断都只经这一处，不再散落成入口快照 / rate 推断 / 跨页标记各一份。
/// - `wantsPlaying`：用户是否希望它在播，跨页保留。只在**能读到真实播放状态**时同步
///   （页面在前台时的旧实例 `rate`、离开页面那一刻的 `rate`）——不靠跨 await 的快照。
/// - `isPageActive`：剪辑页是否在前台，由 onAppear/onDisappear 驱动，**初始 false**。
///   播放起点是「页面出现」而不是「模型构造」：AppModel 在点击项目卡时就先行构造
///   （见 ProjectListView.openProject），构造即起播会让任何未真正进入剪辑页的构造
///   留下没人停的孤儿播放。
/// - `player` 的唯一写入点是 `install(_:)`：它同步停掉被替换实例再按意图收敛，
///   结构上杜绝「旧实例继续出声」。**不要在别处给 `player` 赋值。**
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
    /// 用户是否希望预览在播（跨页保留，见类注释）
    private var wantsPlaying = true   // 首次装载视为自动播放
    /// 剪辑页是否在前台（见类注释）
    private var isPageActive = false

    init(store: EditStore, resolver: AssetResolver) {
        self.store = store
        self.resolver = resolver
        rebuild()
    }

    // MARK: 页面生命周期（剪辑页 onAppear / onDisappear 驱动）

    /// 剪辑页出现（首次进入 / 从素材库等返回）：恢复播放意图。
    func pageDidAppear() {
        isPageActive = true
        applyDesired()
    }

    /// 剪辑页离开（push 素材库 / 返回项目列表）：立即停声，并记下此刻的播放意图供返回时恢复。
    func pageDidDisappear() {
        if let player { wantsPlaying = player.rate > 0 }   // 尚无实例（未装载完）时保留原意图
        isPageActive = false
        applyDesired()
    }

    /// 单点收敛：把意图落到当前实例上。
    private func applyDesired() {
        guard let player else { return }
        if wantsPlaying && isPageActive { player.play() } else { player.pause() }
    }

    /// `player` 的唯一安装点（连同与实例绑定的轮询 Task 一起换）：先按旧实例此刻的播放状态
    /// 同步意图（仅页面在前台时可信——不在前台时旧实例是被我们自己停的），再同步停掉旧实例
    /// 与其轮询，最后按意图收敛新实例。
    private func install(_ newPlayer: AVPlayer) {
        if isPageActive, let old = player { wantsPlaying = old.rate > 0 }
        player?.pause()
        timePollingTask?.cancel()
        player = newPlayer
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
        applyDesired()
    }

    func rebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            guard let package = try? await PreviewBridge.makePreview(for: store.plan, resolver: resolver) else { return }
            // 重建竞态防护：await 期间可能已被下一次 rebuild 取消，此时不得安装过期 player。
            guard !Task.isCancelled else { return }
            cues = package.cues
            install(AVPlayer(playerItem: package.playerItem))
        }
    }

    var currentCue: CaptionCue? {
        cues.first { $0.range.contains(currentTime) }
    }
}
