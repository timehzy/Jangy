import AVFoundation
import Foundation
import Photos
import Kadr
import KadrPhotos

/// 相册导入桥：PHAsset localIdentifier → 磁盘文件 URL。
/// 属于引擎适配层文件族（EngineBridge/PreviewBridge/ExportRunner/PhotosBridge）——
/// POCCore 中唯一允许 import Kadr / KadrCaptions / KadrPhotos 的地方（硬边界规则 1）。
///
/// 授权说明：kadr-photos 的 resolver 要求 readWrite 授权（.authorized 或 .limited），
/// 因此即使 PHPicker 本身免授权，走「选中 → 解析 PHAsset」链路前必须先 requestReadAccess()。
public enum PhotosBridge {

    public enum BridgeError: Error, CustomStringConvertible {
        /// picker 返回的 localIdentifier 已解析不到 PHAsset（选择后被删除等）
        case assetNotFound(String)

        public var description: String {
            switch self {
            case .assetNotFound(let id): return "相册中找不到所选素材（可能已被删除）: \(id)"
            }
        }
    }

    /// 申请相册读权限（kadr-photos resolver 的前置条件）。返回是否可用。
    public static func requestReadAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// 把 picker 返回的 assetIdentifier 解析成磁盘文件 URL（iCloud 素材自动下载，
    /// progress 回调 0...1 仅覆盖下载阶段）。产物在临时目录，调用方负责 move 进素材库
    /// （见 AssetImporter）。
    ///
    /// 导出策略：优先 passthrough——不重编码，HDR/高帧率/画质原样保留且秒级完成；
    /// 容器或编码与 mp4 不兼容时（如 ProRes）回退最高质量重编码。
    @MainActor
    public static func resolveVideoFile(assetIdentifier: String,
                                        progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        guard let asset = PhotoPickerResult(assetIdentifier: assetIdentifier).resolveAsset() else {
            throw BridgeError.assetNotFound(assetIdentifier)
        }
        do {
            let clip = try await PhotosClipResolver.video(
                asset: asset,
                options: .init(videoExportPreset: AVAssetExportPresetPassthrough),
                progress: progress
            )
            return clip.url
        } catch {
            let clip = try await PhotosClipResolver.video(asset: asset, progress: progress)
            return clip.url
        }
    }
}
