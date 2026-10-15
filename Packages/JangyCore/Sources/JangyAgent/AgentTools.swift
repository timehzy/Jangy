import AnyLanguageModel
import Foundation
import JangyCore

// MARK: - 工具结果信封

/// 工具结果 JSON 信封：模型与宿主（CLI 事件流）都能消费。
/// 一切失败（参数错、领域错、校验错）都以 {"status":"error",...} 数据返回让模型自纠——
/// 工具内抛错会被框架包成 ToolCallError 在 respond 处 rethrow 炸掉整轮（参考实现教训），
/// 因此本文件所有工具的 call 都不向外抛错。
enum ToolEnvelope {
    private struct Ok<Payload: Encodable>: Encodable {
        let status = "ok"
        let payload: Payload
    }
    private struct Err: Encodable {
        let status = "error"
        let message: String
        let issues: [ValidationIssue]?
    }

    static func ok(_ payload: some Encodable) -> String {
        encode(Ok(payload: payload))
    }

    static func error(_ message: String, issues: [ValidationIssue]? = nil) -> String {
        encode(Err(message: message, issues: issues))
    }

    /// apply 结果 → 信封：校验失败回 {"status":"error","issues":[...]}（path 形如 clips[1].speed）。
    static func applied(_ result: Result<EditPlan, ValidationFailure>, payload: (EditPlan) -> some Encodable) -> String {
        switch result {
        case .success(let plan):
            return ok(payload(plan))
        case .failure(let failure):
            return error("校验未通过，请根据 issues 修正后重试", issues: failure.issues)
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// 工具公共件：步数闸门 + 元素查找。
enum AgentToolCommon {
    struct LookupError: Error {
        let message: String
    }

    /// 元素定位：elementID → (轨道下标, 元素下标)。
    struct ElementLocation { let trackIndex: Int; let elementIndex: Int }

    /// 步数闸门：超限后返回收尾提示（非 nil 表示应直接返回该结果，不再执行）。
    static func stepLimitIfExceeded(_ context: AgentRunContext) -> String? {
        context.admitToolCall()
            ? nil
            : ToolEnvelope.error("已达到工具调用步数上限（\(context.maxToolCalls)），请停止调用工具，用文字总结已完成的编辑")
    }

    /// 元素定位：全轨查找 elementID → (轨道下标, 元素下标)；失败返回错误信封文本。
    static func locate(_ plan: EditPlan, elementID: String) -> Result<ElementLocation, LookupError> {
        guard let uuid = UUID(uuidString: elementID) else {
            return .failure(LookupError(message: ToolEnvelope.error("无效的元素 ID: \(elementID)")))
        }
        for (ti, track) in plan.tracks.enumerated() {
            if let ei = track.elements.firstIndex(where: { $0.id == uuid }) {
                return .success(ElementLocation(trackIndex: ti, elementIndex: ei))
            }
        }
        return .failure(LookupError(message: ToolEnvelope.error(
            "找不到元素 \(elementID)，请先用 get_plan 获取当前元素 ID")))
    }

    /// 主轨下标（`add_clip` 等主轨操作仍按主轨定位）。
    static func primaryTrackIndex(_ plan: EditPlan) -> Int? {
        plan.tracks.firstIndex { $0.id == plan.primaryTrackID }
    }
}

/// 防御性参数解析：工具统一以 GeneratedContent 收参、内部解码为 @Generable 结构体，
/// 解码失败回落为错误信封而不是抛错（避免框架把参数错升级成整轮失败）。
/// schema 仍由 @Generable 结构体生成，模型看到的参数契约不受影响。
protocol DefensiveAgentTool: Tool where Arguments == GeneratedContent {
    associatedtype Args: Generable
    func call(parsed args: Args) async throws -> String
}

extension DefensiveAgentTool {
    var parameters: GenerationSchema { Args.generationSchema }

    func call(arguments: GeneratedContent) async throws -> String {
        do {
            return try await call(parsed: Args(arguments))
        } catch {
            return ToolEnvelope.error("工具参数无法解析：\(error.localizedDescription)。请严格按参数 schema 修正后重试")
        }
    }
}

// MARK: - 读工具

struct GetPlanTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "get_plan"
    let description = "读取当前时间线的完整 EditPlan JSON 和渲染总时长 renderedDuration（秒）。开始编辑前、或不确定当前状态时调用。"

    @Generable
    struct Args {}

    struct Payload: Encodable {
        let renderedDuration: TimeInterval
        let plan: EditPlan
    }

    func call(parsed _: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        let plan = await context.plan
        return ToolEnvelope.ok(Payload(renderedDuration: plan.renderedDuration, plan: plan))
    }
}

struct ListAssetsTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "list_assets"
    let description = "列出素材登记表（id/kind/fileName/时长/分辨率）。引用素材前先确认它已登记或知道文件名。"

    @Generable
    struct Args {}

    struct Payload: Encodable { let assets: [AssetItem] }

    func call(parsed _: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        return ToolEnvelope.ok(Payload(assets: (await context.plan).assets))
    }
}

// MARK: - 编辑工具

struct AddClipTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "add_clip"
    let description = "把素材追加为时间线末尾的片段。视频：提供 rangeStart/rangeEnd（源区间）；图片：提供可选 duration（秒，缺省 3），忽略 range。fileName 未登记时会在同一次编辑里自动登记（先探测素材元数据）。"

