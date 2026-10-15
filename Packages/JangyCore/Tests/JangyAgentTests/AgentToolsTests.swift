import AnyLanguageModel
import Foundation
import XCTest

@testable import JangyAgent
@testable import JangyCore
@testable import JangyTestSupport

/// 工具层测试：不碰 LLM，直接驱动工具实现，断言 plan 变化与错误回喂信封。
final class AgentToolsTests: XCTestCase {

    // MARK: - 信封解码辅助

    private struct Envelope: Decodable {
        let status: String
        let message: String?
        let issues: [ValidationIssue]?
    }

    private func decodeEnvelope(_ json: String) throws -> Envelope {
        try JSONDecoder().decode(Envelope.self, from: Data(json.utf8))
    }

    private func makeContext(plan: EditPlan = SamplePlan.make(), maxToolCalls: Int = 30) -> AgentRunContext {
        AgentRunContext(
            plan: plan,
            resolver: AssetResolver(directory: URL(fileURLWithPath: "/tmp/jangy-nonexistent-assets")),
            framesDirectory: FileManager.default.temporaryDirectory,
            maxToolCalls: maxToolCalls
        )
    }

    // 样例工程的固定 clip ID（SamplePlan.make()）
    private let clip1 = "11111111-1111-1111-1111-111111111111"
    private let clip2 = "22222222-2222-2222-2222-222222222222"
    private let clip3 = "33333333-3333-3333-3333-333333333333"

