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

    /// 时间线上选中的元素 id（纯 L0 局部态，不进 plan）。选中即出操作条（变速/转场/删除/布局）。
    @State private var selection: UUID?

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

    // MARK: 选中态操作条（变速 / 转场 / 删除 / 布局预设）

    /// 选中的内容元素及其片段（按 id 跨轨定位，不假定在主轨）。找不到（撤销/删除后 selection
    /// 悬空）时返回 nil，操作条随之隐藏。
    private var selectedClip: (clip: PlanClip, asset: AssetItem?)? {
        guard let id = selection else { return nil }
        for track in model.store.plan.tracks {
            guard let element = track.elements.first(where: { $0.id == id }),
                  case .content(let payload) = element.content,
                  let clip = payload.value as? PlanClip else { continue }
            return (clip, model.store.plan.asset(withID: clip.assetID))
        }
        return nil
    }

    /// 选中操作条：变速 / 转场 / 布局（菜单）+ 删除（留 gap）+ 取消选择。
    private var selectionBar: some View {
        HStack(spacing: 14) {
            Menu("变速") {
                ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { rate in
                    Button(speedLabel(rate)) { setSpeed(rate) }
                }
            }
            Menu("转场") {
                Button("无") { setTransition(nil) }
                Button("叠化 0.5s") { setTransition(.dissolve(duration: 0.5)) }
                Button("淡入淡出 0.5s") { setTransition(.fade(duration: 0.5)) }
            }
            Menu("布局") {
                Button("全屏") { setLayout(nil) }
                Button("左半屏") { setLayout(.left) }.disabled(!canHalfScreen(.left))
                Button("右半屏") { setLayout(.right) }.disabled(!canHalfScreen(.right))
            }
            Button("删除", role: .destructive) { deleteSelection() }
            Spacer()
            Button("取消选择") { selection = nil }
        }
        .font(.subheadline)
        .padding(.horizontal)
        .disabled(model.agent.isRunning)
    }

    private func speedLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate)×"
    }

    /// 改选中片段的 payload（按 id 跨轨定位，一次 model.edit = 单撤销步）。
    private func updateSelectedClip(_ mutate: (inout PlanClip) -> Void) {
        guard let id = selection else { return }
        model.edit { plan in
            for ti in plan.tracks.indices {
                guard let ei = plan.tracks[ti].elements.firstIndex(where: { $0.id == id }),
                      case .content(let payload) = plan.tracks[ti].elements[ei].content,
                      var clip = payload.value as? PlanClip else { continue }
                mutate(&clip)
                plan.tracks[ti].elements[ei].content = .content(TrackPayload(clip))
                return
            }
        }
    }

    private func setSpeed(_ rate: Double) {
        updateSelectedClip { $0.speed = .flat(rate) }
    }

    private func setTransition(_ transition: PlanTransition?) {
        updateSelectedClip { $0.transitionAfter = transition }
    }

    /// 删除 = 留 gap（链式轨中间内容元素换等长 gap），走公约「删除语义」。
    private func deleteSelection() {
        guard let id = selection else { return }
        model.edit { plan in TrackOperations.removeElement(id, in: &plan) }
        selection = nil
    }

    /// 该侧半屏能否算出（视频像素尺寸未知 → halfScreen 返 nil → 禁用，不静默回退全屏）。
    private func canHalfScreen(_ side: ClipTransform.Half) -> Bool {
        guard let asset = selectedClip?.asset else { return false }
        return ClipTransform.halfScreen(for: asset, preset: model.store.plan.preset, side: side) != nil
    }

    /// 设选中元素的布局：全屏 = transform nil；半屏按素材/预设算 scale。一次 model.edit。
    private func setLayout(_ side: ClipTransform.Half?) {
        guard let id = selection else { return }
        model.edit { plan in
            for ti in plan.tracks.indices {
                guard let ei = plan.tracks[ti].elements.firstIndex(where: { $0.id == id }),
                      case .content(let payload) = plan.tracks[ti].elements[ei].content,
                      var clip = payload.value as? PlanClip else { continue }
                if let side, let asset = plan.asset(withID: clip.assetID),
                   let transform = ClipTransform.halfScreen(for: asset, preset: plan.preset, side: side) {
                    clip.transform = transform
                } else {
                    clip.transform = nil   // 全屏
                }
                plan.tracks[ti].elements[ei].content = .content(TrackPayload(clip))
                return
            }
        }
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

            if selectedClip != nil {
                selectionBar
            }

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

            TimelineView(model: model, height: timelineHeight, selection: $selection,
                         onAdd: { showLibrary = true })
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
