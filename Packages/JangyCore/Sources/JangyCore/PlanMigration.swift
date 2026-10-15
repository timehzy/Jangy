import Foundation

/// v3 及更早的 plan 形状。仅用于迁移读取，不参与 v4 编码。
struct LegacyPlanV3: Decodable {
    var version: Int?
    var assets: [AssetItem]
    var clips: [LegacyClipV3]
    var captions: LegacyCaptionTrackV3?
    var preset: OutputPreset?

    struct LegacyClipV3: Decodable {
        var id: UUID?
        var assetID: UUID
        var source: PlanClipSource?
        var range: ClosedRange<TimeInterval>?
        var speed: SpeedPlan?
        var transitionAfter: PlanTransition?
    }

    struct LegacyCaptionTrackV3: Decodable {
        var assetID: UUID
        var isEnabled: Bool?
        var style: LegacyCaptionStyleV3?

        struct LegacyCaptionStyleV3: Decodable {
            var fontSize: Double?
            var isBold: Bool?
        }
    }
}

/// 迁移期的数据问题。**必须能被调用方看见**——迁移是静默发生的，
/// 丢掉的字幕如果没人报，用户只会看到字幕莫名变少。
public enum MigrationNotice: Equatable, Sendable, CustomStringConvertible {
    /// 字幕来源文件读不出来（缺失 / 编码不支持）。字幕轨会留空。
    case captionSourceUnreadable(assetID: UUID)
    /// 字幕来源里有些块解析不出来，被跳过了。
    case captionBlocksSkipped(assetID: UUID, count: Int)
    /// 片段既没有 source 也没有旧 range，无法还原，已丢弃。
    case clipSourceMissing(clipID: UUID)

    public var description: String {
        switch self {
        case .captionSourceUnreadable(let id):
            return "字幕来源文件读不出来，字幕未迁移（素材 \(id.uuidString.prefix(8))）"
        case .captionBlocksSkipped(let id, let count):
            return "字幕有 \(count) 条无法解析、已跳过（素材 \(id.uuidString.prefix(8))）"
        case .clipSourceMissing(let id):
            return "片段 \(id.uuidString.prefix(8)) 缺少源区间，已丢弃"
        }
    }
}

/// 迁移产物：只含轨道与素材，不含 EditPlan（v4 的 EditPlan 由后续 Task 6 引入）。
struct MigratedPlanParts {
    var assets: [AssetItem]
    var tracks: [PlanTrack]
    var primaryTrackID: UUID
    var preset: OutputPreset
    /// 迁移期的问题。调用方（Task 6 的 ProjectStore / App）负责并进工程完整性报告，
    /// **不得静默丢弃**。
    var notices: [MigrationNotice] = []
}

/// v3 → v4：扁平 clips → 单主轨；整片 captions → 绝对定位字幕轨。
enum PlanMigration {

    static func migrate(_ legacy: LegacyPlanV3, assetsDirectory: URL?) -> MigratedPlanParts {
        var notices: [MigrationNotice] = []

        // 既没有 source 也没有旧 range 的片段无法还原源区间——丢弃并记 notice。
        // 旧实现会回落成 `.video(0...0)`（零长度畸形片段），静默造畸形数据比 fail-fast 更糟。
        let elements: [PlanElement] = legacy.clips.compactMap { clip in
            guard let source = clip.source ?? clip.range.map({ .video($0) }) else {
                notices.append(.clipSourceMissing(clipID: clip.id ?? UUID()))
                return nil
            }
            return PlanElement(id: clip.id ?? UUID(),
                               content: .content(TrackPayload(PlanClip(
                                   assetID: clip.assetID,
                                   source: source,
                                   speed: clip.speed ?? .flat(1.0),
                                   transitionAfter: clip.transitionAfter))))
        }

        let primary = PlanTrack(kind: .video, placement: .chained, elements: elements)

        var tracks = [primary]
        if let captions = legacy.captions {
            let caption = makeCaptionTrack(captions, assets: legacy.assets, assetsDirectory: assetsDirectory)
            tracks.append(caption.track)
            notices.append(contentsOf: caption.notices)
        }

        return MigratedPlanParts(assets: legacy.assets, tracks: tracks,
                                 primaryTrackID: primary.id, preset: legacy.preset ?? .reelsAndShorts,
                                 notices: notices)
    }

    /// SRT 可读时展开成 cue 元素；不可读时留空轨——settings 保留 sourceAssetID，
    /// 并把问题记进 notices 供调用方并进完整性报告，不静默丢。
    private static func makeCaptionTrack(_ legacy: LegacyPlanV3.LegacyCaptionTrackV3,
                                         assets: [AssetItem],
                                         assetsDirectory: URL?) -> (track: PlanTrack, notices: [MigrationNotice]) {
        let settings = CaptionTrackSettings(
            fontSize: legacy.style?.fontSize ?? 48,
            isBold: legacy.style?.isBold ?? true,
            isEnabled: legacy.isEnabled ?? true,
            sourceAssetID: legacy.assetID)

        var notices: [MigrationNotice] = []
        var elements: [PlanElement] = []

        if let assetsDirectory,
           let fileName = assets.first(where: { $0.id == legacy.assetID })?.fileName {
            let url = assetsDirectory.appendingPathComponent(fileName)
            // 与旧路径（KadrCaptions 的 Caption.load(srt:)）保持一致的编码回落：
            // UTF-8 读不出时试 windowsCP1252。不这么做就是行为倒退——
            // 旧路径从不会因为编码问题静默产出零条 cue。
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8)
                   ?? String(data: data, encoding: .windowsCP1252) {
                let parsed = SRTParser.parse(text)
                elements = parsed.cues.map { cue in
                    PlanElement(at: cue.start,
                                content: .content(TrackPayload(
                                    CaptionCuePayload(text: cue.text, duration: cue.duration))))
                }
                if parsed.skippedBlocks > 0 {
                    notices.append(.captionBlocksSkipped(assetID: legacy.assetID,
                                                         count: parsed.skippedBlocks))
                }
            } else {
                notices.append(.captionSourceUnreadable(assetID: legacy.assetID))
            }
        }
        // assetsDirectory 为 nil 是调用方没给素材目录（不是数据问题），不报 notice

        let track = PlanTrack(kind: .caption, placement: .absolute,
                              settings: TrackPayload(settings), elements: elements)
        return (track, notices)
    }
}
