import AVFoundation
import Foundation

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
}
