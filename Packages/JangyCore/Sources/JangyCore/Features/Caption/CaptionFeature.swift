import Foundation

/// 字幕轨的元素 payload：一条 cue。
/// v1 不做逐句样式——样式是轨级的，放 CaptionTrackSettings。
/// **位置以 PlanElement.at 为权威**，payload 里不存 start（避免两个事实源）。
public struct CaptionCuePayload: Codable, Equatable, Sendable, TrackElementPayload {
    public static let payloadType = "caption-cue"

    public var text: String
    public var duration: TimeInterval

    public init(text: String, duration: TimeInterval) {
        self.text = text
        self.duration = duration
    }

    private enum CodingKeys: String, CodingKey { case text, duration }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
    }

    /// `type` 由 TrackPayload box 注入，这里只写自己的字段。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(duration, forKey: .duration)
    }
}

/// 字幕轨的轨级参数（原 CaptionTrack + CaptionStyle 的合体）。
public struct CaptionTrackSettings: Codable, Equatable, Sendable, TrackElementPayload {
    public static let payloadType = "caption-settings"

    public var fontSize: Double
    public var isBold: Bool
    public var isEnabled: Bool
    /// 字幕来源文件（登记表里的 .srt）。SRT 已退化为导入源，这里只为维持素材引用保护。
    public var sourceAssetID: UUID?

    public init(fontSize: Double = 48, isBold: Bool = true,
                isEnabled: Bool = true, sourceAssetID: UUID? = nil) {
        self.fontSize = fontSize
        self.isBold = isBold
        self.isEnabled = isEnabled
        self.sourceAssetID = sourceAssetID
    }

    /// 轨级参数不参与时间线。
    public var duration: TimeInterval { 0 }

    private enum CodingKeys: String, CodingKey {
        case fontSize, isBold, isEnabled, sourceAssetID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 48
        isBold = try container.decodeIfPresent(Bool.self, forKey: .isBold) ?? true
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        sourceAssetID = try container.decodeIfPresent(UUID.self, forKey: .sourceAssetID)
    }

    /// `type` 由 TrackPayload box 注入，这里只写自己的字段。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(isBold, forKey: .isBold)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(sourceAssetID, forKey: .sourceAssetID)
    }
}

/// 字幕轨特性（L2 片）。L3 引擎映射见同目录 CaptionEngine.swift。
public enum CaptionFeature: TrackFeature {
    public static let kind = TrackKind.caption
    public static let payloadTypes: [any TrackElementPayload.Type] = [
        CaptionCuePayload.self, CaptionTrackSettings.self,
    ]

    /// 轨级设置。settings 缺失或类型不对时回落默认值。
    public static func settings(of track: PlanTrack) -> CaptionTrackSettings {
        (track.settings?.value as? CaptionTrackSettings) ?? CaptionTrackSettings()
    }

    public static func validate(track: PlanTrack, context: TrackValidationContext) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let prefix = context.pathPrefix(for: track)

        if track.placement != .absolute {
            issues.append(ValidationIssue(path: "\(prefix).placement",
                                          message: "字幕轨必须是绝对定位（.absolute）"))
        }

        for (i, element) in track.elements.enumerated() {
            let path = "\(prefix).elements[\(i)]"
            guard let at = element.at else {
                issues.append(ValidationIssue(path: "\(path).at", elementID: element.id,
                                              message: "绝对定位轨的元素必须带 at"))
                continue
            }
            if at < 0 {
                issues.append(ValidationIssue(path: "\(path).at", elementID: element.id,
                                              message: "字幕起点不能为负"))
            }
            if element.duration <= 0 {
                issues.append(ValidationIssue(path: "\(path)", elementID: element.id,
                                              message: "字幕时长必须为正"))
            }
            if at + element.duration > context.mainTrackEnd + EditPlanValidator.durationTolerance {
                issues.append(ValidationIssue(path: "\(path).at", elementID: element.id,
                                              message: "字幕超出主轨末端（主轨 \(context.mainTrackEnd)s）"))
            }
        }

        if let sourceID = settings(of: track).sourceAssetID {
            switch context.asset(withID: sourceID) {
            case nil:
                issues.append(ValidationIssue(path: "\(prefix).settings.sourceAssetID",
                                              message: "引用了未登记的字幕素材: \(sourceID)"))
            case let asset? where asset.kind != .subtitle:
                issues.append(ValidationIssue(path: "\(prefix).settings.sourceAssetID",
                                              message: "字幕来源必须是字幕素材，实际为 \(asset.kind.rawValue)"))
            default:
                break
            }
        }

        return issues
    }
}
