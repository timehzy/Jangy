import Foundation

/// 元素 payload 的值语义契约。实现者自带 `payloadType` 判别字符串，
/// 核心只读这个字符串查表分发，不认识任何具体 payload 类型。
public protocol TrackElementPayload: Codable, Equatable, Sendable {
    static var payloadType: String { get }
    /// 元素时长。有内容的元素时长由 payload 推出（gap 的时长自带）。
    var duration: TimeInterval { get }
}

/// type-erased payload box：JSON 形如 {"type":"clip", ...}。
public struct TrackPayload: Codable, Equatable, Sendable {
    public let payloadType: String
    public let value: any TrackElementPayload

    public init(_ value: any TrackElementPayload) {
        self.value = value
        self.payloadType = type(of: value).payloadType
    }

    public var duration: TimeInterval { value.duration }

    private struct TypeProbe: Decodable { let type: String }

    public init(from decoder: Decoder) throws {
        let probe = try TypeProbe(from: decoder)
        guard let codec = TrackFeatureRegistry.payloadCodecs[probe.type] else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "未注册的元素 payload 类型 '\(probe.type)'。已注册：\(TrackFeatureRegistry.payloadCodecs.keys.sorted().joined(separator: ", "))"))
        }
        self.payloadType = probe.type
        self.value = try codec.init(from: decoder)
    }

    private enum TypeKey: String, CodingKey { case type }

    public func encode(to encoder: Encoder) throws {
        // 判别字段 `type` 由 box 注入（具体 payload 只关心自己的字段），
        // 与 `init(from:)` 的 TypeProbe 对称：JSON 形如 {"type":"clip", ...}。
        var container = encoder.container(keyedBy: TypeKey.self)
        try container.encode(payloadType, forKey: .type)
        try value.encode(to: encoder)
    }

    public static func == (lhs: TrackPayload, rhs: TrackPayload) -> Bool {
        guard lhs.payloadType == rhs.payloadType,
              let other = rhs.value as? any Equatable else { return false }
        return Self.areEqual(lhs.value, other)
    }

    /// 同类型 payload 的相等比较：借 Codable 往返（`any Equatable` 的 `==` 需要同具体类型）。
    private static func areEqual(_ lhs: any TrackElementPayload, _ rhs: any Equatable) -> Bool {
        guard let rhsValue = rhs as? any TrackElementPayload else { return false }
        return lhs.isEqual(to: rhsValue)
    }
}

extension TrackElementPayload {
    /// 同具体类型的相等比较。默认实现直接比 `self == other`（同类型才成立）。
    func isEqual(to other: any TrackElementPayload) -> Bool {
        guard let other = other as? Self else { return false }
        return self == other
    }
}
