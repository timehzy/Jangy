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

/// 迁移产物：只含轨道与素材，不含 EditPlan（v4 的 EditPlan 由后续 Task 6 引入）。
struct MigratedPlanParts {
    var assets: [AssetItem]
    var tracks: [PlanTrack]
    var primaryTrackID: UUID
    var preset: OutputPreset
}

/// v3 → v4：扁平 clips → 单主轨；整片 captions → 绝对定位字幕轨。
enum PlanMigration {

    static func migrate(_ legacy: LegacyPlanV3, assetsDirectory: URL?) -> MigratedPlanParts {
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: legacy.clips.map { clip in
            PlanElement(id: clip.id ?? UUID(),
                        content: .content(TrackPayload(PlanClip(
                            assetID: clip.assetID,
                            source: clip.source ?? clip.range.map { .video($0) } ?? .video(0...0),
                            speed: clip.speed ?? .flat(1.0),
                            transitionAfter: clip.transitionAfter))))
        })

        var tracks = [primary]
        if let captions = legacy.captions {
            tracks.append(makeCaptionTrack(captions, assets: legacy.assets, assetsDirectory: assetsDirectory))
        }

        return MigratedPlanParts(assets: legacy.assets, tracks: tracks,
                                 primaryTrackID: primary.id, preset: legacy.preset ?? .reelsAndShorts)
    }

    /// SRT 可读时展开成 cue 元素；不可读时留空轨——settings 保留 sourceAssetID，
    /// 工程完整性报告会显式提示，不静默丢。
    private static func makeCaptionTrack(_ legacy: LegacyPlanV3.LegacyCaptionTrackV3,
                                         assets: [AssetItem],
                                         assetsDirectory: URL?) -> PlanTrack {
        let settings = CaptionTrackSettings(
            fontSize: legacy.style?.fontSize ?? 48,
            isBold: legacy.style?.isBold ?? true,
            isEnabled: legacy.isEnabled ?? true,
            sourceAssetID: legacy.assetID)

        var elements: [PlanElement] = []
        if let assetsDirectory,
           let fileName = assets.first(where: { $0.id == legacy.assetID })?.fileName,
           let text = try? String(contentsOf: assetsDirectory.appendingPathComponent(fileName),
                                  encoding: .utf8) {
            elements = SRTParser.parse(text).cues.map { cue in
                PlanElement(at: cue.start,
                            content: .content(TrackPayload(
                                CaptionCuePayload(text: cue.text, duration: cue.duration))))
            }
        }

        return PlanTrack(kind: .caption, placement: .absolute,
                         settings: TrackPayload(settings), elements: elements)
    }
}