    @Generable
    struct Args {
        @Guide(description: "素材文件名（相对素材目录），如 clip1.mp4 或 photo.png")
        let fileName: String
        @Guide(description: "视频源区间起点（秒）。图片忽略。")
        let rangeStart: Double?
        @Guide(description: "视频源区间终点（秒）。图片忽略。")
        let rangeEnd: Double?
        @Guide(description: "变速倍率，0.25–4.0，缺省 1.0")
        let speed: Double?
        @Guide(description: "图片显示时长（秒），缺省 3.0。视频忽略。")
        let duration: Double?
    }

    struct Payload: Encodable {
        let clipID: String
        let assetID: String
        let registeredNewAsset: Bool
        let renderedDuration: TimeInterval
    }

    /// 按扩展名判图片（登记表未命中、需先探测时用）。
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "webp", "gif", "bmp"]

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        let currentPlan = await context.plan
        let existingFileNames = Set(currentPlan.assets.map(\.fileName))

        // 登记素材：已登记则复用；未登记先按扩展名判图片、探测元数据
        // （文件不存在直接报错，免得到引擎期才炸）
        var asset = currentPlan.assets.first { $0.fileName == args.fileName }
        if asset == nil {
            let ext = (args.fileName as NSString).pathExtension.lowercased()
            if Self.imageExtensions.contains(ext) {
                guard context.resolver.exists(AssetItem(kind: .image, fileName: args.fileName)) else {
                    return ToolEnvelope.error("素材文件不存在: \(args.fileName)。请用 list_assets 查看可用素材")
                }
                let metadata = AssetImporter.probeImageMetadata(of: context.resolver.resolve(fileName: args.fileName))
                asset = AssetItem(kind: .image, fileName: args.fileName, origin: .files,
                                  pixelWidth: metadata.pixelWidth, pixelHeight: metadata.pixelHeight,
                                  importedAt: Date())
            } else {
                guard context.resolver.exists(AssetItem(kind: .video, fileName: args.fileName)) else {
                    return ToolEnvelope.error("素材文件不存在: \(args.fileName)。请用 list_assets 查看可用素材")
                }
                let metadata = await AssetImporter.probeMetadata(of: context.resolver.resolve(fileName: args.fileName))
                asset = AssetItem(kind: .video, fileName: args.fileName, origin: .files,
                                  duration: metadata.duration, pixelWidth: metadata.pixelWidth,
                                  pixelHeight: metadata.pixelHeight, hasAudio: metadata.hasAudio,
                                  importedAt: Date())
            }
        }
        guard let asset else { return ToolEnvelope.error("素材登记失败") }
        // 已登记的非上轨类型（音频后置；字幕走 set_captions）直接拒绝——
        // 否则下面的 .video 分支会对缺失的 range 强解包崩溃。
        // 注意：未登记文件在探测阶段按扩展名归类（image vs 其余），不在此 guard 范围。
        guard asset.kind == .video || asset.kind == .image else {
            let label = asset.kind == .audio ? "音频" : "字幕"
            return ToolEnvelope.error("不支持把\(label)素材加入时间线（音频后置；字幕请用 set_captions）")
        }
        let rate = args.speed ?? 1.0

        // 视频需 range（ClosedRange 构造下界>上界会运行时 trap，必须先拦）
        if asset.kind == .video {
            guard let start = args.rangeStart, let end = args.rangeEnd, start < end else {
                return ToolEnvelope.error("视频片段必须提供非空源区间：rangeStart 须小于 rangeEnd")
            }
        }

        // 登记 + 追加必须在同一次 apply（公约：单事务、单撤销步）
        return await context.withStore { store in
            let result = store.apply { plan in
                let assetID: UUID
                if let registered = plan.assets.first(where: { $0.fileName == asset.fileName }) {
                    assetID = registered.id
                } else {
                    plan.assets.append(asset)
                    assetID = asset.id
                }
                let clip: PlanClip
                switch asset.kind {
                case .image:
                    clip = PlanClip(assetID: assetID, source: .still(duration: args.duration ?? 3.0), speed: .flat(rate))
                default:
                    clip = PlanClip(assetID: assetID,
                                    source: .video(args.rangeStart!...args.rangeEnd!),
                                    speed: .flat(rate))
                }
                guard let ti = AgentToolCommon.primaryTrackIndex(plan) else { return }
                plan.tracks[ti].elements.append(PlanElement(content: .content(TrackPayload(clip))))
            }
            return ToolEnvelope.applied(result) { plan in
                let elementID = plan.primaryTrack?.elements.last?.id.uuidString ?? ""
                let registered = plan.assets.first { $0.fileName == asset.fileName }!
                return Payload(clipID: elementID, assetID: registered.id.uuidString,
                               registeredNewAsset: !existingFileNames.contains(asset.fileName),
                               renderedDuration: plan.renderedDuration)
            }
        }
    }
}

