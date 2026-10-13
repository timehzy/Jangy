import Foundation

/// 导出配置：导出面板（App）与 CLI 共用同一份选项模型。
/// 纯 Swift 状态层类型，不依赖引擎；结构体形态为后续导出选项
/// （分辨率/码率档位、水印等）预留扩展——新选项作为字段追加，面板同步加控件。
public struct ExportOptions: Codable, Equatable, Sendable {

    /// HDR 直通（默认开）：导出保留 BT.2020 + HLG 元数据（HEVC 编码），
    /// 即「HDR 全链路」特性（roadmap 2026-10-09 定论）。
    /// 关闭 → SDR 降级：分辨率/帧率不变，编码换 H.264，由 AVAssetExportSession
    /// 自动色调映射到 BT.709（POC 验证点③已验证该路径色调正确），
    /// 解决分享到不支持 HDR 平台的发灰问题。
    public var hdrPassthrough: Bool

    public init(hdrPassthrough: Bool = true) {
        self.hdrPassthrough = hdrPassthrough
    }

    /// 默认配置：HDR 直通。
    public static let `default` = ExportOptions()
}
