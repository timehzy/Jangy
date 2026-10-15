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

    /// 字幕轨（v4：字幕是绝对定位轨，开关读轨级 settings）。
    private var captionTrack: PlanTrack? {
        model.store.plan.tracks.first { $0.kind == .caption }
    }

    private var captionEnabled: Bool {
        guard let track = captionTrack else { return false }
        return CaptionFeature.settings(of: track).isEnabled
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                PreviewView(player: model.player)
                if model.store.plan.primaryTrack?.elements.isEmpty ?? true {
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
                Button(captionEnabled ? "字幕：开" : "字幕：关") {
                    model.edit { plan in
                        guard let ti = plan.tracks.firstIndex(where: { $0.kind == .caption }) else { return }
                        var settings = CaptionFeature.settings(of: plan.tracks[ti])
                        settings.isEnabled.toggle()
                        plan.tracks[ti].settings = TrackPayload(settings)
                    }
                }
                .disabled(captionTrack == nil || model.agent.isRunning)
                Button("素材库") { showLibrary = true }
                    .disabled(model.agent.isRunning)
                Button("Agent") { showAgent = true }
                    .disabled(!model.agent.isConfigured)
                Button("导出成片") { showExportPanel = true }
                    .disabled(model.exportProgress != nil || model.agent.isRunning || (model.store.plan.primaryTrack?.elements.isEmpty ?? true))
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
        // 剪辑页出现（首次进入 / 从素材库等返回）：恢复播放意图；同时建立素材库上轨语境
        .onAppear {
            model.player.pageDidAppear()
            libraryModel.attachedEditor = model
        }
        // 离开剪辑页（push 素材库 / 返回项目列表）：先停预览声音并刷新封面
        .onDisappear {
            model.player.pageDidDisappear()
            model.updateCover()
        }
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
