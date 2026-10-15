import Foundation

/// 校验问题：path 指向 JSON 字段路径（如 "clips[1].speed"），Agent/人都可读。
public struct ValidationIssue: Equatable, Sendable, Codable, CustomStringConvertible {
    public let path: String
    public let message: String
    /// 出问题的元素 ID（可定位时）。Agent 用它做位置无关的引用——
    /// 下标会随 plan 变动漂移，ID 不会。
    public let elementID: UUID?

    public init(path: String, elementID: UUID? = nil, message: String) {
        self.path = path
        self.elementID = elementID
        self.message = message
    }

    public var description: String { "\(path): \(message)" }
}

/// apply/导出前校验的失败载体：聚合全部问题，CLI 可直接 JSON 序列化给 Agent。
public struct ValidationFailure: Error, Equatable, Sendable, Codable {
    public let issues: [ValidationIssue]

    public init(issues: [ValidationIssue]) { self.issues = issues }
}

/// 结构校验（纯函数，无 IO）与素材存在性校验（有 IO）分离：
/// EditStore.apply 只跑前者；CLI validate / 导出前两者都跑。
public struct EditPlanValidator: Sendable {

    public static let speedRange: ClosedRange<Double> = 0.25...4.0
    /// range 终点与素材时长的比对容差（秒）：时长探测与区间取值存在毫秒级口径差。
    public static let durationTolerance: TimeInterval = 0.05

    public init() {}

    public func validate(_ plan: EditPlan) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        // 登记表自身一致性：ID 唯一
        var seen: Set<UUID> = []
        for (i, asset) in plan.assets.enumerated() {
            if !seen.insert(asset.id).inserted {
                issues.append(ValidationIssue(path: "assets[\(i)].id", message: "素材 ID 重复: \(asset.id)"))
            }
        }

        // 轨道自身一致性：ID 唯一；kind 必须有注册的特性模块
        var trackIDs: Set<UUID> = []
        for (i, track) in plan.tracks.enumerated() {
            if !trackIDs.insert(track.id).inserted {
                issues.append(ValidationIssue(path: "tracks[\(i)].id", message: "轨道 ID 重复: \(track.id)"))
            }
            if TrackFeatureRegistry.feature(for: track.kind) == nil {
                issues.append(ValidationIssue(path: "tracks[\(i)].kind",
                                              message: "未注册的轨道类型 '\(track.kind.rawValue)'"))
            }
        }

        // 主轨：必须存在、链式、非空
        guard let primary = plan.primaryTrack else {
            issues.append(ValidationIssue(path: "primaryTrackID", message: "主轨不存在: \(plan.primaryTrackID)"))
            return issues
        }
        if primary.placement != .chained {
            issues.append(ValidationIssue(path: "primaryTrackID", message: "主轨必须是链式（.chained）"))
        }
        if primary.elements.isEmpty {
            issues.append(ValidationIssue(path: "tracks[\(primary.id)].elements", message: "主轨至少需要一个元素"))
        }

        // 逐轨分派给特性模块。
        // mainTrackEnd 必须是 renderedDuration（扣过转场重叠的成片时长），
        // 不能用 primary.span——链式轨的 span 是 Σ 元素时长，样例工程两者差 0.5s。
        let context = TrackValidationContext(assets: plan.assets,
                                             mainTrackEnd: plan.renderedDuration,
                                             tracks: plan.tracks)
        for track in plan.tracks {
            if let feature = TrackFeatureRegistry.feature(for: track.kind) {
                issues.append(contentsOf: feature.validate(track: track, context: context))
            }
        }

        // 核心不变式兜底：元素的 payload 类型必须属于其轨类型注册的 payload 集合。
        // 否则是跨类型误放（如把视频片段挪进字幕轨），核心放行、到引擎层才炸。
        for (i, track) in plan.tracks.enumerated() {
            guard let feature = TrackFeatureRegistry.feature(for: track.kind) else { continue }
            let accepted = Set(feature.payloadTypes.map { $0.payloadType })
            for (j, element) in track.elements.enumerated() {
                guard case .content(let payload) = element.content,
                      !accepted.contains(payload.payloadType) else { continue }
                issues.append(ValidationIssue(
                    path: "tracks[\(i)].elements[\(j)].content",
                    elementID: element.id,
                    message: "元素 payload 类型 '\(payload.payloadType)' 不属于轨道类型 '\(track.kind.rawValue)'"))
            }
        }

        // 核心不变式兜底：任何轨的元素不得超出主轨末端。
        // 用 renderedDuration 而非 primary.span——链式轨的 span 不含转场重叠。
        let mainEnd = plan.renderedDuration
        for track in plan.tracks where track.id != primary.id {
            for (i, element) in track.elements.enumerated() {
                let end = (element.at ?? 0) + element.duration
                if end > mainEnd + Self.durationTolerance {
                    issues.append(ValidationIssue(
                        path: "\(context.pathPrefix(for: track)).elements[\(i)].at",
                        elementID: element.id,
                        message: "元素末端 \(end)s 超出主轨末端 \(mainEnd)s"))
                }
            }
        }

        return issues
    }

    /// 素材存在性校验：登记表中每个条目对应的文件都必须落在磁盘上。
    public func validateAssets(_ plan: EditPlan, resolver: AssetResolver) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        for (i, asset) in plan.assets.enumerated() where !resolver.exists(asset) {
            issues.append(ValidationIssue(path: "assets[\(i)].fileName", message: "素材文件不存在: \(asset.fileName)"))
        }
        return issues
    }
}
