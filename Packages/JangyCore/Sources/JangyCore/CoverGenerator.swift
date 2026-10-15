import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 项目封面：第一片段素材的首帧 JPEG，缓存到 Projects/<id>/cover.jpg。
/// 失败静默（封面是锦上添花，不阻断任何流程）；空时间线清掉旧封面。
public enum CoverGenerator {
    public static func generate(for plan: EditPlan, resolver: AssetResolver, to url: URL) async {
        let fm = FileManager.default
        guard let first = plan.primaryTrack?.elements.first,
              case .content(let payload) = first.content,
              let clip = payload.value as? PlanClip,
              let asset = plan.asset(withID: clip.assetID),
              resolver.exists(asset) else {
            try? fm.removeItem(at: url)
            return
        }
        let sourceURL = resolver.resolve(asset)
        let cgImage: CGImage?
        switch asset.kind {
        case .image:
            // 图片：ImageIO 降采样（不走 AVAssetImageGenerator——它只对视频有效）
            cgImage = ImageDownsampler.downsample(url: sourceURL, maxPixel: 640)
        default:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: sourceURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            cgImage = try? await generator.image(at: .zero).image
        }
        guard let cgImage, let data = jpegData(of: cgImage, quality: 0.8) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// CGImage → JPEG。走 ImageIO 而非 UIKit/AppKit：JangyCore 同时声明
    /// iOS/macOS 平台，swift test 在 macOS 上构建，直接 import UIKit 编不过。
    private static func jpegData(of image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