struct SplitClipTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "split_clip"
    let description = "在片段内指定时刻把片段切成两段。变速等片段属性两段都保留；原片段尾部转场归后半段。视频按源区间时间切，图片按基准时长切。"

    @Generable
    struct Args {
        @Guide(description: "片段 ID（get_plan 返回的 clip id）")
        let clipID: String
        @Guide(description: "分割点（秒）。视频为源区间内时刻，图片为片段基准时长内时刻；须严格落在区间内部")
        let at: Double
    }

    struct Payload: Encodable {
        let firstClipID: String
        let secondClipID: String
        let renderedDuration: TimeInterval
    }

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        return await context.withStore { store in
            let location: AgentToolCommon.ElementLocation
            switch AgentToolCommon.locate(store.plan, elementID: args.clipID) {
            case .success(let found): location = found
            case .failure(let error): return error.message
            }
            guard case .content(let payload) = store.plan.tracks[location.trackIndex]
                    .elements[location.elementIndex].content,
                  let clip = payload.value as? PlanClip else {
                return ToolEnvelope.error("元素 \(args.clipID) 不是视频/图片片段，无法分割")
            }
            let originalID = store.plan.tracks[location.trackIndex].elements[location.elementIndex].id
            switch clip.source {
            case .video(let range):
                guard args.at > range.lowerBound, args.at < range.upperBound else {
                    return ToolEnvelope.error("分割点 \(args.at) 须严格落在片段源区间 \(range.lowerBound)–\(range.upperBound) 内")
                }
                let secondID = UUID()
                let result = store.apply { plan in
                    guard case .content(let p) = plan.tracks[location.trackIndex]
                            .elements[location.elementIndex].content,
                          var first = p.value as? PlanClip else { return }
                    var second = first
                    first.source = .video(range.lowerBound...args.at)
                    first.transitionAfter = nil
                    second.source = .video(args.at...range.upperBound)
                    plan.tracks[location.trackIndex].elements.replaceSubrange(
                        location.elementIndex...location.elementIndex,
                        with: [PlanElement(id: originalID, content: .content(TrackPayload(first))),
                               PlanElement(id: secondID, content: .content(TrackPayload(second)))])
                }
                return ToolEnvelope.applied(result) { plan in
                    Payload(firstClipID: args.clipID, secondClipID: secondID.uuidString,
                            renderedDuration: plan.renderedDuration)
                }
            case .still(let duration):
                // 图片无源区间：分割点按「片段内已过时间」解释，切成两段 still（倍率两段都保留）。
                guard args.at > 0, args.at < duration else {
                    return ToolEnvelope.error("分割点 \(args.at) 须严格落在图片时长 0–\(duration) 内")
                }
                let secondID = UUID()
                let result = store.apply { plan in
                    guard case .content(let p) = plan.tracks[location.trackIndex]
                            .elements[location.elementIndex].content,
                          var first = p.value as? PlanClip else { return }
                    var second = first
                    first.source = .still(duration: args.at)
                    first.transitionAfter = nil
                    second.source = .still(duration: duration - args.at)
                    plan.tracks[location.trackIndex].elements.replaceSubrange(
                        location.elementIndex...location.elementIndex,
                        with: [PlanElement(id: originalID, content: .content(TrackPayload(first))),
                               PlanElement(id: secondID, content: .content(TrackPayload(second)))])
                }
                return ToolEnvelope.applied(result) { plan in
                    Payload(firstClipID: args.clipID, secondClipID: secondID.uuidString,
                            renderedDuration: plan.renderedDuration)
                }
            }
        }
    }
}

