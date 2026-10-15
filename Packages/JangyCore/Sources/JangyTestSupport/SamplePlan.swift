import Foundation
import JangyCore

/// 内置演示工程：素材登记表（3 段合成视频 + 1 份字幕）+ 转场 + 变速 + 字幕，覆盖 POC 五个关键字。
/// 固定 UUID 保证黄金 JSON 契约可比对。仅测试与 CLI 使用（JangyTestSupport），不进 App 产物。
public enum SamplePlan {
    /// 登记表条目的固定 ID：clip1/clip2/clip3/sample.srt
    public static let assetID1 = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
    public static let assetID2 = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000002")!
    public static let assetID3 = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000003")!
    public static let captionAssetID = UUID(uuidString: "aaaaaaaa-0000-0000-0000-0000000000f1")!

    public static func make() -> EditPlan {
        let primary = PlanTrack(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                                kind: .video, placement: .chained, elements: [
            PlanElement(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                        content: .content(TrackPayload(PlanClip(
                            assetID: assetID1, source: .video(0...3), speed: .flat(1.0),
                            transitionAfter: .dissolve(duration: 0.5))))),
            PlanElement(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                        content: .content(TrackPayload(PlanClip(
                            assetID: assetID2, source: .video(0...3), speed: .flat(0.5))))),
            PlanElement(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                        content: .content(TrackPayload(PlanClip(
                            assetID: assetID3, source: .video(0...2), speed: .flat(2.0))))),
        ])

        let captionTrack = PlanTrack(id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                                     kind: .caption, placement: .absolute,
                                     settings: TrackPayload(CaptionTrackSettings(
                                        fontSize: 48, isBold: true, isEnabled: true,
                                        sourceAssetID: captionAssetID)),
                                     elements: captionElements())

        return EditPlan(
            assets: [
                // 与 AssetSynthesizer 产物一致：4 秒 1280x720 H.264 无音频
                AssetItem(id: assetID1, kind: .video, fileName: "clip1.mp4",
                          origin: .synthesized, duration: 4.0, pixelWidth: 1280, pixelHeight: 720, hasAudio: false),
                AssetItem(id: assetID2, kind: .video, fileName: "clip2.mp4",
                          origin: .synthesized, duration: 4.0, pixelWidth: 1280, pixelHeight: 720, hasAudio: false),
                AssetItem(id: assetID3, kind: .video, fileName: "clip3.mp4",
                          origin: .synthesized, duration: 4.0, pixelWidth: 1280, pixelHeight: 720, hasAudio: false),
                AssetItem(id: captionAssetID, kind: .subtitle, fileName: "sample.srt",
                          origin: .synthesized),
            ],
            tracks: [primary, captionTrack], primaryTrackID: primary.id)
    }

    /// 与 `AssetSynthesizer.srtContent` **逐字一一对应**（3 条 cue）：
    /// 0–2.5「第一段：开场」/ 3.0–7.5「第二段：慢动作」/ 8.0–9.0「第三段：收尾」。
    /// **必须与 srtContent 完全一致**——`ExportEndToEndTests` 的像素断言锚在
    /// 「t=1.0 有字幕、t=2.8 无字幕」上（2.8 落在 cue1 结束 2.5 与 cue2 开始 3.0 之间）。
    private static func captionElements() -> [PlanElement] {
        [
            PlanElement(id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
                        at: 0, content: .content(TrackPayload(
                            CaptionCuePayload(text: "第一段：开场", duration: 2.5)))),
            PlanElement(id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
                        at: 3.0, content: .content(TrackPayload(
                            CaptionCuePayload(text: "第二段：慢动作", duration: 4.5)))),
            PlanElement(id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
                        at: 8.0, content: .content(TrackPayload(
                            CaptionCuePayload(text: "第三段：收尾", duration: 1.0)))),
        ]
    }

    /// CLI `sample` 子命令的输出，与 EditStore.json() 同一格式。
    public static func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(SamplePlan.make()), as: UTF8.self)
    }
}
