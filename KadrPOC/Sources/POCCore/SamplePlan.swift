import Foundation

/// 内置演示工程：素材登记表（3 段合成视频 + 1 份字幕）+ 转场 + 变速 + 字幕，覆盖 POC 五个关键字。
/// 固定 UUID 保证黄金 JSON 契约可比对。
public enum SamplePlan {
    /// 登记表条目的固定 ID：clip1/clip2/clip3/sample.srt
    public static let assetID1 = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
    public static let assetID2 = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000002")!
    public static let assetID3 = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000003")!
    public static let captionAssetID = UUID(uuidString: "aaaaaaaa-0000-0000-0000-0000000000f1")!

    public static func make() -> EditPlan {
        EditPlan(
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
            clips: [
                PlanClip(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                         assetID: assetID1,
                         range: 0...3, speed: .flat(1.0),
                         transitionAfter: .dissolve(duration: 0.5)),
                PlanClip(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                         assetID: assetID2,
                         range: 0...3, speed: .flat(0.5),
                         transitionAfter: nil),
                PlanClip(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                         assetID: assetID3,
                         range: 0...2, speed: .flat(2.0),
                         transitionAfter: nil),
            ],
            captions: CaptionTrack(assetID: captionAssetID,
                                   isEnabled: true,
                                   style: CaptionStyle(fontSize: 48, isBold: true)),
            preset: .reelsAndShorts
        )
    }

    /// CLI `sample` 子命令的输出，与 EditStore.json() 同一格式。
    public static func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(SamplePlan.make()), as: UTF8.self)
    }
}
