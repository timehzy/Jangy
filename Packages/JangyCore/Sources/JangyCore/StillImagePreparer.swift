import CoreGraphics
import Foundation
import ImageIO
#if canImport(AppKit)
import AppKit
/// 本文件不 import Kadr（硬边界规则：仅引擎适配层文件族 EngineBridge/PreviewBridge/ExportRunner 允许 import），
/// 因此不用 Kadr.PlatformImage，自行定义同义别名（macOS 下即 NSImage）。
typealias PreparedImage = NSImage
#elseif canImport(UIKit)
import UIKit
typealias PreparedImage = UIImage
#endif

/// 把图片文件准备成可直接喂 Kadr 的图片（与 `Kadr.PlatformImage` 同底层类型）。
///
/// 动机：Kadr 的 `ImageEncoder.createPixelBuffer` 把图片**直接拉伸**铺满 preset 画幅
/// （`context.draw(cgImage, in: 全画幅 rect)`），不保宽高比——实测 100×100 方图导出
/// 1080×1920 整帧填充。本类型先把图片等比 aspect-fit 居中贴到同画幅黑底画布上，
/// 之后 Kadr 的拉伸变为恒等缩放，变形消失。
///
/// 仅引擎适配层使用（L3）；画布尺寸 = `preset.resolution`。
enum StillImagePreparer {

    /// 图片文件 → 画布尺寸的 `PreparedImage`；不可解码返回 nil。
    static func prepare(url: URL, canvas: CGSize) -> PreparedImage? {
        prepareCGImage(url: url, canvas: canvas).map(preparedImage(from:))
    }

    /// 跨平台核心：等比 aspect-fit 居中贴到画布黑底，返回画布尺寸 CGImage。
    /// 测试直接驱动此入口（避开 PreparedImage 的 UIKit/AppKit 分叉）。
    static func prepareCGImage(url: URL, canvas: CGSize) -> CGImage? {
        let width = Int(canvas.width), height = Int(canvas.height)
        guard width > 0, height > 0,
              let cgImage = ImageDownsampler.downsample(url: url, maxPixel: max(width, height)),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            return nil
        }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let imageAspect = CGFloat(cgImage.width) / CGFloat(cgImage.height)
        let canvasAspect = canvas.width / canvas.height
        let drawRect: CGRect
        if imageAspect > canvasAspect {
            let h = canvas.width / imageAspect           // 图更宽：贴满宽，上下留黑
            drawRect = CGRect(x: 0, y: (canvas.height - h) / 2, width: canvas.width, height: h)
        } else {
            let w = canvas.height * imageAspect          // 图更高：贴满高，左右留黑
            drawRect = CGRect(x: (canvas.width - w) / 2, y: 0, width: w, height: canvas.height)
        }
        ctx.draw(cgImage, in: drawRect)
        return ctx.makeImage()
    }

    private static func preparedImage(from cgImage: CGImage) -> PreparedImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
}
