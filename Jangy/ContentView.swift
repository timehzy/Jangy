import SwiftUI
import JangyCore

struct ContentView: View {
    var model: AppModel
    @State private var showPhotoPicker = false
    @State private var showFilesPicker = false
    @State private var showResetConfirm = false
    @State private var showExportPanel = false
    @State private var showAgent = false

    var body: some View {
        VStack(spacing: 0) {
            PreviewView(player: model.player)

            // 操作条：撤销/重做 + 字幕开关 + 导入（相册/文件）+ 新建草稿 + 导出
            HStack {
                Button("撤销") { model.undo() }.disabled(!model.store.canUndo || model.agent.isRunning)
                Button("重做") { model.redo() }.disabled(!model.store.canRedo || model.agent.isRunning)
                Spacer()
                Button(model.store.plan.captions?.isEnabled == true ? "字幕：开" : "字幕：关") {
                    model.edit { $0.captions?.isEnabled.toggle() }
                }
                .disabled(model.agent.isRunning)
                Menu("导入") {
                    Button("从相册导入") { showPhotoPicker = true }
                    Button("从文件导入") { showFilesPicker = true }
                }
                .disabled(model.importProgress != nil || model.agent.isRunning)
                Button("新建") { showResetConfirm = true }.disabled(model.agent.isRunning)
                Button("Agent") { showAgent = true }
                    .disabled(!model.agent.isConfigured || model.importProgress != nil)
                Button("导出") { showExportPanel = true }
                    .disabled(model.exportProgress != nil || model.agent.isRunning)
            }
            .padding(.horizontal)

            if let progress = model.importProgress {
                ProgressView(value: progress) { Text("导入素材…").font(.caption) }
                    .padding(.horizontal)
            }
            if let progress = model.exportProgress {
                ProgressView(value: progress).padding(.horizontal)
            }
            if let message = model.importMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            if let message = model.draftMessage {
                Text(message).font(.caption).foregroundStyle(.orange).padding(.horizontal)
            }
            if let message = model.exportMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            if let issues = model.lastIssues {
                Text(issues.map(\.description).joined(separator: "\n"))
                    .font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            if !model.agent.isConfigured {
                Text("未配置 Agent 凭据：把 agent-config.json 放入 Application Support/Jangy/")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }

            TimelineView(model: model)
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPicker { identifiers in
                showPhotoPicker = false
                model.importVideos(assetIdentifiers: identifiers)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showFilesPicker) {
            FilesPicker { urls in
                showFilesPicker = false
                model.importVideosFromFiles(urls: urls)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showExportPanel) {
            ExportPanel { options in
                model.export(options: options)
            }
        }
        .sheet(isPresented: $showAgent) {
            AgentChatView(controller: model.agent)
        }
        .confirmationDialog("新建草稿？当前时间线将清空（可撤销）",
                            isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("新建草稿", role: .destructive) { model.resetDraft() }
            Button("取消", role: .cancel) {}
        }
    }
}
