import CoreGraphics
import Foundation

/// 元素在成片画布上的布局变换（归一化坐标）。元素 `transform == nil` 表示全屏（恒等）。
/// 与 Kadr `Transform` 语义对齐但独立定义——L2 不能 import Kadr（公约 §1）。
///
/// **Kadr 的 `scale` 是均匀缩放**（`Double`，非 `CGSize`），且作用在 aspect-fill 之后、
/// 裁切之前的内容上。所以「半屏」不是恒定的 0.5——要得到半宽块得按素材宽高比换算
/// `scale`（见 `halfScreen(...)`）。旋转 / 锚点留 backlog（Kadr 支持，本期不用）。
public struct ClipTransform: Codable, Equatable, Sendable {
    /// 画布上的归一化中心（0...1，原点左上）。
    public var centerX: Double
    public var centerY: Double
    /// 均匀缩放（1 = 铺满画布）。
    public var scale: Double
    /// 不透明度（0...1）。
    public var opacity: Double

    public init(centerX: Double = 0.5, centerY: Double = 0.5,
                scale: Double = 1, opacity: Double = 1) {
        self.centerX = centerX
        self.centerY = centerY
        self.scale = scale
        self.opacity = opacity
    }

    public static let fullScreen = ClipTransform()
}

extension ClipTransform {
    public enum Half: Sendable { case left, right }

    /// 左右分屏：元素等比缩放到**画布一半宽**、垂直居中，落在指定一侧。
    ///
    /// 素材先按「铺满画布」（aspect-fill）落到画布，Kadr 的 transform 作用于**这之后**——
    /// 所以要得到「半宽块」，scale = 0.5 × 画布宽 / 填充后内容宽，而**不是**恒定的 0.5。
    /// （横屏素材填充后远宽于画布，恒定 0.5 会得到整幅宽色带而非半屏列——见 known-pitfalls。）
    public static func halfScreen(sourceSize: CGSize, canvasSize: CGSize, side: Half) -> ClipTransform {
        guard sourceSize.width > 0, sourceSize.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return .fullScreen }
        let fill = max(canvasSize.width / sourceSize.width, canvasSize.height / sourceSize.height)
        let filledWidth = sourceSize.width * fill
        let scale = 0.5 * canvasSize.width / filledWidth
        return ClipTransform(centerX: side == .left ? 0.25 : 0.75, centerY: 0.5, scale: scale)
    }

    /// 由素材与预设直接算分屏预设（调用方拿得到 asset + plan.preset 时用这个）。
    /// 图片先经 StillImagePreparer 预合成到画布（等比 letterbox），故其填充后尺寸就是画布本身。
    public static func halfScreen(for asset: AssetItem, preset: OutputPreset, side: Half) -> ClipTransform {
        let canvas = preset.renderSize
        let sourceSize: CGSize
        switch asset.kind {
        case .image:
            sourceSize = canvas
        default:
            sourceSize = CGSize(width: Double(asset.pixelWidth ?? Int(canvas.width)),
                                height: Double(asset.pixelHeight ?? Int(canvas.height)))
        }
        return halfScreen(sourceSize: sourceSize, canvasSize: canvas, side: side)
    }
}