struct TrimClipTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "trim_clip"
    let description = "修改片段时长。视频：改源区间（区间须在素材时长内且非空）；图片：以 rangeEnd − rangeStart 作为新时长。"

    @Generable
    struct Args {
        @Guide(description: "片段 ID")
        let clipID: String
        @Guide(description: "新区间起点（秒，相对素材自身时间轴）")
        let rangeStart: Double
        @Guide(description: "新区间终点（秒）")
        let rangeEnd: Double
    }

    struct Payload: Encodable {
        let clipID: String
        let renderedDuration: TimeInterval
    }

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        guard args.rangeStart < args.rangeEnd else {
            return ToolEnvelope.error("区间不能为空：rangeStart（\(args.rangeStart)）须小于 rangeEnd（\(args.rangeEnd)）")
        }
        return await context.withStore { store in
            let location: AgentToolCommon.ElementLocation
            switch AgentToolCommon.locate(store.plan, elementID: args.clipID) {
            case .success(let found): location = found
            case .failure(let error): return error.message
            }
            let result = store.apply { plan in
                guard case .content(let payload) = plan.tracks[location.trackIndex]
                        .elements[location.elementIndex].content,
                      var clip = payload.value as? PlanClip else { return }
                switch clip.source {
                case .video:
                    clip.source = .video(args.rangeStart...args.rangeEnd)
                case .still:
                    // 图片无源区间：以 rangeEnd − rangeStart 作为新基准时长。
                    clip.source = .still(duration: args.rangeEnd - args.rangeStart)
                }
                plan.tracks[location.trackIndex].elements[location.elementIndex].content =
                    .content(TrackPayload(clip))
            }
            return ToolEnvelope.applied(result) { plan in
                Payload(clipID: args.clipID, renderedDuration: plan.renderedDuration)
            }
        }
    }
}

