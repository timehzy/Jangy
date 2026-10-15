import Foundation

/// 元素定位方式：结构属性（核心认识），不是类型属性。
/// - chained：位置由数组顺序推出，元素不带 at（主轨）
/// - absolute：每个元素自带 at（叠加轨 / 字幕轨）
public enum TrackPlacement: String, Codable, Sendable {
    case chained
    case absolute
}
