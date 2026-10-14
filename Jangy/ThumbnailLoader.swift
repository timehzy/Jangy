import AVFoundation
import ImageIO
import UIKit
import JangyCore

/// 素材缩略图：视频抽首帧、图片降采样；NSCache 按 assetID 缓存。
enum ThumbnailLoader {
    private static let cache = NSCache<NSUUID, UIImage>()

    static func load(item: AssetItem, resolver: AssetResolver) async -> UIImage? {
        if let cached = cache.object(forKey: item.id as NSUUID) { return cached }
        let url = resolver.resolve(item)
        let image: UIImage?
        switch item.kind {
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            image = (try? await generator.image(at: .zero).image).map { UIImage(cgImage: $0) }
        case .image:
            image = downsample(url: url, maxPixel: 240)
        default:
            image = nil
        }
        if let image { cache.setObject(image, forKey: item.id as NSUUID) }
        return image
    }

    /// ImageIO 降采样：不加载全尺寸像素进内存。
    private static func downsample(url: URL, maxPixel: Int) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
