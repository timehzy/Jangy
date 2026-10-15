import CoreGraphics
import Foundation
import ImageIO

/// ImageIO 降采样：不加载全尺寸像素进内存（大图也不爆）。图片相关的 L3 工具共用。
enum ImageDownsampler {
    static func downsample(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 应用 EXIF 方向
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
