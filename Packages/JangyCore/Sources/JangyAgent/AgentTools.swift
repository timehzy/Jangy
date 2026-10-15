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

    /// apply 结果 → 信封：校验失败回 {"status":"error","issues":[...]}（path 形如 tracks[0].elements[1].speed）。
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

    /// 轨道下标（按 id）。
    static func trackIndex(_ plan: EditPlan, trackID: String) -> Int? {
        guard let uuid = UUID(uuidString: trackID) else { return nil }
        return plan.tracks.firstIndex { $0.id == uuid }
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
    let description = "读取当前时间线。payload.elements 是**扁平元素视图**（含 elementID/trackID/payloadType，字幕 cue 还带 text），payload.plan 是完整 EditPlan JSON，payload.renderedDuration 是成片总时长（秒）。开始编辑前、或不确定当前状态时调用。"

    @Generable
    struct Args {}

    struct Payload: Encodable {
        struct ElementView: Encodable {
            let elementID: String
            let trackID: String
            let trackKind: String
            let at: TimeInterval?
            let duration: TimeInterval
            let payloadType: String?
            /// 字幕 cue 的文本，便于模型直接读。
            let text: String?
        }
        let renderedDuration: TimeInterval
        let primaryTrackID: String
        /// 扁平视图：模型不必自己遍历 tracks[].elements[]。
        let elements: [ElementView]
        /// 原始 plan JSON。
        let plan: EditPlan
    }

    func call(parsed _: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        let plan = await context.plan
        let views = plan.tracks.flatMap { track in
            track.elements.map { element -> Payload.ElementView in
                var payloadType: String?
                var text: String?
                if case .content(let payload) = element.content {
                    payloadType = payload.payloadType
                    text = (payload.value as? CaptionCuePayload)?.text
                }
                return Payload.ElementView(elementID: element.id.uuidString,
                                           trackID: track.id.uuidString,
                                           trackKind: track.kind.rawValue,
                                           at: element.at,
                                           duration: element.duration,
                                           payloadType: payloadType,
                                           text: text)
            }
        }
        return ToolEnvelope.ok(Payload(renderedDuration: plan.renderedDuration,
                                       primaryTrackID: plan.primaryTrackID.uuidString,
                                       elements: views, plan: plan))
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
    let description = "把素材加为片段。缺省追加到主轨末尾（链式）；给了 trackID 则加到该轨（绝对定位轨必须同时给 at）。视频：提供 rangeStart/rangeEnd（源区间）；图片：提供可选 duration（秒，缺省 3），忽略 range。fileName 未登记时会在同一次编辑里自动登记（先探测素材元数据）。"

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
        @Guide(description: "目标轨道 ID，缺省 = 主轨（追加到末尾）")
        let trackID: String?
        @Guide(description: "绝对定位轨上的起点（秒）。目标是绝对定位轨时必填；主轨忽略。")
        let at: Double?
    }

    struct Payload: Encodable {
        let elementID: String
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

        // 目标轨：缺省主轨；显式指定时必须是已存在的轨，且是视频轨
        let targetTrackID: UUID
        if let raw = args.trackID {
            guard let index = AgentToolCommon.trackIndex(currentPlan, trackID: raw) else {
                return ToolEnvelope.error("找不到轨道 \(raw)，请先用 get_plan 获取当前轨道 ID")
            }
            let track = currentPlan.tracks[index]
            guard track.kind == .video else {
                return ToolEnvelope.error("add_clip 只能往视频轨加片段（字幕请用 set_caption_track）")
            }
            if track.placement == .absolute, args.at == nil {
                return ToolEnvelope.error("轨道 \(raw) 是绝对定位轨，必须提供 at（起点秒数）")
            }
            targetTrackID = track.id
        } else {
            targetTrackID = currentPlan.primaryTrackID
        }

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
        // 已登记的非视频/图片类型（音频后置；字幕走 set_caption_track）直接拒绝——
        // 否则下面的 .video 分支会对缺失的 range 强解包崩溃。
        // 注意：未登记文件在探测阶段按扩展名归类（image vs 其余），不在此 guard 范围。
        guard asset.kind == .video || asset.kind == .image else {
            let label = asset.kind == .audio ? "音频" : "字幕"
            return ToolEnvelope.error("不支持把\(label)素材加入时间线（音频后置；字幕请用 set_caption_track）")
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
                guard let ti = plan.tracks.firstIndex(where: { $0.id == targetTrackID }) else { return }
                // 绝对定位轨用 at 锚定；链式轨的 at 恒为 nil（位置由顺序推出）。
                let at = plan.tracks[ti].placement == .absolute ? args.at : nil
                plan.tracks[ti].elements.append(PlanElement(at: at, content: .content(TrackPayload(clip))))
            }
            return ToolEnvelope.applied(result) { plan in
                let track = plan.tracks.first { $0.id == targetTrackID }
                let elementID = track?.elements.last?.id.uuidString ?? ""
                let registered = plan.assets.first { $0.fileName == asset.fileName }!
                return Payload(elementID: elementID, assetID: registered.id.uuidString,
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
        @Guide(description: "片段元素 ID（get_plan 返回的 elementID）")
        let elementID: String
        @Guide(description: "分割点（秒）。视频为源区间内时刻，图片为片段基准时长内时刻；须严格落在区间内部")
        let at: Double
    }

    struct Payload: Encodable {
        let firstElementID: String
        let secondElementID: String
        let renderedDuration: TimeInterval
    }

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        return await context.withStore { store in
            let location: AgentToolCommon.ElementLocation
            switch AgentToolCommon.locate(store.plan, elementID: args.elementID) {
            case .success(let found): location = found
            case .failure(let error): return error.message
            }
            guard case .content(let payload) = store.plan.tracks[location.trackIndex]
                    .elements[location.elementIndex].content,
                  let clip = payload.value as? PlanClip else {
                return ToolEnvelope.error("元素 \(args.elementID) 不是视频/图片片段，无法分割")
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
                    // 绝对定位轨要保留 at：前半段沿用原位，后半段顺延前半段的输出时长。
                    // 链式轨 at 恒为 nil，两段都不带 at。
                    let originalAt = plan.tracks[location.trackIndex].elements[location.elementIndex].at
                    var second = first
                    first.source = .video(range.lowerBound...args.at)
                    first.transitionAfter = nil
                    second.source = .video(args.at...range.upperBound)
                    let firstElement = PlanElement(id: originalID, at: originalAt,
                                                   content: .content(TrackPayload(first)))
                    let secondElement = PlanElement(at: originalAt.map { $0 + firstElement.duration },
                                                    content: .content(TrackPayload(second)))
                    plan.tracks[location.trackIndex].elements.replaceSubrange(
                        location.elementIndex...location.elementIndex,
                        with: [firstElement, secondElement])
                }
                return ToolEnvelope.applied(result) { plan in
                    Payload(firstElementID: args.elementID, secondElementID: secondID.uuidString,
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
                    let originalAt = plan.tracks[location.trackIndex].elements[location.elementIndex].at
                    var second = first
                    first.source = .still(duration: args.at)
                    first.transitionAfter = nil
                    second.source = .still(duration: duration - args.at)
                    let firstElement = PlanElement(id: originalID, at: originalAt,
                                                   content: .content(TrackPayload(first)))
                    let secondElement = PlanElement(at: originalAt.map { $0 + firstElement.duration },
                                                    content: .content(TrackPayload(second)))
                    plan.tracks[location.trackIndex].elements.replaceSubrange(
                        location.elementIndex...location.elementIndex,
                        with: [firstElement, secondElement])
                }
                return ToolEnvelope.applied(result) { plan in
                    Payload(firstElementID: args.elementID, secondElementID: secondID.uuidString,
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
        @Guide(description: "片段元素 ID")
        let elementID: String
        @Guide(description: "新区间起点（秒，相对素材自身时间轴）")
        let rangeStart: Double
        @Guide(description: "新区间终点（秒）")
        let rangeEnd: Double
    }

    struct Payload: Encodable {
        let elementID: String
        let renderedDuration: TimeInterval
    }

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        guard args.rangeStart < args.rangeEnd else {
            return ToolEnvelope.error("区间不能为空：rangeStart（\(args.rangeStart)）须小于 rangeEnd（\(args.rangeEnd)）")
        }
        return await context.withStore { store in
            let location: AgentToolCommon.ElementLocation
            switch AgentToolCommon.locate(store.plan, elementID: args.elementID) {
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
                Payload(elementID: args.elementID, renderedDuration: plan.renderedDuration)
            }
        }
    }
}

struct MoveElementTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "move_element"
    let description = "移动元素。给 beforeElementID = 插到该元素之前（相对定位）；给 at = 放到该绝对时间（仅绝对定位轨）；给 toTrackID = 换轨（不给 beforeElementID 则追加到目标轨末尾）。至少给一个。"

    @Generable
    struct Args {
        @Guide(description: "要移动的元素 ID")
        let elementID: String
        @Guide(description: "目标轨道 ID；缺省 = 不换轨")
        let toTrackID: String?
        @Guide(description: "插到这个元素之前（同轨内的相对定位）。不给则追加到目标轨末尾。")
        let beforeElementID: String?
        @Guide(description: "放到这个绝对时间（秒），仅绝对定位轨")
        let at: Double?
    }

    struct Payload: Encodable {
        let elementID: String
        let trackID: String
        let renderedDuration: TimeInterval
    }

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        guard args.toTrackID != nil || args.beforeElementID != nil || args.at != nil else {
            return ToolEnvelope.error("至少要给 toTrackID / beforeElementID / at 其中之一")
        }
        return await context.withStore { store in
            // 目标元素
            let location: AgentToolCommon.ElementLocation
            switch AgentToolCommon.locate(store.plan, elementID: args.elementID) {
            case .success(let found): location = found
            case .failure(let error): return error.message
            }
            let movedID = store.plan.tracks[location.trackIndex].elements[location.elementIndex].id

            // 锚点元素（校验存在；记 id 而非下标——移除后下标会漂移）
            var beforeID: UUID?
            if let raw = args.beforeElementID {
                guard let uuid = UUID(uuidString: raw) else {
                    return ToolEnvelope.error("无效的元素 ID: \(raw)")
                }
                guard store.plan.tracks.contains(where: { $0.elements.contains { $0.id == uuid } }) else {
                    return ToolEnvelope.error("找不到元素 \(raw)，请先用 get_plan 获取当前元素 ID")
                }
                beforeID = uuid
            }

            // 目标轨（校验存在）
            var targetTrackID: UUID?
            if let raw = args.toTrackID {
                guard let index = AgentToolCommon.trackIndex(store.plan, trackID: raw) else {
                    return ToolEnvelope.error("找不到轨道 \(raw)，请先用 get_plan 获取当前轨道 ID")
                }
                targetTrackID = store.plan.tracks[index].id
            }
            let destinationIndex = targetTrackID.flatMap { id in
                store.plan.tracks.firstIndex { $0.id == id }
            } ?? location.trackIndex

            // 锚点必须在**目标轨**内——跨轨锚点无从解释，静默退化成「追加到末尾」是假成功。
            if let beforeID, !store.plan.tracks[destinationIndex].elements.contains(where: { $0.id == beforeID }) {
                return ToolEnvelope.error("锚点元素 \(args.beforeElementID ?? "") 不在目标轨内，请用 get_plan 确认元素与轨道")
            }

            // 链式轨不接受 at（位置由顺序推出，两个事实源会打架）。
            let destinationIsAbsolute = store.plan.tracks[destinationIndex].placement == .absolute
            if args.at != nil, !destinationIsAbsolute {
                return ToolEnvelope.error("目标轨是链式轨，不能指定 at；请用 beforeElementID 做相对定位")
            }

            let result = store.apply { plan in
                guard let from = plan.tracks.firstIndex(where: { $0.elements.contains { $0.id == movedID } }),
                      let fi = plan.tracks[from].elements.firstIndex(where: { $0.id == movedID }) else { return }
                var element = plan.tracks[from].elements.remove(at: fi)

                let destination = targetTrackID.flatMap { id in
                    plan.tracks.firstIndex { $0.id == id }
                } ?? from

                // 绝对定位轨用 at；链式轨的 at 恒为 nil。
                element.at = plan.tracks[destination].placement == .absolute ? (args.at ?? element.at) : nil

                if let beforeID,
                   let anchor = plan.tracks[destination].elements.firstIndex(where: { $0.id == beforeID }) {
                    plan.tracks[destination].elements.insert(element, at: anchor)
                } else {
                    plan.tracks[destination].elements.append(element)
                }
            }

            return ToolEnvelope.applied(result) { plan in
                let trackID = plan.tracks.first { $0.elements.contains { $0.id == movedID } }?.id.uuidString ?? ""
                return Payload(elementID: args.elementID, trackID: trackID,
                               renderedDuration: plan.renderedDuration)
            }
        }
    }
}

struct RemoveClipTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "remove_clip"
    let description = "删除元素。主轨（链式）删中间元素 = 原地留一段等长黑（成片时长不变）；删末尾元素才缩短。绝对定位轨直接移除。"

    @Generable
    struct Args {
        @Guide(description: "要删除的元素 ID")
        let elementID: String
    }

    struct Payload: Encodable {
        let renderedDuration: TimeInterval
        let remainingElements: Int
    }

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        return await context.withStore { store in
            let location: AgentToolCommon.ElementLocation
            switch AgentToolCommon.locate(store.plan, elementID: args.elementID) {
            case .success(let found): location = found
            case .failure(let error): return error.message
            }
            let elementID = store.plan.tracks[location.trackIndex].elements[location.elementIndex].id
            let result = store.apply { plan in
                TrackOperations.removeElement(elementID, in: &plan)
            }
            return ToolEnvelope.applied(result) { plan in
                Payload(renderedDuration: plan.renderedDuration,
                        remainingElements: plan.tracks[location.trackIndex].elements.count)
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
        @Guide(description: "片段元素 ID")
        let elementID: String
        @Guide(description: "变速倍率，0.25–4.0")
        let rate: Double
    }

    struct Payload: Encodable {
        let elementID: String
        let rate: Double
        let renderedDuration: TimeInterval
    }

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        return await context.withStore { store in
            let location: AgentToolCommon.ElementLocation
            switch AgentToolCommon.locate(store.plan, elementID: args.elementID) {
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
                Payload(elementID: args.elementID, rate: args.rate,
                        renderedDuration: plan.renderedDuration)
            }
        }
    }
}

struct SetTransitionTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "set_transition"
    let description = "设置或移除片段尾部的转场。dissolve 与相邻片段全额重叠（扣总时长）；fade 不重叠。转场时长不能超过相邻两段中较短者的输出时长。只对主轨（链式轨）有意义。"

    @Generable
    struct Args {
        @Guide(description: "片段元素 ID（转场挂在该片段尾部，最后一段不能挂转场）")
        let elementID: String
        @Guide(description: "转场类型：dissolve / fade / none（none = 移除转场）")
        let type: String
        @Guide(description: "转场时长（秒），type 为 none 时忽略，缺省 0.5")
        let duration: Double?
    }

    struct Payload: Encodable {
        let elementID: String
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
            switch AgentToolCommon.locate(store.plan, elementID: args.elementID) {
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
                Payload(elementID: args.elementID, renderedDuration: plan.renderedDuration)
            }
        }
    }
}

