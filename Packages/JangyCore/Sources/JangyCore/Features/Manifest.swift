import Foundation

/// 特性清单 —— 全仓库唯一的注册点。加一类轨 = 这里加一行 + 新增一个 Features/<Name>/ 目录。
/// 静态装配（不依赖 App 启动）：`jangy-cli agent` 是 headless 跑的，
/// 若编解码器由 App 注册，CLI 解码带新轨类型的 plan 会直接失败。
public enum TrackFeatureRegistry {

    /// 生产特性清单。计算属性：无共享可变状态，因此不需要 nonisolated(unsafe) 豁免。
    /// 加一类轨 = 这里加一行（如 `VideoFeature.self`）。
    public static var features: [any TrackFeature.Type] {
        [
            VideoFeature.self,
        ]
    }

    /// 测试注入点：可插拔性验收用（后续任务）。生产路径永不写入。
    /// internal：仅 `@testable import` 可见，不进生产 API 面（可变全局不该暴露）。
    nonisolated(unsafe) static var testOnlyFeatures: [any TrackFeature.Type] = []

    public static var allFeatures: [any TrackFeature.Type] { features + testOnlyFeatures }

    /// payloadType 字符串 → 编解码器。计算属性而非缓存：测试注入后立即生效。
    public static var payloadCodecs: [String: any TrackElementPayload.Type] {
        var table: [String: any TrackElementPayload.Type] = [:]
        for feature in allFeatures {
            for type in feature.payloadTypes {
                table[type.payloadType] = type
            }
        }
        return table
    }

    public static func feature(for kind: TrackKind) -> (any TrackFeature.Type)? {
        allFeatures.first { $0.kind == kind }
    }
}
