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
            .call(parsed: .init(fileName: "clip1.mp4", rangeStart: 0, rangeEnd: 1, speed: nil))
        XCTAssertEqual(try decodeEnvelope(result).status, "ok")
        let plan = await context.plan
        XCTAssertEqual(plan.clips.count, 4)
        // 复用登记，不重复追加
        XCTAssertEqual(plan.assets.count, 4)
        XCTAssertEqual(plan.clips.last?.assetID, SamplePlan.assetID1)
    }

    func testAddClipMissingFileReturnsError() async throws {
        let context = makeContext()
        let result = try await AddClipTool(context: context)
            .call(parsed: .init(fileName: "nope.mp4", rangeStart: 0, rangeEnd: 1, speed: nil))
        let envelope = try decodeEnvelope(result)
        XCTAssertEqual(envelope.status, "error")
        XCTAssertTrue(envelope.message?.contains("素材文件不存在") == true)
        let plan = await context.plan
        XCTAssertEqual(plan.clips.count, 3, "失败不留痕")
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
            .call(parsed: .init(fileName: absolutePath, rangeStart: 0, rangeEnd: 2, speed: 1.5))
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
            .call(parsed: .init(fileName: "clip1.mp4", rangeStart: 0, rangeEnd: 99, speed: nil))
        let envelope = try decodeEnvelope(result)
        XCTAssertEqual(envelope.status, "error")
        XCTAssertTrue(envelope.issues?.contains { $0.path == "clips[3].range" } == true)
        let plan = await context.plan
        XCTAssertEqual(plan.clips.count, 3, "校验失败不落 plan")
    }

    // MARK: - split_clip

    func testSplitClipKeepsSpeedAndMovesTransition() async throws {
        let context = makeContext()
        // clip1: range 0...3, speed 1.0, transitionAfter dissolve 0.5
        let result = try await SplitClipTool(context: context)
            .call(parsed: .init(clipID: clip1, at: 1.5))
        XCTAssertEqual(try decodeEnvelope(result).status, "ok")

        let plan = await context.plan
        let clips = plan.clips
        XCTAssertEqual(clips.count, 4)
        XCTAssertEqual(clips[0].range, 0...1.5)
        XCTAssertNil(clips[0].transitionAfter, "前半段不再挂转场")
        XCTAssertEqual(clips[1].range, 1.5...3)
        XCTAssertEqual(clips[1].transitionAfter, .dissolve(duration: 0.5), "转场归后半段尾部")
        XCTAssertNotEqual(clips[1].id, clips[0].id)
    }

    func testSplitClipAtBoundaryReturnsError() async throws {
        let context = makeContext()
        let result = try await SplitClipTool(context: context)
            .call(parsed: .init(clipID: clip1, at: 3.0))
        XCTAssertEqual(try decodeEnvelope(result).status, "error")
        let plan = await context.plan
        XCTAssertEqual(plan.clips.count, 3)
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
        let plan = await context.plan
        XCTAssertEqual(plan.clips[0].range, 1...2.5)
        XCTAssertEqual(plan.renderedDuration, 8.0, accuracy: 0.001)
    }

    func testTrimClipEmptyRangeFailsValidation() async throws {
        let context = makeContext()
        let result = try await TrimClipTool(context: context)
            .call(parsed: .init(clipID: clip1, rangeStart: 2, rangeEnd: 1))
        XCTAssertEqual(try decodeEnvelope(result).status, "error")
        let plan = await context.plan
        XCTAssertEqual(plan.clips[0].range, 0...3, "失败不留痕")
    }

    func testMoveClipReorders() async throws {
        let context = makeContext()
        let result = try await MoveClipTool(context: context)
            .call(parsed: .init(clipID: clip3, toIndex: 0))
        XCTAssertEqual(try decodeEnvelope(result).status, "ok")
        let plan = await context.plan
        XCTAssertEqual(plan.clips.map(\.assetID),
                       [SamplePlan.assetID3, SamplePlan.assetID1, SamplePlan.assetID2])
    }

    func testMoveClipWithTransitionToLastFails() async throws {
        let context = makeContext()
        // clip1 挂着 dissolve，移到最后一段会被校验拦下（最后一段不能挂转场）
        let result = try await MoveClipTool(context: context)
            .call(parsed: .init(clipID: clip1, toIndex: 2))
        let envelope = try decodeEnvelope(result)
        XCTAssertEqual(envelope.status, "error")
        XCTAssertTrue(envelope.issues?.contains { $0.path.contains("transitionAfter") } == true)
    }

    func testRemoveLastRemainingClipFails() async throws {
        let plan = EditPlan(assets: SamplePlan.make().assets,
                            clips: [SamplePlan.make().clips[2]])
        let context = makeContext(plan: plan)
        let result = try await RemoveClipTool(context: context)
            .call(parsed: .init(clipID: clip3))
        XCTAssertEqual(try decodeEnvelope(result).status, "error")
        let resultingPlan = await context.plan
        XCTAssertEqual(resultingPlan.clips.count, 1)
    }

    // MARK: - set_speed / set_transition

    func testSetSpeedOutOfRangeFails() async throws {
        let context = makeContext()
        let result = try await SetSpeedTool(context: context)
            .call(parsed: .init(clipID: clip1, rate: 5.0))
        let envelope = try decodeEnvelope(result)
        XCTAssertEqual(envelope.status, "error")
        XCTAssertTrue(envelope.issues?.contains { $0.path == "clips[0].speed" } == true)
    }

    func testSetTransitionAndRemove() async throws {
        let context = makeContext()
        var result = try await SetTransitionTool(context: context)
            .call(parsed: .init(clipID: clip2, type: "fade", duration: 0.3))
        XCTAssertEqual(try decodeEnvelope(result).status, "ok")
        var plan = await context.plan
        XCTAssertEqual(plan.clips[1].transitionAfter, .fade(duration: 0.3))

        result = try await SetTransitionTool(context: context)
            .call(parsed: .init(clipID: clip2, type: "none", duration: nil))
        XCTAssertEqual(try decodeEnvelope(result).status, "ok")
        plan = await context.plan
        XCTAssertNil(plan.clips[1].transitionAfter)
    }

    func testSetTransitionUnknownTypeReturnsError() async throws {
        let context = makeContext()
        let result = try await SetTransitionTool(context: context)
            .call(parsed: .init(clipID: clip1, type: "zip", duration: nil))
        XCTAssertEqual(try decodeEnvelope(result).status, "error")
    }

    // MARK: - set_captions

    func testSetCaptionsUpdatesStyle() async throws {
        let context = makeContext()
        let result = try await SetCaptionsTool(context: context)
            .call(parsed: .init(fileName: "sample.srt", fontSize: 30, isBold: false, enabled: true))
        XCTAssertEqual(try decodeEnvelope(result).status, "ok")
        let plan = await context.plan
        XCTAssertEqual(plan.captions?.style, CaptionStyle(fontSize: 30, isBold: false))
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
