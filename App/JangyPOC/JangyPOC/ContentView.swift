import SwiftUI
import POCCore

struct ContentView: View {
    var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PreviewView(player: model.player)

            // 操作条：撤销/重做 + 字幕开关 + 追加片段 + 导出
            HStack {
                Button("撤销") { model.undo() }.disabled(!model.store.canUndo)
                Button("重做") { model.redo() }.disabled(!model.store.canRedo)
                Spacer()
                Button(model.store.plan.captions?.isEnabled == true ? "字幕：开" : "字幕：关") {
                    model.edit { $0.captions?.isEnabled.toggle() }
                }
                Button("追加片段") {
                    model.edit {
                        $0.clips.append(PlanClip(source: MediaRef(fileName: "clip1.mp4"), range: 0...2))
                    }
                }
                Button("导出") { model.export() }
                    .disabled(model.exportProgress != nil)
            }
            .padding(.horizontal)

            if let progress = model.exportProgress {
                ProgressView(value: progress).padding(.horizontal)
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
    }
}
