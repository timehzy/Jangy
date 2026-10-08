import CoreGraphics
import Foundation
#if canImport(AppKit)
import AppKit
/// 本文件不 import Kadr（硬边界规则：仅引擎适配层文件族 EngineBridge/PreviewBridge/ExportRunner 允许 import），
/// 因此不用 Kadr.PlatformImage，自行定义同义别名（macOS 下即 NSImage）。
public typealias CaptionImage = NSImage
#elseif canImport(UIKit)
import UIKit
public typealias CaptionImage = UIImage
#endif

/// 把字幕文本预渲染成图片。
///
/// 为什么不用 Kadr 的 `TextOverlay`（CATextLayer）：
/// 实测在本环境（macOS 26，无 WindowServer 的 CLI/测试进程）下，
/// `AVVideoCompositionCoreAnimationTool` 导出的 layer 树里 **CATextLayer 一律不绘制文字**
/// （纯色 CALayer、CGImage contents 都正常；CATextLayer 换 font/CTFont/NSAttributedString
/// 全部空白）。这是平台层限制，非 Kadr 配置问题。因此字幕改走
/// `ImageOverlay`（预渲染 CGImage），同样的位置/可见窗口语义，导出一律可见。
/// 附带好处：烧录结果与字体栅格化完全由我们控制，跨机器可复现。
public enum CaptionImageRenderer {

    /// 渲染样式（与 CaptionStyle 对齐）：白字、可选粗体、半透明黑底圆角条。
    public static func render(_ text: String, fontSize: Double, isBold: Bool) -> CaptionImage {
        #if canImport(AppKit)
        return renderAppKit(text, fontSize: fontSize, isBold: isBold)
        #else
        return renderUIKit(text, fontSize: fontSize, isBold: isBold)
        #endif
    }

    #if canImport(AppKit)
    private static func renderAppKit(_ text: String, fontSize: Double, isBold: Bool) -> NSImage {
        let font = NSFont.systemFont(ofSize: fontSize, weight: isBold ? .bold : .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ])
        let paddingH: CGFloat = 28
        let paddingV: CGFloat = 14
        let textSize = attributed.size()
        let imageSize = CGSize(width: ceil(textSize.width) + paddingH * 2,
                               height: ceil(textSize.height) + paddingV * 2)
        return NSImage(size: imageSize, flipped: false) { rect in
            // 半透明底条，保证亮色画面上字幕可读
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            attributed.draw(in: CGRect(x: paddingH, y: paddingV,
                                       width: textSize.width, height: textSize.height))
            return true
        }
    }
    #else
    private static func renderUIKit(_ text: String, fontSize: Double, isBold: Bool) -> UIImage {
        let font = UIFont.systemFont(ofSize: fontSize, weight: isBold ? .bold : .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
        ])
        let paddingH: CGFloat = 28
        let paddingV: CGFloat = 14
        let textSize = attributed.size()
        let imageSize = CGSize(width: ceil(textSize.width) + paddingH * 2,
                               height: ceil(textSize.height) + paddingV * 2)
        let renderer = UIGraphicsImageRenderer(size: imageSize)
        return renderer.image { _ in
            UIColor.black.withAlphaComponent(0.45).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: imageSize), cornerRadius: 12).fill()
            attributed.draw(in: CGRect(x: paddingH, y: paddingV,
                                       width: textSize.width, height: textSize.height))
        }
    }
    #endif
}