// MARK: - 字幕工具

struct SetCaptionTrackTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "set_caption_track"
    let description = "导入外挂字幕（仅 SRT 文件）并展开为逐句 cue，fileName 未登记时自动登记。enabled=false 关闭字幕显示。已有字幕轨则整体替换。"

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
        let cueCount: Int
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
                let captionTrack = plan.tracks.first { $0.kind == .caption }
                let settings = captionTrack.map(CaptionFeature.settings(of:))
                return Payload(captionAssetID: settings?.sourceAssetID?.uuidString ?? "",
                               isEnabled: settings?.isEnabled ?? false,
                               cueCount: captionTrack?.elements.count ?? 0)
            }
        }
    }
}

struct SetCaptionTextTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "set_caption_text"
    let description = "修改单条字幕 cue 的文本（字幕已逐句化，文本进 plan）。用 get_plan 的元素视图拿到字幕 cue 的 elementID。"

    @Generable
    struct Args {
        @Guide(description: "字幕 cue 的元素 ID")
        let elementID: String
        @Guide(description: "新的字幕文本")
        let text: String
    }

    struct Payload: Encodable {
        let elementID: String
    }

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        return await context.withStore { store in
            let location: AgentToolCommon.ElementLocation
            switch AgentToolCommon.locate(store.plan, elementID: args.elementID) {
            case .success(let found): location = found
            case .failure(let error): return error.message
            }
            guard case .content(let payload) = store.plan.tracks[location.trackIndex]
                    .elements[location.elementIndex].content,
                  payload.value is CaptionCuePayload else {
                return ToolEnvelope.error("元素 \(args.elementID) 不是字幕 cue，无法改文本")
            }
            let result = store.apply { plan in
                guard case .content(let p) = plan.tracks[location.trackIndex]
                        .elements[location.elementIndex].content,
                      var cue = p.value as? CaptionCuePayload else { return }
                cue.text = args.text
                plan.tracks[location.trackIndex].elements[location.elementIndex].content =
                    .content(TrackPayload(cue))
            }
            return ToolEnvelope.applied(result) { _ in
                Payload(elementID: args.elementID)
            }
        }
    }
}

