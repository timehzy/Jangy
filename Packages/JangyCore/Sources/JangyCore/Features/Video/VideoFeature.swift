import Foundation

/// 视频轨特性（L2 片）：payload 模型 + 校验规则。L3 引擎映射见同目录 VideoEngine.swift。
public enum VideoFeature: TrackFeature {
    public static let kind = TrackKind.video
    public static let payloadTypes: [any TrackElementPayload.Type] = [PlanClip.self]

    public static func validate(track: PlanTrack, context: TrackValidationContext) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        if track.placement != .chained {
            issues.append(ValidationIssue(path: "\(context.pathPrefix(for: track)).placement",
                                          message: "视频轨必须是链式（.chained）"))
        }

        for (i, element) in track.elements.enumerated() {
            let path = "\(context.pathPrefix(for: track)).elements[\(i)]"
            // gap 在链式轨上合法（删除留下的空档），不校验内容；
            // 出现别的 payload 类型（kind 与 payload 不匹配）时同样跳过——
            // 那类错误由引擎层（EngineBridge.UnknownPayloadError）兜底，不在这里判。
            guard case .content(let payload) = element.content,
                  let clip = payload.value as? PlanClip else { continue }

            let asset = context.asset(withID: clip.assetID)
            if asset == nil {
                issues.append(ValidationIssue(path: "\(path).assetID", elementID: element.id,
                                              message: "引用了未登记的素材: \(clip.assetID)"))
            } else if let asset {
                switch clip.source {
                case .video where asset.kind != .video:
                    issues.append(ValidationIssue(path: "\(path).assetID", elementID: element.id,
                                                  message: "视频片段必须引用视频素材，实际为 \(asset.kind.rawValue)"))
                case .still where asset.kind != .image:
                    issues.append(ValidationIssue(path: "\(path).assetID", elementID: element.id,
                                                  message: "图片片段必须引用图片素材，实际为 \(asset.kind.rawValue)"))
                default:
                    break
                }
            }

            switch clip.source {
            case .video(let range):
                if range.lowerBound < 0 {
                    issues.append(ValidationIssue(path: "\(path).source.range", elementID: element.id,
                                                  message: "裁剪起点不能为负"))
                } else if range.upperBound <= range.lowerBound {
                    issues.append(ValidationIssue(path: "\(path).source.range", elementID: element.id,
                                                  message: "裁剪区间不能为空"))
                } else if let duration = asset?.duration,
                          range.upperBound > duration + EditPlanValidator.durationTolerance {
                    issues.append(ValidationIssue(path: "\(path).source.range", elementID: element.id,
                                                  message: "裁剪终点超出素材时长（\(duration)s）"))
                }
            case .still(let duration):
                if duration <= 0 {
                    issues.append(ValidationIssue(path: "\(path).source.duration", elementID: element.id,
                                                  message: "图片时长必须为正"))
                }
            }

            if !EditPlanValidator.speedRange.contains(clip.speed.rate) {
                issues.append(ValidationIssue(
                    path: "\(path).speed", elementID: element.id,
                    message: "变速倍率必须在 \(EditPlanValidator.speedRange.lowerBound)–\(EditPlanValidator.speedRange.upperBound) 之间"))
            }

            guard let transition = clip.transitionAfter else { continue }

            // 转场只对「紧邻的下一个元素」生效；gap 打断邻接
            let nextIndex = i + 1
            guard nextIndex < track.elements.count else {
                issues.append(ValidationIssue(path: "\(path).transitionAfter", elementID: element.id,
                                              message: "最后一个片段不能挂转场"))
                continue
            }
            guard case .content(let nextPayload) = track.elements[nextIndex].content,
                  nextPayload.value is PlanClip else {
                issues.append(ValidationIssue(path: "\(path).transitionAfter", elementID: element.id,
                                              message: "转场不能跨过空档——请先移除转场"))
                continue
            }
            if transition.duration <= 0 {
                issues.append(ValidationIssue(path: "\(path).transitionAfter", elementID: element.id,
                                              message: "转场时长必须为正"))
                continue
            }
            let nextDuration = track.elements[nextIndex].duration
            if transition.duration > min(element.duration, nextDuration) {
                issues.append(ValidationIssue(path: "\(path).transitionAfter", elementID: element.id,
                                              message: "转场时长不能超过相邻片段时长"))
            }
        }
        return issues
    }
}
