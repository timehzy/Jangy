import AVFoundation
import Foundation
import ImageIO

/// 素材元数据探测结果。全部字段可空：探测宽容，失败只留 nil，
/// 不阻断导入/校验（validator/引擎层有兜底语义）。
public struct AssetMetadata: Equatable, Sendable {
    public var duration: TimeInterval?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var hasAudio: Bool?
}

/// 素材入库：把外部文件（picker 导出的临时文件、文件 App 拷入件等）收进素材库目录，
/// UUID 命名防冲突，并探测元数据（时长/分辨率/有无音频）生成 AssetItem 登记项。
///
/// 注意是 move 而非 copy：调用方拿到的通常是临时目录文件（kadr-photos 导出产物），
/// move 不留残余、不占双份磁盘。
public struct AssetImporter: Sendable {
    /// 素材库目录（通常与 AssetResolver.directory 相同）
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// 视频元数据探测：DraftStore 完整性比对与 importVideo 共用此入口。
    public static func probeMetadata(of url: URL) async -> AssetMetadata {
        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration)
        let seconds = duration.flatMap { $0.isNumeric ? $0.seconds : nil }
        let videoTrack = try? await asset.loadTracks(withMediaType: .video).first
        let naturalSize = try? await videoTrack?.load(.naturalSize)
        let hasAudio = try? await asset.loadTracks(withMediaType: .audio).isEmpty == false
        return AssetMetadata(
            duration: seconds,
            pixelWidth: naturalSize.map { Int($0.width) },
            pixelHeight: naturalSize.map { Int($0.height) },
            hasAudio: hasAudio
        )
    }

    /// 导入视频素材。成功返回登记项（kind = .video，元数据已探测）。
    @discardableResult
    public func importVideo(from sourceURL: URL, origin: AssetOrigin, displayName: String? = nil) async throws -> AssetItem {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
        let fileName = "\(UUID().uuidString).\(ext)"
        let destination = directory.appendingPathComponent(fileName)
        try fm.moveItem(at: sourceURL, to: destination)

        let metadata = await Self.probeMetadata(of: destination)

        return AssetItem(
            kind: .video,
            fileName: fileName,
            displayName: displayName ?? sourceURL.deletingPathExtension().lastPathComponent,
            origin: origin,
            duration: metadata.duration,
            pixelWidth: metadata.pixelWidth,
            pixelHeight: metadata.pixelHeight,
            hasAudio: metadata.hasAudio,
            importedAt: Date()
        )
    }

    /// 图片元数据探测：ImageIO 读像素尺寸（不解码像素，快）。无时长/音频概念。
    public static func probeImageMetadata(of url: URL) -> AssetMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return AssetMetadata()
        }
        return AssetMetadata(
            duration: nil,
            pixelWidth: props[kCGImagePropertyPixelWidth] as? Int,
            pixelHeight: props[kCGImagePropertyPixelHeight] as? Int,
            hasAudio: nil
        )
    }

    /// 音频元数据探测：只取时长。
    public static func probeAudioMetadata(of url: URL) async -> AssetMetadata {
        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration)
        return AssetMetadata(duration: duration.flatMap { $0.isNumeric ? $0.seconds : nil },
                             pixelWidth: nil, pixelHeight: nil, hasAudio: nil)
    }

    /// 通用素材入库：视频/图片/音频。sha256 在 move 前计算（素材库去重判定的依据）；
    /// 调用方已算过可经 knownSHA256 传入，避免大文件重复读盘。
    @discardableResult
    public func importMedia(from sourceURL: URL, kind: AssetKind, origin: AssetOrigin,
                            displayName: String? = nil, knownSHA256: String? = nil) async throws -> AssetItem {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = try knownSHA256 ?? AssetHasher.sha256(of: sourceURL)

        let ext = sourceURL.pathExtension.isEmpty ? Self.defaultExtension(for: kind) : sourceURL.pathExtension
        let fileName = "\(UUID().uuidString).\(ext)"
        let destination = directory.appendingPathComponent(fileName)
        try fm.moveItem(at: sourceURL, to: destination)

        let metadata: AssetMetadata
        switch kind {
        case .video: metadata = await Self.probeMetadata(of: destination)
        case .image: metadata = Self.probeImageMetadata(of: destination)
        case .audio: metadata = await Self.probeAudioMetadata(of: destination)
        case .subtitle: metadata = AssetMetadata()
        }

        return AssetItem(
            kind: kind,
            fileName: fileName,
            displayName: displayName ?? sourceURL.deletingPathExtension().lastPathComponent,
            origin: origin,
            duration: metadata.duration,
            pixelWidth: metadata.pixelWidth,
            pixelHeight: metadata.pixelHeight,
            hasAudio: metadata.hasAudio,
            importedAt: Date(),
            sha256: hash
        )
    }

    private static func defaultExtension(for kind: AssetKind) -> String {
        switch kind {
        case .video: return "mp4"
        case .image: return "jpg"
        case .audio: return "m4a"
        case .subtitle: return "srt"
        }
    }
}