// MARK: - 轨工具

struct AddTrackTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "add_track"
    let description = "新增一条轨，返回新轨 ID。kind 如 video（叠加视频轨）/ caption（字幕轨）；placement 只支持 absolute（叠加轨，主轨唯一不可新增）。"

    @Generable
    struct Args {
        @Guide(description: "轨道类型：video / caption")
        let kind: String
        @Guide(description: "定位方式，缺省 absolute（叠加轨）。chained 仅主轨，不可新增。")
        let placement: String?
        @Guide(description: "轨名（可选，便于人读）")
        let name: String?
    }

    struct Payload: Encodable {
        let trackID: String
        let kind: String
    }

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        let kind = TrackKind(rawValue: args.kind)
        guard TrackFeatureRegistry.feature(for: kind) != nil else {
            return ToolEnvelope.error("未注册的轨道类型 '\(args.kind)'")
        }
        let placement = TrackPlacement(rawValue: args.placement ?? TrackPlacement.absolute.rawValue)
        guard let placement else {
            return ToolEnvelope.error("未知的 placement '\(args.placement ?? "")'；支持：absolute")
        }
        guard placement == .absolute else {
            return ToolEnvelope.error("只能新增绝对定位轨（主轨唯一且已存在）")
        }
        let track = PlanTrack(kind: kind, name: args.name, placement: placement)
        return await context.withStore { store in
            let result = store.apply { plan in plan.tracks.append(track) }
            return ToolEnvelope.applied(result) { _ in
                Payload(trackID: track.id.uuidString, kind: kind.rawValue)
            }
        }
    }
}

