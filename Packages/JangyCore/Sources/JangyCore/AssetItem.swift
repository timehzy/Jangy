import Foundation

/// 素材类别。subtitle 指外挂字幕文件（POC 仅 SRT）。
public enum AssetKind: String, Codable, Sendable {
    case video, image, audio, subtitle
}

/// 素材来源渠道。导入渠道会持续增加（相册/文件 App/拍摄……），分析与管理按此区分。
public enum AssetOrigin: String, Codable, Sendable {
    case synthesized    // AssetSynthesizer 生成的测试素材
    case photoLibrary   // 系统相册导入
    case files          // 文件 App 导入 / CLI 喂入
}

/// 素材条目：工程内素材库的登记项。clip/字幕轨道一律用 `assetID` 引用它，
/// 不再直接引用文件名——素材的元数据（时长/分辨率/有无音频/来源）都挂在这里。
///
/// `fileName` 相对素材目录解析；以 "/" 开头视为绝对路径（CLI 喂任意素材、4K HDR 验证用）。
public struct AssetItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: AssetKind
    public var fileName: String
    public var displayName: String
    public var origin: AssetOrigin
    /// 素材实际时长（秒）。image 类素材为 nil；探测失败的视频也为 nil
    /// （此时 validator 不做 range 越界检查，错误留到引擎期抛出）。
    public var duration: TimeInterval?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// 是否自带音频轨。nil = 未探测（引擎层会即时探测兜底）。
    public var hasAudio: Bool?
    public var importedAt: Date?

    public init(id: UUID = UUID(), kind: AssetKind, fileName: String,
                displayName: String? = nil, origin: AssetOrigin = .files,
                duration: TimeInterval? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil,
                hasAudio: Bool? = nil, importedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.displayName = displayName ?? fileName
        self.origin = origin
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.hasAudio = hasAudio
        self.importedAt = importedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, fileName, displayName, origin, duration, pixelWidth, pixelHeight, hasAudio, importedAt
    }

    /// Agent 友好的宽容解码：仅 `kind`/`fileName` 必填，`id` 缺省随机生成，
    /// `displayName` 缺省回落 fileName，`origin` 缺省按 .files 处理。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(AssetKind.self, forKey: .kind)
        fileName = try container.decode(String.self, forKey: .fileName)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? fileName
        origin = try container.decodeIfPresent(AssetOrigin.self, forKey: .origin) ?? .files
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        pixelWidth = try container.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decodeIfPresent(Int.self, forKey: .pixelHeight)
        hasAudio = try container.decodeIfPresent(Bool.self, forKey: .hasAudio)
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt)
    }
}
