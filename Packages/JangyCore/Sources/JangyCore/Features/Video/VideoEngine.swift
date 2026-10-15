import AVFoundation
import CoreGraphics
import Foundation
import Kadr

/// 视频轨特性（L3 片）：叠加视频轨 → Kadr.Track。
/// 主轨的映射在 EngineBridge 内联（它要跟转场交错构建，且必须是顶层链式 clip）；
/// 本文件只管非主轨的视频轨。
public enum VideoEngine {

    /// 叠加视频轨 → 一个并行子时间线。
    /// 元素用 `.at(time:)` 绝对定位（与 .absolute 轨语义一致）；
    /// Track 的声明顺序 = 绘制顺序（后面的盖前面的）。
    static func makeParallelTrack(track: PlanTrack, plan: EditPlan,
                                  resolver: AssetResolver,
                                  preset: Kadr.Preset) async throws -> Kadr.Track {
        var elements: [any Kadr.Clip] = []

        for element in track.elements {
            let start = element.at ?? 0
            switch element.content {
            case .gap(let duration):
                elements.append(Kadr.ImageClip.color(PlatformColor.black, duration: duration)
                    .at(time: start))

            case .content(let payload):
                guard let clip = payload.value as? PlanClip else {
                    throw EngineBridge.UnknownPayloadError(kind: track.kind,
                                                           payloadType: payload.payloadType)
                }
                guard let asset = plan.asset(withID: clip.assetID) else {
                    throw EngineBridge.MissingAssetError(assetID: clip.assetID)
                }
                let url = resolver.resolve(asset)

                switch clip.source {
                case .still(let duration):
                    guard let image = StillImagePreparer.prepare(url: url, canvas: preset.resolution) else {
                        throw EngineBridge.ImageDecodeError(assetID: clip.assetID)
                    }
                    elements.append(Kadr.ImageClip(image, duration: duration / clip.speed.rate)
                        .at(time: start))

                case .video(let range):
                    var videoClip = Kadr.VideoClip(url: url).trimmed(to: range)
                    if clip.speed.rate != 1.0 {
                        videoClip = videoClip.speed(.flat(clip.speed.rate))
                    }
                    elements.append(videoClip.at(time: start))
                }
            }
        }

        return Kadr.Track(name: track.name) {
            for element in elements { element }
        }
    }
}
