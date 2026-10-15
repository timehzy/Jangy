import AVFoundation
import CoreGraphics
import Foundation
import Kadr

/// 视频轨特性（L3 片）：叠加视频轨 → Kadr.Track。
/// 主轨的映射在 EngineBridge 内联（它要跟转场交错构建，且必须是顶层链式 clip）；
/// 本文件只管非主轨的视频轨。
public enum VideoEngine {

    /// 叠加视频轨 → **每个元素一个** `Kadr.Track(at:)`。
    ///
    /// 为什么不是「一个 Track 装全部元素」：`Kadr.Track { }` 内部是 track-relative 隐式链，
    /// 内部元素的 `.at(time:)` **被忽略**（Track 的 `.at` 才是锚点，见 Kadr `Track.swift`）。
    /// 叠加轨要的是绝对定位，所以把每个元素各自包进一个锚在 `element.at` 的 Track——
    /// 一个元素 = 一个并行子时间线 = 一条独立 video track。
    ///
    /// 声明顺序 = 绘制顺序（后面的盖前面的），故返回数组的顺序即元素顺序。
    static func makeParallelTracks(track: PlanTrack, plan: EditPlan,
                                   resolver: AssetResolver,
                                   preset: Kadr.Preset) async throws -> [Kadr.Track] {
        var tracks: [Kadr.Track] = []

        for element in track.elements {
            let clip: any Kadr.Clip
            switch element.content {
            case .gap(let duration):
                clip = Kadr.ImageClip.color(PlatformColor.black, duration: duration)

            case .content(let payload):
                guard let planClip = payload.value as? PlanClip else {
                    throw EngineBridge.UnknownPayloadError(kind: track.kind,
                                                           payloadType: payload.payloadType)
                }
                guard let asset = plan.asset(withID: planClip.assetID) else {
                    throw EngineBridge.MissingAssetError(assetID: planClip.assetID)
                }
                let url = resolver.resolve(asset)

                switch planClip.source {
                case .still(let duration):
                    guard let image = StillImagePreparer.prepare(url: url, canvas: preset.resolution) else {
                        throw EngineBridge.ImageDecodeError(assetID: planClip.assetID)
                    }
                    var imageClip = Kadr.ImageClip(image, duration: duration / planClip.speed.rate)
                    if let t = planClip.transform {
                        imageClip = imageClip.transform(t.kadrTransform).opacity(t.opacity)
                    }
                    clip = imageClip

                case .video(let range):
                    var videoClip = Kadr.VideoClip(url: url).trimmed(to: range)
                    if planClip.speed.rate != 1.0 {
                        videoClip = videoClip.speed(.flat(planClip.speed.rate))
                    }
                    if let t = planClip.transform {
                        videoClip = videoClip.transform(t.kadrTransform).opacity(t.opacity)
                    }
                    clip = videoClip
                }
            }

            // 锚点 = 元素绝对起点（.absolute 轨语义）。链式轨不该走到这里。
            let start = element.at ?? 0
            tracks.append(Kadr.Track(at: start, name: track.name) { clip })
        }

        return tracks
    }
}
