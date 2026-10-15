import Foundation

/// 轨道类型：开放类型（包 String），核心不 switch 它。
/// 核心能说「这条轨是链式的」，说不出「这条轨是音乐」——具体轨类型由特性模块解释。
public struct TrackKind: Codable, Equatable, Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let video = TrackKind(rawValue: "video")
    public static let caption = TrackKind(rawValue: "caption")
}