struct RemoveTrackTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "remove_track"
    let description = "删除一条轨（连同其元素）。不能删除主轨。"

    @Generable
    struct Args {
        @Guide(description: "要删除的轨道 ID")
        let trackID: String
    }

    struct Payload: Encodable {
        let trackID: String
    }

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        return await context.withStore { store in
            guard let index = AgentToolCommon.trackIndex(store.plan, trackID: args.trackID) else {
                return ToolEnvelope.error("找不到轨道 \(args.trackID)，请先用 get_plan 获取当前轨道 ID")
            }
            guard store.plan.tracks[index].id != store.plan.primaryTrackID else {
                return ToolEnvelope.error("不能删除主轨")
            }
            let result = store.apply { plan in
                plan.tracks.remove(at: index)
            }
            return ToolEnvelope.applied(result) { _ in
                Payload(trackID: args.trackID)
            }
        }
    }
}

struct MoveTrackTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "move_track"
    let description = "调整轨道顺序（数组下标，0 起）。轨序影响叠加轨的绘制层序（越靠后越在上层）。"

    @Generable
    struct Args {
        @Guide(description: "要移动的轨道 ID")
        let trackID: String
        @Guide(description: "目标下标（0 起）")
        let toIndex: Int
    }

    struct Payload: Encodable {
        let trackOrder: [String]
    }

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        return await context.withStore { store in
            guard let index = AgentToolCommon.trackIndex(store.plan, trackID: args.trackID) else {
                return ToolEnvelope.error("找不到轨道 \(args.trackID)，请先用 get_plan 获取当前轨道 ID")
            }
            guard store.plan.tracks.indices.contains(args.toIndex) else {
                return ToolEnvelope.error("目标下标 \(args.toIndex) 越界（当前共 \(store.plan.tracks.count) 条轨）")
            }
            let result = store.apply { plan in
                let track = plan.tracks.remove(at: index)
                plan.tracks.insert(track, at: args.toIndex)
            }
            return ToolEnvelope.applied(result) { plan in
                Payload(trackOrder: plan.tracks.map { $0.id.uuidString })
            }
        }
    }
}

