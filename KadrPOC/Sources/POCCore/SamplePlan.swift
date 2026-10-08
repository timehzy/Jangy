import Foundation

/// 内置演示工程：三段素材 + 转场 + 变速 + 字幕，覆盖 POC 五个关键字。
/// 固定 UUID 保证黄金 JSON 契约可比对。
public enum SamplePlan {
    public static func make() -> EditPlan {
        EditPlan(
            clips: [
                PlanClip(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                         source: MediaRef(fileName: "clip1.mp4"),
                         range: 0...3, speed: .flat(1.0),
                         transitionAfter: .dissolve(duration: 0.5)),
                PlanClip(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                         source: MediaRef(fileName: "clip2.mp4"),
                         range: 0...3, speed: .flat(0.5),
                         transitionAfter: nil),
                PlanClip(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                         source: MediaRef(fileName: "clip3.mp4"),
                         range: 0...2, speed: .flat(2.0),
                         transitionAfter: nil),
            ],
            captions: CaptionTrack(source: MediaRef(fileName: "sample.srt"),
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
