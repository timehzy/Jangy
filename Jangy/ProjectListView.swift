import SwiftUI
import JangyCore
import UniformTypeIdentifiers

/// 首页：项目列表（单列大卡）。点卡片进剪辑页；多选模式批量删除/复制/导出工程包。
struct ProjectListView: View {
    @State var model: ProjectListModel
    @State var libraryModel: LibraryModel

    @State private var openedProject: ProjectSummary?
    /// AppModel 在点击处构造（不在 destination 闭包里）：后者随 body 重算反复执行，
    /// 会重复同步读盘 loadProject 并构造一次性 AppModel（附带 PlayerController rebuild）
    @State private var editorModel: AppModel?
    @State private var showLibrary = false
    @State private var showPackagePicker = false
    @State private var renameTarget: ProjectSummary?
    @State private var renameText = ""
    @State private var infoTarget: ProjectSummary?
    @State private var pendingDelete: Set<UUID>?
    @State private var showShareSheet = false

    var body: some View {
        Group {
            if model.projects.isEmpty {
                emptyState
            } else {
                projectList
            }
        }
        .navigationTitle("项目")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if model.isSelecting {
                    Button("完成") { model.exitSelection() }
                } else {
                    HStack(spacing: 16) {
                        Button("素材库") { showLibrary = true }
                        Menu {
                            Button("导入工程包") { showPackagePicker = true }
                        } label: { Image(systemName: "ellipsis.circle") }
                        Button("多选") { model.isSelecting = true }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isSelecting {
                selectionBar
            } else {
                Button { openProject(model.createProject()) } label: {
                    Label("新建项目", systemImage: "plus")
                        .padding(.horizontal, 24).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            // 首页可见 = 不在任何项目内：清空剪辑页语境，防止素材库出现 stale 的 ＋
            libraryModel.attachedEditor = nil
            model.reload()
        }
        .navigationDestination(item: $openedProject) { summary in
            if let editorModel {
                EditorView(model: editorModel, libraryModel: libraryModel, projectName: summary.name)
            }
        }
        .navigationDestination(isPresented: $showLibrary) {
            LibraryView(model: libraryModel)
        }
        .sheet(isPresented: $showShareSheet, onDismiss: { model.packagesToShare = nil }) {
            if let urls = model.packagesToShare { ShareSheet(items: urls) }
        }
        .onChange(of: model.packagesToShare != nil) { _, has in showShareSheet = has }
        .sheet(isPresented: $showPackagePicker) {
            FilesPicker(contentTypes: [.zip]) { urls in
                showPackagePicker = false
                if let url = urls.first { model.importPackage(from: url) }
            }
            .ignoresSafeArea()
        }
        .sheet(item: $infoTarget) { summary in
            ProjectInfoSheet(summary: summary, storageSize: model.referencedStorageSize(of: summary.id))
                .presentationDetents([.medium])
        }
        .alert("重命名项目", isPresented: renameBinding) {
            TextField("项目名", text: $renameText)
            Button("确定") { if let t = renameTarget { model.rename(id: t.id, to: renameText) } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除后不可恢复（素材库不受影响）", isPresented: deleteBinding, titleVisibility: .visible) {
            Button("删除 \(pendingDelete?.count ?? 0) 个项目", role: .destructive) {
                if let ids = pendingDelete { model.delete(ids: ids) }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("提示", isPresented: messageBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("还没有项目").foregroundStyle(.secondary)
            Button { openProject(nil) } label: {
                Label("新建你的第一个项目", systemImage: "plus")
                    .padding(.horizontal, 24).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    private var projectList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(model.projects) { summary in
                    ProjectCard(summary: summary, isSelecting: model.isSelecting,
                                isSelected: model.selection.contains(summary.id))
                        .onTapGesture {
                            if model.isSelecting {
                                model.toggleSelection(of: summary.id)
                            } else {
                                openProject(summary)
                            }
                        }
                        .contextMenu {
                            if !model.isSelecting {
                                Button("重命名") { renameTarget = summary; renameText = summary.name }
                                Button("复制") { model.duplicate(ids: [summary.id]) }
                                Button("查看信息") { infoTarget = summary }
                                Button("导出工程包") { model.exportPackages(ids: [summary.id]) }
                                Button("删除", role: .destructive) { pendingDelete = [summary.id] }
                            }
                        }
                }
            }
            .padding()
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 32) {
            Button("删除") { pendingDelete = model.selection }
                .foregroundStyle(.red).disabled(model.selection.isEmpty)
            Button("复制") { model.duplicate(ids: model.selection) }
                .disabled(model.selection.isEmpty)
            Button("导出工程包") { model.exportPackages(ids: model.selection) }
                .disabled(model.selection.isEmpty)
        }
        .padding(.vertical, 10)
    }

    /// 点击处构造 AppModel 再触发导航（nil = 先新建项目）
    private func openProject(_ summary: ProjectSummary?) {
        guard let summary = summary ?? model.createProject() else { return }
        editorModel = makeEditorModel(for: summary)
        openedProject = summary
    }

    private func makeEditorModel(for summary: ProjectSummary) -> AppModel {
        do {
            let plan = try model.projectStore.loadProject(id: summary.id)
            return AppModel(projectID: summary.id, store: EditStore(initial: plan),
                            resolver: model.resolver, projectStore: model.projectStore)
        } catch {
            return AppModel(projectID: summary.id, store: EditStore(initial: EditPlan(clips: [])),
                            resolver: model.resolver, projectStore: model.projectStore,
                            restoreNotice: "工程恢复失败（\(error.localizedDescription)），已从空时间线起步")
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var messageBinding: Binding<Bool> {
        Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
    }
}

/// 项目大卡：封面帧 + 名称 + 时长 + 修改时间。
private struct ProjectCard: View {
    let summary: ProjectSummary
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let image = UIImage(contentsOfFile: summary.coverURL.path) {
                        Image(uiImage: image).resizable().aspectRatio(16.0/9, contentMode: .fill)
                    } else {
                        Rectangle().fill(Color(.secondarySystemFill))
                            .aspectRatio(16.0/9, contentMode: .fill)
                            .overlay { Image(systemName: "film").foregroundStyle(.secondary) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? Color.accentColor : .white)
                        .padding(8)
                }
            }
            Text(summary.name).font(.headline)
            Text("\(summary.duration.formatted(.number.precision(.fractionLength(1))))s · \(summary.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 项目信息半屏 sheet。
private struct ProjectInfoSheet: View {
    let summary: ProjectSummary
    let storageSize: Int64

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("名称", value: summary.name)
                LabeledContent("时长", value: "\(summary.duration.formatted(.number.precision(.fractionLength(1))))s")
                LabeledContent("片段数", value: "\(summary.clipCount)")
                LabeledContent("引用素材", value: "\(summary.referencedAssetCount) 个")
                LabeledContent("创建时间", value: summary.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("修改时间", value: summary.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("引用素材体积", value: ByteCountFormatter.string(fromByteCount: storageSize, countStyle: .file))
            }
            .navigationTitle("项目信息")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