struct MoveClipTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "move_clip"
    let description = "把片段移动到时间线的另一个位置（按下标）。"

    @Generable
    struct Args {
        @Guide(description: "片段 ID")
        let clipID: String
        @Guide(description: "目标下标（0 起）")
        let toIndex: Int
    }

    struct Payload: Encodable {
        let clipOrder: [String]
        let renderedDuration: TimeInterval
    }

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        return await context.withStore { store in
            let location: AgentToolCommon.ElementLocation
            switch AgentToolCommon.locate(store.plan, elementID: args.clipID) {
            case .success(let found): location = found
            case .failure(let error): return error.message
            }
            let track = store.plan.tracks[location.trackIndex]
            guard track.elements.indices.contains(args.toIndex) else {
                return ToolEnvelope.error("目标下标 \(args.toIndex) 越界（当前共 \(track.elements.count) 个片段）")
            }
            let result = store.apply { plan in
                let element = plan.tracks[location.trackIndex].elements.remove(at: location.elementIndex)
                plan.tracks[location.trackIndex].elements.insert(element, at: args.toIndex)
            }
            return ToolEnvelope.applied(result) { plan in
                Payload(clipOrder: plan.tracks[location.trackIndex].elements.map { $0.id.uuidString },
                        renderedDuration: plan.renderedDuration)
            }
        }
    }
}

struct RemoveClipTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "remove_clip"
    let description = "删除片段。被删片段尾部的转场一并消失；前一片段若挂着指向它的转场会被自动清除。"

    @Generable
    struct Args {
        @Guide(description: "片段 ID")
        let clipID: String
    }

    struct Payload: Encodable {
        let renderedDuration: TimeInterval
        let remainingClips: Int
    }

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        return await context.withStore { store in
            let location: AgentToolCommon.ElementLocation
            switch AgentToolCommon.locate(store.plan, elementID: args.clipID) {
            case .success(let found): location = found
            case .failure(let error): return error.message
            }
            let elementID = store.plan.tracks[location.trackIndex].elements[location.elementIndex].id
            let result = store.apply { plan in
                TrackOperations.removeElement(elementID, in: &plan)
            }
            return ToolEnvelope.applied(result) { plan in
                Payload(renderedDuration: plan.renderedDuration,
                        remainingClips: plan.primaryTrack?.elements.count ?? 0)
            }
        }
    }
}

struct SetSpeedTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "set_speed"
    let description = "设置片段变速倍率（0.25–4.0）。变速改变该片段的输出时长，从而影响总时长与转场适配。"

    @Generable
    struct Args {
        @Guide(description: "片段 ID")
        let clipID: String
        @Guide(description: "变速倍率，0.25–4.0")
        let rate: Double
    }

    struct Payload: Encodable {
        let clipID: String
        let rate: Double
        let renderedDuration: TimeInterval
    }

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        return await context.withStore { store in
            let location: AgentToolCommon.ElementLocation
            switch AgentToolCommon.locate(store.plan, elementID: args.clipID) {
            case .success(let found): location = found
            case .failure(let error): return error.message
            }
            let result = store.apply { plan in
                guard case .content(let payload) = plan.tracks[location.trackIndex]
                        .elements[location.elementIndex].content,
                      var clip = payload.value as? PlanClip else { return }
                clip.speed = .flat(args.rate)
                plan.tracks[location.trackIndex].elements[location.elementIndex].content =
                    .content(TrackPayload(clip))
            }
            return ToolEnvelope.applied(result) { plan in
                Payload(clipID: args.clipID, rate: args.rate,
                        renderedDuration: plan.renderedDuration)
            }
        }
    }
}

