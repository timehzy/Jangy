import AVFoundation
import CoreMedia
import Foundation

/// 导出产物完整性校验。
///
/// 背景（上游 Kadr bug，v1.x 未修）：`CompositionBuilder` 无条件向 composition
/// 添加音频轨；当所有素材都无音频时该轨为空，而 AVFoundation 的
/// `AVAssetExportSession.compatibility(ofExportPreset:with:outputFileType:)`
/// 对含空轨的 composition 一律返回 false → `ExportEngine` 静默回退
/// `AVAssetExportPresetPassthrough`：不挂 videoComposition，preset 的分辨率/帧率/
/// 编码、转场、字幕烧录全部丢失，输出是原始码流拷贝（甚至多条视频轨），
/// 且导出流程"成功"。这里在导出后硬校验产物形状——宁可 loud failure，
/// 也不把 passthrough 垃圾当成功交付。
public enum ExportVerifier {

    public enum Failure: Error, Equatable {
        /// 疑似 passthrough：视频轨数量 / 分辨率 / 编码与 preset 不符。
        case passthroughSuspected(reason: String)
    }

    /// 校验导出产物与 preset 期望一致；不符则抛 `Failure.passthroughSuspected`。
    public static func verify(output url: URL, preset: OutputPreset) async throws {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        // passthrough 会原样拷贝转场用的双视频轨；正常渲染输出恒为单轨。
        guard videoTracks.count == 1 else {
            throw Failure.passthroughSuspected(
                reason: "输出含 \(videoTracks.count) 条视频轨（期望 1 条）——疑似 Kadr 静默 passthrough，转场/字幕/preset 均未应用"
            )
        }

        let track = videoTracks[0]
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let renderSize = naturalSize.applying(transform)
        let expected = preset.expectedResolution
        guard abs(abs(renderSize.width) - expected.width) <= 2,
              abs(abs(renderSize.height) - expected.height) <= 2 else {
            throw Failure.passthroughSuspected(
                reason: "输出分辨率 \(Int(abs(renderSize.width)))x\(Int(abs(renderSize.height))) ≠ preset 期望 \(Int(expected.width))x\(Int(expected.height))——疑似 Kadr 静默 passthrough"
            )
        }

        let codec = try await track.load(.formatDescriptions)
            .map { CMFormatDescriptionGetMediaSubType($0) }
            .first
        guard let codec, preset.expectedVideoCodecs.contains(codec) else {
            throw Failure.passthroughSuspected(
                reason: "输出编码 \(codec.map(fourCCString) ?? "未知") ≠ preset 期望 \(preset.expectedVideoCodecs.map(fourCCString))——疑似 Kadr 静默 passthrough"
            )
        }
    }

    static func fourCCString(_ code: FourCharCode) -> String {
        let chars: [UInt8] = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ]
        return String(bytes: chars, encoding: .ascii) ?? "0x\(String(code, radix: 16))"
    }

    static func fourCC(_ string: String) -> FourCharCode {
        string.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }
}

extension OutputPreset {
    /// 导出后校验用：渲染分辨率（与 Kadr.Preset 对齐）。
    /// 显式 switch：新增 OutputPreset case 时此处必须编译报错。
    var expectedResolution: CGSize {
        switch self {
        case .reelsAndShorts: return CGSize(width: 1080, height: 1920)
        }
    }

    /// 导出后校验用：期望的视频编码 FourCC（HEVC 允许 hvc1/hev1 两种封装）。
    var expectedVideoCodecs: [FourCharCode] {
        switch self {
        case .reelsAndShorts:
            return [ExportVerifier.fourCC("hvc1"), ExportVerifier.fourCC("hev1")]
        }
    }
}
