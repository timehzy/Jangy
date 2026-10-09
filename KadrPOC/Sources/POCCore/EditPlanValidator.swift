import Foundation

/// 校验问题：path 指向 JSON 字段路径（如 "clips[1].speed"），Agent/人都可读。
public struct ValidationIssue: Equatable, Sendable, Codable, CustomStringConvertible {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
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

        if plan.clips.isEmpty {
            issues.append(ValidationIssue(path: "clips", message: "至少需要一个片段"))
        }

        for (i, clip) in plan.clips.enumerated() {
            // 素材引用必须落在登记表里，且时间线片段目前只接受视频素材
            let asset = plan.asset(withID: clip.assetID)
            if asset == nil {
                issues.append(ValidationIssue(path: "clips[\(i)].assetID", message: "引用了未登记的素材: \(clip.assetID)"))
            } else if asset!.kind != .video {
                issues.append(ValidationIssue(path: "clips[\(i)].assetID", message: "时间线片段仅支持视频素材，实际为 \(asset!.kind.rawValue)"))
            }

            if clip.range.lowerBound < 0 {
                issues.append(ValidationIssue(path: "clips[\(i)].range", message: "裁剪起点不能为负"))
            } else if clip.range.upperBound <= clip.range.lowerBound {
                issues.append(ValidationIssue(path: "clips[\(i)].range", message: "裁剪区间不能为空"))
            } else if let duration = asset?.duration,
                      clip.range.upperBound > duration + Self.durationTolerance {
                issues.append(ValidationIssue(path: "clips[\(i)].range",
                                              message: "裁剪终点超出素材时长（\(duration)s）"))
            }

            if !Self.speedRange.contains(clip.speed.rate) {
                issues.append(ValidationIssue(path: "clips[\(i)].speed",
                                              message: "变速倍率必须在 \(Self.speedRange.lowerBound)–\(Self.speedRange.upperBound) 之间"))
            }

            if let transition = clip.transitionAfter {
                guard i + 1 < plan.clips.count else {
                    issues.append(ValidationIssue(path: "clips[\(i)].transitionAfter", message: "最后一个片段不能挂转场"))
                    continue
                }
                if transition.duration <= 0 {
                    issues.append(ValidationIssue(path: "clips[\(i)].transitionAfter", message: "转场时长必须为正"))
                    continue
                }
                // Kadr CompositionBuilder 按变速后时长（裁剪时长 / speedRate）检查转场适配。
                // 这里刻意保持保守：用完整转场时长对 min(两侧)，而非 Kadr 的 fade 每侧 duration/2——
                // 过严安全（误拒少数合法 plan），过松危险（放行 Kadr 导出期才拒绝的 plan）。
                let thisDuration = (clip.range.upperBound - clip.range.lowerBound) / clip.speed.rate
                let next = plan.clips[i + 1]
                let nextDuration = (next.range.upperBound - next.range.lowerBound) / next.speed.rate
                if transition.duration > min(thisDuration, nextDuration) {
                    issues.append(ValidationIssue(path: "clips[\(i)].transitionAfter", message: "转场时长不能超过相邻片段时长"))
                }
            }
        }

        if let captions = plan.captions, captions.isEnabled {
            switch plan.asset(withID: captions.assetID) {
            case nil:
                issues.append(ValidationIssue(path: "captions.assetID", message: "引用了未登记的素材: \(captions.assetID)"))
            case let asset? where asset.kind != .subtitle:
                issues.append(ValidationIssue(path: "captions.assetID", message: "字幕轨道必须引用字幕素材，实际为 \(asset.kind.rawValue)"))
            case let asset? where !asset.fileName.lowercased().hasSuffix(".srt"):
                issues.append(ValidationIssue(path: "captions.assetID", message: "POC 仅支持 SRT 字幕文件"))
            default:
                break
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
