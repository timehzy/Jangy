import Foundation

/// 元素在成片画布上的布局变换（归一化坐标）。元素 `transform == nil` 表示全屏（恒等）。
/// 与 Kadr `Transform` 语义对齐但独立定义——L2 不能 import Kadr（公约 §1）。
///
/// **Kadr 的 `scale` 是均匀缩放**（`Double`，非 `CGSize`），故「半屏」= 整体缩到 0.5
/// （宽高各半、垂直居中）——呈现为「两块半尺寸画面左右并排 + 上下黑边」，
/// 不是边到边的裁切式分屏。旋转 / 锚点留 backlog（Kadr 支持，本期不用）。
///
/// 前提：`scale` 作用在 aspect-fill 后、裁切前的内容上，只有素材宽高比不宽于画布时
/// 「缩到 0.5」才等于「画面缩到半尺寸」。横屏素材放进竖屏画布时会被撑满宽度，缩 0.5
/// 后仍是满宽横带（左右并排会叠死）——此边界记入 backlog。
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
    /// 左半屏：缩到 0.5、中心在画布左侧 1/4。
    public static let leftHalf = ClipTransform(centerX: 0.25, centerY: 0.5, scale: 0.5)
    /// 右半屏。
    public static let rightHalf = ClipTransform(centerX: 0.75, centerY: 0.5, scale: 0.5)
}
