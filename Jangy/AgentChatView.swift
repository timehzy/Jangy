import SwiftUI
import JangyCore

/// 剪辑 Agent 对话页（L0）：半屏 sheet，IM 形态对话流 + 底部输入框。
/// 零业务逻辑：所有状态来自 AgentController，操作只有 send/stop/dismiss。
struct AgentChatView: View {
    var controller: AgentController
    @Environment(\.dismiss) private var dismiss

    /// 档位：small = 露出操作条，medium = 露出时间线，half = 只露预览（默认），full = 全屏
    @State private var detent: PresentationDetent = .fraction(0.8)
    @State private var input = ""

    private static let small = PresentationDetent.fraction(0.35)
    private static let medium = PresentationDetent.fraction(0.55)
    private static let half = PresentationDetent.fraction(0.8)

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
            inputBar
        }
        .presentationDetents([Self.small, Self.medium, Self.half, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled)
        .presentationDragIndicator(.visible)
    }

    /// 自定义头部：左关闭（回主编辑页）/ 中标题 / 右全屏切换（全屏态变退出全屏，回半屏档）
    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold))
            }
            Spacer()
            Text("剪辑 Agent").font(.subheadline.weight(.semibold))
            Spacer()
            Button {
                withAnimation { detent = (detent == .large) ? Self.half : .large }
            } label: {
                Image(systemName: detent == .large ? "arrow.down.right.and.arrow.up.left"
                                                   : "arrow.up.left.and.arrow.down.right")
                    .font(.body.weight(.semibold))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(controller.items) { item in
                    bubble(for: item).id(item.id)
                }
            }
            .padding()
        }
        // 底部锚定（iMessage 同款）：内容不足一屏时贴底而不是贴顶；
        // 新消息从底部进入、把旧内容往上顶；用户上翻阅读时不拽动位置
        .defaultScrollAnchor(.bottom)
    }

    @ViewBuilder
    private func bubble(for item: AgentChatItem) -> some View {
        switch item.content {
        case .user(let text):
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
            }
        case .assistant(let text):
            HStack {
                Text(text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 16))
                Spacer(minLength: 60)
            }
        case .tool(let name, let summary, let status):
            HStack(spacing: 6) {
                Image(systemName: iconName(for: status))
                    .foregroundStyle(color(for: status))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.caption.weight(.semibold).monospaced())
                    Text(summary).font(.caption2.monospaced())
                        .foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer()
            }
            .padding(8)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
        case .snapshot(let path, let at):
            VStack(alignment: .leading, spacing: 4) {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable().scaledToFit()
                        .frame(maxWidth: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text(String(format: "快照 @ %.1fs", at)).font(.caption2).foregroundStyle(.secondary)
            }
        case .done(let turns):
            Label("任务完成（\(turns) 轮；可用「撤销」整体回退）", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red)
        case .stopped:
            Label("已停止", systemImage: "stop.circle")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func iconName(for status: AgentChatItem.Status) -> String {
        switch status {
        case .pending: "circle.dotted"
        case .ok: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    private func color(for status: AgentChatItem.Status) -> Color {
        switch status {
        case .pending: .secondary
        case .ok: .green
        case .error: .red
        }
    }

    /// 底部输入框：运行中发送按钮变停止按钮（spec 拍板 #4）
    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("描述你想要的剪辑…", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(controller.isRunning)
            if controller.isRunning {
                Button { controller.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
            } else {
                Button {
                    controller.send(input)
                    input = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
