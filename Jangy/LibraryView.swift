import SwiftUI
import UIKit
import JangyCore
import UniformTypeIdentifiers

/// 素材库：类型 tab + 三列网格。首页进入 = 纯管理；剪辑页进入（attachedEditor 非 nil）
/// = 视频/图片格带 ＋ 快捷上轨。多选模式只有删除（引用保护）。
struct LibraryView: View {
    @State var model: LibraryModel

    @State private var tab: AssetKind = .video
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var showPhotoPicker = false
    @State private var showFilesPicker = false
    @State private var previewItem: AssetItem?
    @State private var showDeleteConfirm = false
    @State private var blockedNames: [String]?
    @State private var scanFailure: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    private var filtered: [AssetItem] {
        model.items.filter { $0.kind == tab }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("类型", selection: $tab) {
                Text("视频").tag(AssetKind.video)
                Text("图片").tag(AssetKind.image)
                Text("音频").tag(AssetKind.audio)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.vertical, 8)

            if filtered.isEmpty {
                emptyState
            } else {
                grid
            }

            if let progress = model.importProgress {
                ProgressView(value: progress) { Text("导入素材…").font(.caption) }.padding(.horizontal)
            }
            if let message = model.importMessage ?? model.libraryMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
        }
        .navigationTitle("素材库")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isSelecting {
                    Button("完成") { exitSelection() }
                } else {
                    HStack(spacing: 16) {
                        Menu("导入") {
                            Button("从相册导入") { showPhotoPicker = true }
                            Button("从文件导入") { showFilesPicker = true }
                        }
                        Button("多选") { isSelecting = true }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                Button("删除 \(selection.count) 个素材") { showDeleteConfirm = true }
                    .foregroundStyle(.red)
                    .disabled(selection.isEmpty)
                    .padding(.vertical, 10)
            }
        }
        .onAppear { model.reload() }
        .navigationDestination(item: $previewItem) { item in
            AssetPreviewView(item: item, resolver: model.resolver, model: model)
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPicker { identifiers in
                showPhotoPicker = false
                model.importFromPhotos(identifiers: identifiers)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showFilesPicker) {
            FilesPicker(contentTypes: [.movie, .image, .audio]) { urls in
                showFilesPicker = false
                model.importFromFiles(urls: urls)
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("从素材库删除（不影响项目内已有片段的播放，被引用的素材会被拦截）",
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) { performDelete() }
            Button("取消", role: .cancel) {}
        }
        .alert("无法删除被引用的素材", isPresented: blockedBinding) {
            Button("只删除未引用的") { deleteUnreferencedOnly() }
            Button("好", role: .cancel) {}
        } message: {
            Text("以下项目正在使用所选素材：\((blockedNames ?? []).joined(separator: "、"))")
        }
        .alert("删除失败", isPresented: scanFailureBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(scanFailure ?? "")
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toastMessage {
                Text(toast)
                    .font(.caption).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 60)
                    .task(id: model.toastSequence) { try? await Task.sleep(for: .seconds(1.5)); model.toastMessage = nil }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("还没有素材").foregroundStyle(.secondary)
            Menu("＋ 导入素材") {
                Button("从相册导入") { showPhotoPicker = true }
                Button("从文件导入") { showFilesPicker = true }
            }
            .font(.body)
            Spacer()
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(filtered) { item in
                    AssetCell(item: item, thumbnailer: model.thumbnailer,
                              isSelecting: isSelecting, isSelected: selection.contains(item.id),
                              isNew: model.recentlyImported.contains(item.id),
                              showQuickAdd: model.attachedEditor != nil
                                  && ((tab == .video && item.duration != nil) || tab == .image),
                              onQuickAdd: { model.quickAdd(item) })
                        .onTapGesture {
                            if isSelecting {
                                if selection.contains(item.id) { selection.remove(item.id) }
                                else { selection.insert(item.id) }
                            } else {
                                previewItem = item
                            }
                        }
                }
            }
            .padding(4)
        }
    }

    private func performDelete() {
        switch model.delete(ids: selection) {
        case .deleted:
            exitSelection()
        case .blocked(let names):
            blockedNames = names
        case .scanFailed(let reason):
            scanFailure = reason
        }
    }

    private func deleteUnreferencedOnly() {
        let removable = model.unreferencedIDs(in: selection)
        guard !removable.isEmpty else { return }
        _ = model.delete(ids: removable)
        exitSelection()
    }

    private func exitSelection() {
        isSelecting = false
        selection.removeAll()
    }

    private var blockedBinding: Binding<Bool> {
        Binding(get: { blockedNames != nil }, set: { if !$0 { blockedNames = nil } })
    }

    private var scanFailureBinding: Binding<Bool> {
        Binding(get: { scanFailure != nil }, set: { if !$0 { scanFailure = nil } })
    }
}

/// 素材格：缩略图（音频为图标）+ 时长角标 + 剪辑页语境的 ＋ 快捷上轨。
/// isNew = 本次导入的新素材，accent 色描边高亮。
private struct AssetCell: View {
    let item: AssetItem
    let thumbnailer: TimelineThumbnailer
    let isSelecting: Bool
    let isSelected: Bool
    let isNew: Bool
    let showQuickAdd: Bool
    let onQuickAdd: () -> Void

    @State private var thumbnail: Image?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Rectangle().fill(Color(.secondarySystemFill))
                if let thumbnail {
                    thumbnail.resizable().aspectRatio(contentMode: .fill)
                } else if item.kind == .audio {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(.secondary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()

            if let duration = item.duration {
                Text("\(duration, format: .number.precision(.fractionLength(0)))s")
                    .font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(4)
            }
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(6)
            }
            if showQuickAdd && !isSelecting {
                Button(action: onQuickAdd) {
                    Image(systemName: "plus")
                        .font(.caption.bold())
                        .frame(width: 26, height: 26)
                        .background(Color.accentColor, in: Circle())
                        .foregroundStyle(.white)
                }
                .padding(5)
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            if isNew {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .task { thumbnail = await thumbnailer.thumbnail(for: item, maxPixel: 240)
            .map { Image(decorative: $0, scale: UIScreen.main.scale) } }
        .accessibilityLabel(item.displayName)
    }
}
