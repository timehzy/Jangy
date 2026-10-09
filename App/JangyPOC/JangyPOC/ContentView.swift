import SwiftUI
import POCCore

struct ContentView: View {
    var model: AppModel
    @State private var showPhotoPicker = false
    @State private var showResetConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            PreviewView(player: model.player)

            // 操作条：撤销/重做 + 字幕开关 + 相册导入 + 新建草稿 + 导出
            HStack {
                Button("撤销") { model.undo() }.disabled(!model.store.canUndo)
                Button("重做") { model.redo() }.disabled(!model.store.canRedo)
                Spacer()
                Button(model.store.plan.captions?.isEnabled == true ? "字幕：开" : "字幕：关") {
                    model.edit { $0.captions?.isEnabled.toggle() }
                }
                Button("导入") { showPhotoPicker = true }
                    .disabled(model.importProgress != nil)
                Button("新建") { showResetConfirm = true }
                Button("导出") { model.export() }
                    .disabled(model.exportProgress != nil)
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

            TimelineView(model: model)
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPicker { identifiers in
                showPhotoPicker = false
                model.importVideos(assetIdentifiers: identifiers)
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("新建草稿？当前时间线将重置为样例工程（可撤销）",
                            isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("新建草稿", role: .destructive) { model.resetDraft() }
            Button("取消", role: .cancel) {}
        }
    }
}