    // 主轨读取/构造辅助（v4：片段在主轨元素里）
    private func primaryElements(_ plan: EditPlan) -> [PlanElement] { plan.primaryTrack?.elements ?? [] }
    private func primaryClips(_ plan: EditPlan) -> [PlanClip] {
        primaryElements(plan).compactMap { element in
            guard case .content(let payload) = element.content else { return nil }
            return payload.value as? PlanClip
        }
    }
    private func sampleClips() -> [PlanClip] { primaryClips(SamplePlan.make()) }
    private func makePlan(assets: [AssetItem], clips: [PlanClip]) -> EditPlan {
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: clips.map { PlanElement(content: .content(TrackPayload($0))) })
        return EditPlan(assets: assets, tracks: [primary], primaryTrackID: primary.id)
    }

    // MARK: - 读工具

    func testGetPlanReturnsRenderedDuration() async throws {
        let context = makeContext()
        let result = try await GetPlanTool(context: context).call(parsed: .init())
        let envelope = try decodeEnvelope(result)
        XCTAssertEqual(envelope.status, "ok")
        let plan = await context.plan
        // 样例锚点：3/1 + 3/0.5 + 2/2 − dissolve 0.5 = 9.5
        XCTAssertEqual(plan.renderedDuration, 9.5, accuracy: 0.001)
    }

    func testListAssetsReturnsRegistry() async throws {
        let context = makeContext()
        let result = try await ListAssetsTool(context: context).call(parsed: .init())
        let envelope = try decodeEnvelope(result)
        XCTAssertEqual(envelope.status, "ok")
        let assets = (await context.plan).assets
        XCTAssertEqual(assets.count, 4)
    }

    // MARK: - add_clip

    func testAddClipReusesRegisteredAsset() async throws {
        let context = makeContext()
        let result = try await AddClipTool(context: context)
            .call(parsed: .init(fileName: "clip1.mp4", rangeStart: 0, rangeEnd: 1, speed: nil, duration: nil))
        XCTAssertEqual(try decodeEnvelope(result).status, "ok")
        let plan = await context.plan
        XCTAssertEqual(primaryElements(plan).count, 4)
        // 复用登记，不重复追加
        XCTAssertEqual(plan.assets.count, 4)
        XCTAssertEqual(primaryClips(plan).last?.assetID, SamplePlan.assetID1)
    }

    func testAddClipMissingFileReturnsError() async throws {
        let context = makeContext()
        let result = try await AddClipTool(context: context)
            .call(parsed: .init(fileName: "nope.mp4", rangeStart: 0, rangeEnd: 1, speed: nil, duration: nil))
        let envelope = try decodeEnvelope(result)
        XCTAssertEqual(envelope.status, "error")
        XCTAssertTrue(envelope.message?.contains("素材文件不存在") == true)
        let plan = await context.plan
        XCTAssertEqual(primaryElements(plan).count, 3, "失败不留痕")
    }

    func testAddClipRegistersAndProbesRealFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jangy-agent-test-\(UUID().uuidString)", isDirectory: true)
        let resolver = try AssetSynthesizer.synthesize(into: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let context = AgentRunContext(plan: SamplePlan.make(), resolver: resolver,
                                      framesDirectory: dir, maxToolCalls: 30)
        // 换个登记表里没有的文件名引用同一份素材文件不行——用绝对路径直引（AssetItem 支持 "/" 前缀）
        let absolutePath = resolver.directory.appendingPathComponent("clip1.mp4").path
        let result = try await AddClipTool(context: context)
            .call(parsed: .init(fileName: absolutePath, rangeStart: 0, rangeEnd: 2, speed: 1.5, duration: nil))
        XCTAssertEqual(try decodeEnvelope(result).status, "ok")
        let plan = await context.plan
        XCTAssertEqual(plan.assets.count, 5, "未登记素材在同一次编辑内登记")
        let registered = plan.assets.first { $0.fileName == absolutePath }
        XCTAssertEqual(registered?.duration ?? 0, 4.0, accuracy: 0.5, "登记时探测元数据")
    }

    func testAddClipValidationFailureFeedsBackIssues() async throws {
        let context = makeContext()
        // clip1 素材时长 4s，range 越界
        let result = try await AddClipTool(context: context)
            .call(parsed: .init(fileName: "clip1.mp4", rangeStart: 0, rangeEnd: 99, speed: nil, duration: nil))
        let envelope = try decodeEnvelope(result)
        XCTAssertEqual(envelope.status, "error")
        XCTAssertTrue(envelope.issues?.contains { $0.path == "tracks[0].elements[3].source.range" } == true)
        let plan = await context.plan
        XCTAssertEqual(primaryElements(plan).count, 3, "校验失败不落 plan")
    }

    func testAddImageClipRegistersAndProbesRealFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jangy-agent-img-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 造一张 PNG
        let pngURL = dir.appendingPathComponent("photo.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
            .write(to: pngURL)

        let context = AgentRunContext(plan: SamplePlan.make(),
                                      resolver: AssetResolver(directory: dir),
                                      framesDirectory: dir, maxToolCalls: 30)
        let result = try await AddClipTool(context: context)
            .call(parsed: .init(fileName: "photo.png", rangeStart: nil, rangeEnd: nil, speed: nil, duration: 4.0))
        XCTAssertEqual(try decodeEnvelope(result).status, "ok")
        let plan = await context.plan
        XCTAssertEqual(primaryElements(plan).count, 4)
        XCTAssertEqual(primaryClips(plan).last?.source, .still(duration: 4.0))
        let registered = plan.assets.first { $0.fileName == "photo.png" }
        XCTAssertEqual(registered?.kind, .image)
        XCTAssertEqual(registered?.pixelWidth, 1)
    }

    func testAddImageClipDefaultsToThreeSeconds() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jangy-agent-img-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
            .write(to: dir.appendingPathComponent("photo.png"))

        let context = AgentRunContext(plan: SamplePlan.make(),
                                      resolver: AssetResolver(directory: dir),
                                      framesDirectory: dir, maxToolCalls: 30)
        let result = try await AddClipTool(context: context)
            .call(parsed: .init(fileName: "photo.png", rangeStart: nil, rangeEnd: nil, speed: nil, duration: nil))
        XCTAssertEqual(try decodeEnvelope(result).status, "ok")
        let plan = await context.plan
        XCTAssertEqual(primaryClips(plan).last?.source, .still(duration: 3.0))
    }

    func testAddVideoClipStillRequiresRange() async throws {
        let context = makeContext()
        let result = try await AddClipTool(context: context)
            .call(parsed: .init(fileName: "clip1.mp4", rangeStart: nil, rangeEnd: nil, speed: nil, duration: nil))
        let envelope = try decodeEnvelope(result)
        XCTAssertEqual(envelope.status, "error")
        XCTAssertTrue(envelope.message?.contains("rangeStart") == true)
    }

    func testAddClipRejectsAudioAsset() async throws {
        // 已登记的音频素材：add_clip 应拒绝（音频后置），不得崩溃
        let audio = AssetItem(kind: .audio, fileName: "bgm.mp3", duration: 30)
        let plan = makePlan(assets: SamplePlan.make().assets + [audio], clips: sampleClips())
        let context = makeContext(plan: plan)
        let result = try await AddClipTool(context: context)
            .call(parsed: .init(fileName: "bgm.mp3", rangeStart: nil, rangeEnd: nil, speed: nil, duration: nil))
        let envelope = try decodeEnvelope(result)
        XCTAssertEqual(envelope.status, "error")
        XCTAssertTrue(envelope.message?.contains("音频") == true)
        let resultingPlan = await context.plan
        XCTAssertEqual(primaryElements(resultingPlan).count, 3, "失败不留痕")
    }

    // MARK: - split_clip

    func testSplitClipKeepsSpeedAndMovesTransition() async throws {
        let context = makeContext()
        // clip1: range 0...3, speed 1.0, transitionAfter dissolve 0.5
        let result = try await SplitClipTool(context: context)
            .call(parsed: .init(clipID: clip1, at: 1.5))
        XCTAssertEqual(try decodeEnvelope(result).status, "ok")

        let plan = await context.plan
        let elements = primaryElements(plan)
        let clips = primaryClips(plan)
        XCTAssertEqual(clips.count, 4)
        XCTAssertEqual(clips[0].source, .video(0...1.5))
        XCTAssertNil(clips[0].transitionAfter, "前半段不再挂转场")
        XCTAssertEqual(clips[1].source, .video(1.5...3))
        XCTAssertEqual(clips[1].transitionAfter, .dissolve(duration: 0.5), "转场归后半段尾部")
        XCTAssertNotEqual(elements[1].id, elements[0].id)
    }

    func testSplitClipAtBoundaryReturnsError() async throws {
        let context = makeContext()
        let result = try await SplitClipTool(context: context)
            .call(parsed: .init(clipID: clip1, at: 3.0))
        XCTAssertEqual(try decodeEnvelope(result).status, "error")
        let plan = await context.plan
        XCTAssertEqual(primaryElements(plan).count, 3)
    }

    func testUnknownClipIDReturnsError() async throws {
        let context = makeContext()
        let result = try await SetSpeedTool(context: context)
            .call(parsed: .init(clipID: "99999999-9999-9999-9999-999999999999", rate: 2.0))
        XCTAssertEqual(try decodeEnvelope(result).status, "error")
    }

    // MARK: - trim / move / remove

    func testTrimClipUpdatesRange() async throws {
        let context = makeContext()
        let result = try await TrimClipTool(context: context)
            .call(parsed: .init(clipID: clip1, rangeStart: 1, rangeEnd: 2.5))
        XCTAssertEqual(try decodeEnvelope(result).status, "ok")
        let after = await context.plan
        XCTAssertEqual(primaryClips(after)[0].source, .video(1...2.5))
        // trim 后主轨 8.0s，但字幕轨末端 9.0s → apply 自动补尾部 gap 到 9.0（不变式 #2）。
        XCTAssertEqual(after.renderedDuration, 9.0, accuracy: 0.001)
    }

    func testTrimClipEmptyRangeFailsValidation() async throws {
        let context = makeContext()
        let result = try await TrimClipTool(context: context)
            .call(parsed: .init(clipID: clip1, rangeStart: 2, rangeEnd: 1))
        XCTAssertEqual(try decodeEnvelope(result).status, "error")
        let plan = await context.plan
        XCTAssertEqual(primaryClips(plan)[0].source, .video(0...3), "失败不留痕")
    }

    func testMoveClipReorders() async throws {
        let context = makeContext()
        let result = try await MoveClipTool(context: context)
            .call(parsed: .init(clipID: clip3, toIndex: 0))
        XCTAssertEqual(try decodeEnvelope(result).status, "ok")
        let plan = await context.plan
        XCTAssertEqual(primaryClips(plan).map(\.assetID),
                       [SamplePlan.assetID3, SamplePlan.assetID1, SamplePlan.assetID2])
    }

    func testMoveClipWithTransitionToLastClearsTransition() async throws {
        let context = makeContext()
        // clip1 挂着 dissolve，移到最后一段：末位不能挂转场 → 归一化清掉，移动本身成功
        //（EditStore.apply 统一归一化，与删除末位元素同一条路径）。
        let result = try await MoveClipTool(context: context)
            .call(parsed: .init(clipID: clip1, toIndex: 2))
        XCTAssertEqual(try decodeEnvelope(result).status, "ok")
        let plan = await context.plan
        XCTAssertEqual(primaryClips(plan).map(\.assetID),
                       [SamplePlan.assetID2, SamplePlan.assetID3, SamplePlan.assetID1])
        XCTAssertNil(primaryClips(plan).last?.transitionAfter, "移到末位的转场被归一化清掉")
    }

    func testRemoveLastRemainingClipFails() async throws {
        let plan = makePlan(assets: SamplePlan.make().assets,
                                        clips: [sampleClips()[2]])
        let context = makeContext(plan: plan)
        let result = try await RemoveClipTool(context: context)
            .call(parsed: .init(clipID: clip3))
        XCTAssertEqual(try decodeEnvelope(result).status, "error")
        let resultingPlan = await context.plan
        XCTAssertEqual(primaryElements(resultingPlan).count, 1)
    }

    // MARK: - set_speed / set_transition

    func testSetSpeedOutOfRangeFails() async throws {
        let context = makeContext()
        let result = try await SetSpeedTool(context: context)
            .call(parsed: .init(clipID: clip1, rate: 5.0))
        let envelope = try decodeEnvelope(result)
        XCTAssertEqual(envelope.status, "error")
        XCTAssertTrue(envelope.issues?.contains { $0.path == "tracks[0].elements[0].speed" } == true)
    }

    func testSetTransitionAndRemove() async throws {
        let context = makeContext()
        var result = try await SetTransitionTool(context: context)
            .call(parsed: .init(clipID: clip2, type: "fade", duration: 0.3))
        XCTAssertEqual(try decodeEnvelope(result).status, "ok")
        var plan = await context.plan
        XCTAssertEqual(primaryClips(plan)[1].transitionAfter, .fade(duration: 0.3))

        result = try await SetTransitionTool(context: context)
            .call(parsed: .init(clipID: clip2, type: "none", duration: nil))
        XCTAssertEqual(try decodeEnvelope(result).status, "ok")
        plan = await context.plan
        XCTAssertNil(primaryClips(plan)[1].transitionAfter)
    }

    func testSetTransitionUnknownTypeReturnsError() async throws {
        let context = makeContext()
        let result = try await SetTransitionTool(context: context)
            .call(parsed: .init(clipID: clip1, type: "zip", duration: nil))
        XCTAssertEqual(try decodeEnvelope(result).status, "error")
    }

    // MARK: - set_captions

    func testSetCaptionsUpdatesStyle() async throws {
        // set_captions 现在导入 SRT 逐句展开，需要一个真实素材目录
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jangy-agent-caps-\(UUID().uuidString)", isDirectory: true)
        let resolver = try AssetSynthesizer.synthesize(into: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = AgentRunContext(plan: SamplePlan.make(), resolver: resolver,
                                      framesDirectory: dir, maxToolCalls: 30)
        let result = try await SetCaptionsTool(context: context)
            .call(parsed: .init(fileName: "sample.srt", fontSize: 30, isBold: false, enabled: true))
        XCTAssertEqual(try decodeEnvelope(result).status, "ok")
        let plan = await context.plan
        let captionTrack = plan.tracks.first { $0.kind == .caption }!
        let settings = CaptionFeature.settings(of: captionTrack)
        XCTAssertEqual(settings.fontSize, 30)
        XCTAssertEqual(settings.isBold, false)
        XCTAssertEqual(settings.isEnabled, true)
        XCTAssertEqual(captionTrack.elements.count, 3, "SRT 逐句展开成 cue 元素")
    }

    func testSetCaptionsRejectsNonSRT() async throws {
        let context = makeContext()
        let result = try await SetCaptionsTool(context: context)
            .call(parsed: .init(fileName: "subs.vtt", fontSize: nil, isBold: nil, enabled: nil))
        XCTAssertEqual(try decodeEnvelope(result).status, "error")
    }

    // MARK: - 步数闸门

    func testStepLimitBlocksFurtherCalls() async throws {
        let context = makeContext(maxToolCalls: 2)
        _ = try await GetPlanTool(context: context).call(parsed: .init())
        _ = try await GetPlanTool(context: context).call(parsed: .init())
        let result = try await GetPlanTool(context: context).call(parsed: .init())
        let envelope = try decodeEnvelope(result)
        XCTAssertEqual(envelope.status, "error")
        XCTAssertTrue(envelope.message?.contains("步数上限") == true)
    }

    // MARK: - 防御性参数解析

    func testMalformedArgumentsReturnErrorEnvelope() async throws {
        let context = makeContext()
        // 模型给出完全不沾边的参数 → 错误信封，不抛错炸轮
        let result = try await SetSpeedTool(context: context).call(arguments: GeneratedContent("bogus"))
        XCTAssertEqual(try decodeEnvelope(result).status, "error")
    }
}
