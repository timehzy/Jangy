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

    /// 时间线窗格高度（预览 / 时间线分界的拖动量）；档位由屏幕高度推导，见 snapLevels。
    /// 初值非零：GeometryReader 回填前也先给一帧可用高度，避免时间线闪一帧 0 高。
    @State private var timelineHeight: CGFloat = 240
    /// 页面可用高度（GeometryReader 回填），拖动与吸附档位都据此推导。
    @State private var screenHeight: CGFloat = 0
    /// 是否已按屏幕高度落过默认档（只做一次，之后交给用户拖动）。
    @State private var heightSeeded = false
    /// 分界拖动起点高度。@GestureState：手势结束或取消都自动复位，不残留脏基准。
    @GestureState private var dividerBase: CGFloat?

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

    // MARK: 预览 / 时间线可拖分界

    /// 可拖动的分界条：上拖放大时间线，下拖放大预览；松手吸附到最近档位。
    private var divider: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 10)
            .overlay(Capsule().fill(Color(.tertiaryLabel)).frame(width: 40, height: 4))
            .contentShape(Rectangle())
            .gesture(dividerDrag)
    }

    private var dividerDrag: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($dividerBase) { _, state, _ in
                if state == nil { state = timelineHeight }   // 起手捕获一次；结束/取消自动复位
            }
            .onChanged { value in
                guard let base = dividerBase else { return }
                // 上拖（translation.height < 0）→ 时间线变高：base − 累计 translation.height
                timelineHeight = Self.clamp(base - value.translation.height,
                                            min: screenHeight * 0.15,
                                            max: screenHeight * 0.85)
            }
            .onEnded { _ in
                timelineHeight = Self.snapHeight(timelineHeight, levels: snapLevels)
            }
    }

    /// 三个吸附档位（时间线高度，点），随屏幕高度缩放：
    /// 预览最大档 → 时间线 = screenH − previewMin；半屏档 → 0.5·screenH；接近全屏档 → 0.8·screenH。
    private var snapLevels: [CGFloat] { Self.snapLevels(forScreenHeight: screenHeight) }

    static func snapLevels(forScreenHeight h: CGFloat) -> [CGFloat] {
        let previewMin = h * 0.6   // 时间线最小时，预览保留的高度（比例，非写死像素）
        return [h - previewMin, h * 0.5, h * 0.8].sorted()
    }

    /// 纯函数：取离 value 最近的档位。
    static func snapHeight(_ value: CGFloat, levels: [CGFloat]) -> CGFloat {
        levels.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
    }

    static func clamp(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lo), hi)
    }

    /// 回填页面可用高度；首次测量时给时间线一个默认档位（最小档，预览为主），只落一次。
    private func syncScreenHeight(_ h: CGFloat) {
        screenHeight = h
        if !heightSeeded {
            timelineHeight = Self.snapLevels(forScreenHeight: h)[0]
            heightSeeded = true
        }
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

            divider

            TimelineView(model: model, height: timelineHeight, onAdd: { showLibrary = true })
        }
        // 量页面可用高度（背景读取不改变既有布局），档位据此推导，不写死像素。
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { syncScreenHeight(geo.size.height) }
                    .onChange(of: geo.size.height) { _, h in syncScreenHeight(h) }
            }
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