struct SetTransitionTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "set_transition"
    let description = "设置或移除片段尾部的转场。dissolve 与相邻片段全额重叠（扣总时长）；fade 不重叠。转场时长不能超过相邻两段中较短者的输出时长。"

    @Generable
    struct Args {
        @Guide(description: "片段 ID（转场挂在该片段尾部，最后一段不能挂转场）")
        let clipID: String
        @Guide(description: "转场类型：dissolve / fade / none（none = 移除转场）")
        let type: String
        @Guide(description: "转场时长（秒），type 为 none 时忽略，缺省 0.5")
        let duration: Double?
    }

    struct Payload: Encodable {
        let clipID: String
        let renderedDuration: TimeInterval
    }

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        let transition: PlanTransition?
        switch args.type {
        case "none":
            transition = nil
        case "dissolve":
            transition = .dissolve(duration: args.duration ?? 0.5)
        case "fade":
            transition = .fade(duration: args.duration ?? 0.5)
        default:
            return ToolEnvelope.error("未知转场类型 '\(args.type)'；支持：dissolve / fade / none")
        }
        return await context.withStore { store in
            let location: AgentToolCommon.ElementLocation
            switch AgentToolCommon.locate(store.plan, elementID: args.clipID) {
            case .success(let found): location = found
            case .failure(let error): return error.message
            }

            // 前置守卫：转场要求「后面紧跟一个内容元素」。链式轨的末位（或后面是空档）挂转场，
            // 会被 apply 的归一化静默清掉、工具回假成功——模型违反了自己 @Guide 的规则却收不到
            // 纠正信号。这里显式报错让模型自纠。移除转场（transition == nil）不受此限。
            if transition != nil, store.plan.tracks[location.trackIndex].placement == .chained {
                let elements = store.plan.tracks[location.trackIndex].elements
                let nextIndex = location.elementIndex + 1
                let hasAdjacentContent: Bool = {
                    guard nextIndex < elements.count,
                          case .content(let nextPayload) = elements[nextIndex].content else { return false }
                    return nextPayload.value is PlanClip
                }()
                guard hasAdjacentContent else {
                    return ToolEnvelope.error(nextIndex < elements.count
                                              ? "转场不能跨过空档——请先移除空档"
                                              : "最后一个片段不能挂转场")
                }
            }

            let result = store.apply { plan in
                guard case .content(let payload) = plan.tracks[location.trackIndex]
                        .elements[location.elementIndex].content,
                      var clip = payload.value as? PlanClip else { return }
                clip.transitionAfter = transition
                plan.tracks[location.trackIndex].elements[location.elementIndex].content =
                    .content(TrackPayload(clip))
            }
            return ToolEnvelope.applied(result) { plan in
                Payload(clipID: args.clipID, renderedDuration: plan.renderedDuration)
            }
        }
    }
}

struct SetCaptionsTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "set_captions"
    let description = "设置外挂字幕（仅 SRT 文件），fileName 未登记时自动登记。enabled=false 关闭字幕显示。"

    @Generable
    struct Args {
        @Guide(description: "字幕文件名（.srt，相对素材目录）")
        let fileName: String
        @Guide(description: "字号，缺省 48")
        let fontSize: Double?
        @Guide(description: "是否加粗，缺省 true")
        let isBold: Bool?
        @Guide(description: "是否启用，缺省 true")
        let enabled: Bool?
    }

    struct Payload: Encodable {
        let captionAssetID: String
        let isEnabled: Bool
    }

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        guard args.fileName.lowercased().hasSuffix(".srt") else {
            return ToolEnvelope.error("仅支持 SRT 字幕文件: \(args.fileName)")
        }
        guard await context.plan.assets.contains(where: { $0.fileName == args.fileName })
            || context.resolver.exists(AssetItem(kind: .subtitle, fileName: args.fileName))
        else {
            return ToolEnvelope.error("字幕文件不存在: \(args.fileName)。请用 list_assets 查看可用素材")
        }

        // 字幕逐句化：SRT 导入展开成 cue 元素（位置进 element.at，payload 只留文本与时长）。
        // 读文件在事务外——store.apply 的闭包是纯内存操作，不做 IO。
        let srtURL = context.resolver.resolve(fileName: args.fileName)
        guard let data = try? Data(contentsOf: srtURL),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            return ToolEnvelope.error("字幕文件读不出来: \(args.fileName)")
        }
        let cueElements = SRTParser.parse(text).cues.map { cue in
            PlanElement(at: cue.start, content: .content(TrackPayload(
                CaptionCuePayload(text: cue.text, duration: cue.duration))))
        }

        return await context.withStore { store in
            let result = store.apply { plan in
                let assetID: UUID
                if let registered = plan.assets.first(where: { $0.fileName == args.fileName }) {
                    assetID = registered.id
                } else {
                    let asset = AssetItem(kind: .subtitle, fileName: args.fileName,
                                          origin: .files, importedAt: Date())
                    plan.assets.append(asset)
                    assetID = asset.id
                }
                let settings = CaptionTrackSettings(
                    fontSize: args.fontSize ?? 48, isBold: args.isBold ?? true,
                    isEnabled: args.enabled ?? true, sourceAssetID: assetID)
                if let ti = plan.tracks.firstIndex(where: { $0.kind == .caption }) {
                    plan.tracks[ti].settings = TrackPayload(settings)
                    plan.tracks[ti].elements = cueElements
                } else {
                    plan.tracks.append(PlanTrack(kind: .caption, placement: .absolute,
                                                 settings: TrackPayload(settings), elements: cueElements))
                }
            }
            return ToolEnvelope.applied(result) { plan in
                let settings = plan.tracks.first { $0.kind == .caption }.map(CaptionFeature.settings(of:))
                return Payload(captionAssetID: settings?.sourceAssetID?.uuidString ?? "",
                               isEnabled: settings?.isEnabled ?? false)
            }
        }
    }
}

