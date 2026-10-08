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

    public init() {}

    public func validate(_ plan: EditPlan) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        if plan.clips.isEmpty {
            issues.append(ValidationIssue(path: "clips", message: "至少需要一个片段"))
        }

        for (i, clip) in plan.clips.enumerated() {
            if clip.range.lowerBound < 0 {
                issues.append(ValidationIssue(path: "clips[\(i)].range", message: "裁剪起点不能为负"))
            } else if clip.range.upperBound <= clip.range.lowerBound {
                issues.append(ValidationIssue(path: "clips[\(i)].range", message: "裁剪区间不能为空"))
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
                let thisDuration = clip.range.upperBound - clip.range.lowerBound
                let next = plan.clips[i + 1]
                let nextDuration = next.range.upperBound - next.range.lowerBound
                if transition.duration > min(thisDuration, nextDuration) {
                    issues.append(ValidationIssue(path: "clips[\(i)].transitionAfter", message: "转场时长不能超过相邻片段时长"))
                }
            }
        }

        if let captions = plan.captions, captions.isEnabled,
           !captions.source.fileName.lowercased().hasSuffix(".srt") {
            issues.append(ValidationIssue(path: "captions.source", message: "POC 仅支持 SRT 字幕文件"))
        }

        return issues
    }

    public func validateAssets(_ plan: EditPlan, resolver: AssetResolver) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        for (i, clip) in plan.clips.enumerated() where !resolver.exists(clip.source) {
            issues.append(ValidationIssue(path: "clips[\(i)].source", message: "素材不存在: \(clip.source.fileName)"))
        }
        if let captions = plan.captions, captions.isEnabled, !resolver.exists(captions.source) {
            issues.append(ValidationIssue(path: "captions.source", message: "字幕文件不存在: \(captions.source.fileName)"))
        }
        return issues
    }
}
