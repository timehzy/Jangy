import AVKit
import SwiftUI
import JangyCore

/// 素材预览页：视频（播放 + trim + 添加）、图片（缩放预览 + 时长选择 + 添加）、音频（播放示意）。
/// 添加按钮在剪辑页语境显示（视频/图片）；音频维持后置。
/// 信息面板：元数据 + 引用项目列表。预览页不提供删除。
struct AssetPreviewView: View {
    let item: AssetItem
    let resolver: AssetResolver
    @State var model: LibraryModel

    @State private var player: AVPlayer?
    @State private var trimRange: ClosedRange<TimeInterval> = 0...0
    @State private var isPlaying = false
    @State private var zoomScale: CGFloat = 1
    @State private var showInfo = false
    @State private var referencingProjects: [String] = []
    @State private var stillDuration: TimeInterval = 3.0
    @State private var customStillDuration: Double = 3.0

    private var fileURL: URL { resolver.resolve(item) }
    private var canAdd: Bool {
        guard model.attachedEditor != nil else { return false }
        switch item.kind {
        case .video: return item.duration != nil
        case .image: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            if item.kind == .video, let duration = item.duration {
                VStack(alignment: .leading, spacing: 4) {
                    VideoTrimView(url: fileURL, duration: duration, range: $trimRange)
                    Text("已选 \(trimRange.lowerBound.formatted(.number.precision(.fractionLength(1))))s ~ \(trimRange.upperBound.formatted(.number.precision(.fractionLength(1))))s / 共 \(duration.formatted(.number.precision(.fractionLength(1))))s")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }

            if item.kind == .image {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("显示时长", selection: $stillDuration) {
                        Text("2s").tag(2.0)
                        Text("3s").tag(3.0)
                        Text("5s").tag(5.0)
                        Text("自定义").tag(-1.0)
                    }
                    .pickerStyle(.segmented)
                    if stillDuration == -1.0 {
                        HStack {
                            Text("\(customStillDuration.formatted(.number.precision(.fractionLength(1))))s")
                                .font(.caption).foregroundStyle(.secondary)
                            Slider(value: $customStillDuration, in: 0.5...30, step: 0.5)
                        }
                    }
                }
                .padding()
            }

            if canAdd {
                Button {
                    if item.kind == .image {
                        let duration = stillDuration == -1.0 ? customStillDuration : stillDuration
                        model.addImageToTimeline(item, duration: duration)
                    } else {
                        model.addToTimeline(item, range: trimRange)
                    }
                } label: {
                    Text("添加到时间线").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(item.kind == .video && trimRange.upperBound <= trimRange.lowerBound)
                .padding()
            }
        }
        .navigationTitle(item.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("信息") {
                    referencingProjects = model.referencingProjects(of: item.id)
                    showInfo = true
                }
            }
        }
        .sheet(isPresented: $showInfo) { infoSheet }
        .onDisappear { player?.pause() }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .video:
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().tint(.white)
                    .task {
                        trimRange = 0...(item.duration ?? 0)
                        player = AVPlayer(url: fileURL)
                    }
            }
        case .image:
            if let image = UIImage(contentsOfFile: fileURL.path) {
                Image(uiImage: image)
                    .resizable().aspectRatio(contentMode: .fit)
                    .scaleEffect(zoomScale)
                    .gesture(MagnifyGesture().onChanged { zoomScale = $0.magnification }
                        .onEnded { _ in withAnimation { zoomScale = 1 } })
            } else {
                Text("无法读取图片").foregroundStyle(.secondary)
            }
        case .audio:
            VStack(spacing: 20) {
                // 波形示意（确定性伪随机，装饰用途；真实波形留待音频专项）
                HStack(spacing: 3) {
                    ForEach(0..<40, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5)
                            .frame(width: 3, height: 8 + 28 * pseudoRandom(i))
                    }
                }
                .foregroundStyle(Color.accentColor)
                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 48))
                }
                Text("音频上轨将在后续版本开放")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .subtitle:
            Text("字幕文件请在剪辑页使用").foregroundStyle(.secondary)
        }
    }

    /// 确定性伪随机（同一种子同一波形）
    private func pseudoRandom(_ i: Int) -> CGFloat {
        CGFloat((i * 2654435761 &* 40503) % 1000) / 1000.0
    }

    private func togglePlay() {
        if player == nil { player = AVPlayer(url: fileURL) }
        if isPlaying { player?.pause() } else { player?.play() }
        isPlaying.toggle()
    }

    private var infoSheet: some View {
        NavigationStack {
            List {
                LabeledContent("名称", value: item.displayName)
                LabeledContent("类型", value: kindLabel)
                if let duration = item.duration {
                    LabeledContent("时长", value: "\(duration.formatted(.number.precision(.fractionLength(1))))s")
                }
                if let w = item.pixelWidth, let h = item.pixelHeight {
                    LabeledContent("分辨率", value: "\(w) × \(h)")
                }
                if let size = fileSize {
                    LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                if let importedAt = item.importedAt {
                    LabeledContent("导入时间", value: importedAt.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("被引用", value: referencingProjects.isEmpty ? "无" : referencingProjects.joined(separator: "、"))
            }
            .navigationTitle("素材信息")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private var kindLabel: String {
        switch item.kind {
        case .video: return "视频"
        case .image: return "图片"
        case .audio: return "音频"
        case .subtitle: return "字幕"
        }
    }

    private var fileSize: Int64? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int64
    }
}