struct SetTrackFlagsTool: DefensiveAgentTool {
    let context: AgentRunContext
    let name = "set_track_flags"
    let description = "设置轨道的静音 / 隐藏 / 锁定标记。只传需要改的字段。"

    @Generable
    struct Args {
        @Guide(description: "轨道 ID")
        let trackID: String
        @Guide(description: "是否静音；不传则不改")
        let muted: Bool?
        @Guide(description: "是否隐藏；不传则不改")
        let hidden: Bool?
        @Guide(description: "是否锁定；不传则不改")
        let locked: Bool?
    }

    struct Payload: Encodable {
        let trackID: String
        let isMuted: Bool
        let isHidden: Bool
        let isLocked: Bool
    }

    func call(parsed args: Args) async throws -> String {
        if let limit = AgentToolCommon.stepLimitIfExceeded(context) { return limit }
        guard args.muted != nil || args.hidden != nil || args.locked != nil else {
            return ToolEnvelope.error("至少要给 muted / hidden / locked 其中之一")
        }
        return await context.withStore { store in
            guard let index = AgentToolCommon.trackIndex(store.plan, trackID: args.trackID) else {
                return ToolEnvelope.error("找不到轨道 \(args.trackID)，请先用 get_plan 获取当前轨道 ID")
            }
            let result = store.apply { plan in
                if let muted = args.muted { plan.tracks[index].isMuted = muted }
                if let hidden = args.hidden { plan.tracks[index].isHidden = hidden }
                if let locked = args.locked { plan.tracks[index].isLocked = locked }
            }
            return ToolEnvelope.applied(result) { plan in
                let track = plan.tracks[index]
                return Payload(trackID: args.trackID, isMuted: track.isMuted,
                               isHidden: track.isHidden, isLocked: track.isLocked)
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
            MoveElementTool(context: context),
            RemoveClipTool(context: context),
            SetSpeedTool(context: context),
            SetTransitionTool(context: context),
            SetCaptionTrackTool(context: context),
            SetCaptionTextTool(context: context),
            AddTrackTool(context: context),
            RemoveTrackTool(context: context),
            MoveTrackTool(context: context),
            SetTrackFlagsTool(context: context),
            SnapshotTool(context: context),
        ]
    }
}