// MARK: - 视觉自检工具

struct SnapshotTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "snapshot"
    let description = "以导出保真度渲染指定时刻的画面（含字幕烧录），用于视觉自检。时刻取合成时间轴秒数，须在 [0, renderedDuration] 内。渲染结果会在下一轮自动以图片附上供你检查。"

    @Generable
    struct Args {
        @Guide(description: "快照时刻列表（秒，合成时间轴）")
        let times: [Double]
    }

    struct FrameInfo: Encodable {
        let at: Double
        let path: String
    }
    struct Payload: Encodable {
        let frames: [FrameInfo]
        let note: String
    }

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        guard !args.times.isEmpty else {
            return ToolEnvelope.error("至少指定一个快照时刻")
        }
        let plan = await context.plan
        do {
            let frames = try await FrameSnapshotter.snapshots(plan: plan, resolver: context.resolver, at: args.times)
            let dir = context.framesDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var pending: [AgentRunContext.SnapshotFrame] = []
            var infos: [FrameInfo] = []
            for t in args.times {
                guard let data = frames[t] else { continue }
                let url = dir.appendingPathComponent(String(format: "t%.2f.png", t))
                try data.write(to: url)
                pending.append(.init(at: t, url: url, pngData: data))
                infos.append(FrameInfo(at: t, path: url.path))
            }
            context.enqueueSnapshots(pending)
            return ToolEnvelope.ok(Payload(frames: infos, note: "快照画面将在下一轮自动以图片附上，请检查字幕/转场等视觉效果是否符合预期"))
        } catch FrameSnapshotter.Failure.timeOutOfRange(let t, let duration) {
            return ToolEnvelope.error("时刻 \(t)s 超出渲染时长 \(duration)s，请用 get_plan 确认 renderedDuration 后重试")
        } catch {
            return ToolEnvelope.error("快照渲染失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - 工具集装配

public enum AgentToolSet {
    public static func make(context: AgentRunContext) -> [any Tool] {
        [
            GetPlanTool(context: context),
            ListAssetsTool(context: context),
            AddClipTool(context: context),
            SplitClipTool(context: context),
            TrimClipTool(context: context),
            MoveClipTool(context: context),
            RemoveClipTool(context: context),
            SetSpeedTool(context: context),
            SetTransitionTool(context: context),
            SetCaptionsTool(context: context),
            SnapshotTool(context: context),
        ]
    }
}
