import XCTest
import JangyCore
import JangyTestSupport
@testable import JangyAgent

/// 多轨 Agent 工具：ID 寻址、轨工具、字幕逐句、绝对时间放置。
final class AgentTrackToolsTests: XCTestCase {

    private func makeContext() throws -> AgentRunContext {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let resolver = try AssetSynthesizer.synthesize(into: dir)
        return AgentRunContext(plan: SamplePlan.make(), resolver: resolver, framesDirectory: dir)
    }

    func testGetPlanExposesFlatElementView() async throws {
        let context = try makeContext()
        let result = try await GetPlanTool(context: context).call(parsed: .init())
        XCTAssertTrue(result.contains("\"elementID\""), "get_plan 应给出扁平元素视图")
        XCTAssertTrue(result.contains("\"trackID\""))
        XCTAssertTrue(result.contains("\"payloadType\""))
    }

    func testMoveElementIsIDBased() async throws {
        let context = try makeContext()
        let plan = await context.plan
        let first = plan.primaryTrack!.elements[0].id
        let last = plan.primaryTrack!.elements[2].id

        let result = try await MoveElementTool(context: context).call(parsed: .init(
            elementID: first.uuidString, toTrackID: nil,
            beforeElementID: last.uuidString, at: nil))
        XCTAssertTrue(result.contains("\"status\":\"ok\""))

        let after = await context.plan
        XCTAssertEqual(after.primaryTrack!.elements[1].id, first)
    }

    func testAddTrackCreatesOverlayVideoTrack() async throws {
        let context = try makeContext()
        let result = try await AddTrackTool(context: context).call(parsed: .init(
            kind: "video", placement: "absolute", name: nil))
        XCTAssertTrue(result.contains("\"status\":\"ok\""))
        let plan = await context.plan
        XCTAssertEqual(plan.tracks.filter { $0.kind == .video }.count, 2)
    }

    func testAddClipToOverlayTrackRequiresAt() async throws {
        let context = try makeContext()
        _ = try await AddTrackTool(context: context).call(parsed: .init(
            kind: "video", placement: "absolute", name: nil))
        let plan = await context.plan
        let overlayID = plan.tracks.filter { $0.kind == .video }[1].id

        let missingAt = try await AddClipTool(context: context).call(parsed: .init(
            fileName: "clip1.mp4", rangeStart: 0, rangeEnd: 2, speed: nil, duration: nil,
            trackID: overlayID.uuidString, at: nil))
        XCTAssertTrue(missingAt.contains("\"status\":\"error\""), "绝对轨必须给 at")
        XCTAssertTrue(missingAt.contains("at"))

        let withAt = try await AddClipTool(context: context).call(parsed: .init(
            fileName: "clip1.mp4", rangeStart: 0, rangeEnd: 2, speed: nil, duration: nil,
            trackID: overlayID.uuidString, at: 1.0))
        XCTAssertTrue(withAt.contains("\"status\":\"ok\""))

        // 钉住落点：片段确实进了**叠加轨**、且 at == 1.0（否则「忽略 trackID 落到主轨」也能骗过上面那条）
        let after = await context.plan
        let overlay = after.tracks.first { $0.id == overlayID }!
        XCTAssertEqual(overlay.elements.count, 1)
        XCTAssertEqual(overlay.elements.last?.at, 1.0)
        XCTAssertEqual(after.primaryTrack!.elements.count, 3, "主轨没被误加")
    }

    func testMoveElementToAbsoluteTrackWithoutAtFails() async throws {
        let context = try makeContext()
        _ = try await AddTrackTool(context: context).call(parsed: .init(
            kind: "video", placement: "absolute", name: nil))
        let plan = await context.plan
        let overlayID = plan.tracks.filter { $0.kind == .video }[1].id
        let clip = plan.primaryTrack!.elements[0].id

        // 链式轨元素没有 at，移到绝对轨又不给 at → 会被放到 t=0，必须报错而非静默成功
        let result = try await MoveElementTool(context: context).call(parsed: .init(
            elementID: clip.uuidString, toTrackID: overlayID.uuidString,
            beforeElementID: nil, at: nil))
        XCTAssertTrue(result.contains("\"status\":\"error\""), "移到绝对轨缺 at 应报错")

        let after = await context.plan
        XCTAssertEqual(after.tracks.first { $0.id == overlayID }!.elements.count, 0, "失败不留痕")
    }

    func testSplitOverlayClipPreservesAbsolutePosition() async throws {
        let context = try makeContext()
        _ = try await AddTrackTool(context: context).call(parsed: .init(
            kind: "video", placement: "absolute", name: nil))
        var plan = await context.plan
        let overlayID = plan.tracks.filter { $0.kind == .video }[1].id
        _ = try await AddClipTool(context: context).call(parsed: .init(
            fileName: "clip1.mp4", rangeStart: 0, rangeEnd: 2, speed: nil, duration: nil,
            trackID: overlayID.uuidString, at: 1.0))
        plan = await context.plan
        let overlayClip = plan.tracks.first { $0.id == overlayID }!.elements[0].id

        let result = try await SplitClipTool(context: context).call(parsed: .init(
            elementID: overlayClip.uuidString, at: 1.0))
        XCTAssertTrue(result.contains("\"status\":\"ok\""))

        // 前半段沿用原位 1.0，后半段顺延前半段的输出时长（1s）→ 2.0（不是都塌到 0）
        let after = await context.plan
        let elements = after.tracks.first { $0.id == overlayID }!.elements
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements[0].at, 1.0)
        XCTAssertEqual(elements[1].at ?? -1, 2.0, accuracy: 0.001)
    }

    func testRemoveMiddleGapShortensViaTool() async throws {
        let context = try makeContext()
        // 删中间内容元素 → 留 gap（时长不变）
        let middle = await context.plan.primaryTrack!.elements[1].id
        _ = try await RemoveClipTool(context: context).call(parsed: .init(elementID: middle.uuidString))
        var plan = await context.plan
        guard case .gap = plan.primaryTrack!.elements[1].content else { return XCTFail("应变成 gap") }
        let withGap = plan.renderedDuration

        // 再删那个 gap → 合上（后续前移）。样例的字幕轨末端 9s 会触发尾部补 gap，
        // 故这里断言「该 gap 元素真的消失」而非元素总数（缩短本身由 TrackOperationsTests 在无字幕轨的 plan 上钉）。
        let gapID = plan.primaryTrack!.elements[1].id
        let result = try await RemoveClipTool(context: context).call(parsed: .init(elementID: gapID.uuidString))
        XCTAssertTrue(result.contains("\"status\":\"ok\""))
        plan = await context.plan
        XCTAssertFalse(plan.primaryTrack!.elements.contains { $0.id == gapID },
                       "gap 被真正移除（不是换成等长 gap 的 no-op）")
        XCTAssertLessThan(plan.renderedDuration, withGap, "删 gap 才缩短成片")
    }

    func testRemoveTrackRefusesPrimary() async throws {
        let context = try makeContext()
        let primaryID = await context.plan.primaryTrackID.uuidString
        let refused = try await RemoveTrackTool(context: context).call(parsed: .init(trackID: primaryID))
        XCTAssertTrue(refused.contains("\"status\":\"error\""))
        XCTAssertTrue(refused.contains("主轨"))

        // 非主轨可删
        _ = try await AddTrackTool(context: context).call(parsed: .init(
            kind: "video", placement: "absolute", name: nil))
        let overlayID = await context.plan.tracks.filter { $0.kind == .video }[1].id.uuidString
        let removed = try await RemoveTrackTool(context: context).call(parsed: .init(trackID: overlayID))
        XCTAssertTrue(removed.contains("\"status\":\"ok\""))
        let after = await context.plan
        XCTAssertEqual(after.tracks.filter { $0.kind == .video }.count, 1)
    }

    func testMoveTrackReorders() async throws {
        let context = try makeContext()
        _ = try await AddTrackTool(context: context).call(parsed: .init(
            kind: "video", placement: "absolute", name: nil))
        var plan = await context.plan
        let overlayID = plan.tracks.filter { $0.kind == .video }[1].id
        XCTAssertEqual(plan.tracks.last?.id, overlayID, "新轨追加在末尾")

        let result = try await MoveTrackTool(context: context).call(parsed: .init(
            trackID: overlayID.uuidString, toIndex: 0))
        XCTAssertTrue(result.contains("\"status\":\"ok\""))
        plan = await context.plan
        XCTAssertEqual(plan.tracks.first?.id, overlayID)
    }

    func testSetTrackFlags() async throws {
        let context = try makeContext()
        let captionID = await context.plan.tracks.first { $0.kind == .caption }!.id.uuidString
        let result = try await SetTrackFlagsTool(context: context).call(parsed: .init(
            trackID: captionID, muted: true, hidden: nil, locked: true))
        XCTAssertTrue(result.contains("\"status\":\"ok\""))

        let after = await context.plan
        let caption = after.tracks.first { $0.kind == .caption }!
        XCTAssertTrue(caption.isMuted)
        XCTAssertTrue(caption.isLocked)
        XCTAssertFalse(caption.isHidden, "未传的字段不改")
    }

    func testAddTrackRejectsUnregisteredKind() async throws {
        let context = try makeContext()
        let result = try await AddTrackTool(context: context).call(parsed: .init(
            kind: "sticker", placement: "absolute", name: nil))
        XCTAssertTrue(result.contains("\"status\":\"error\""))
    }

    func testAddClipWithoutTrackIDGoesToPrimary() async throws {
        let context = try makeContext()
        let result = try await AddClipTool(context: context).call(parsed: .init(
            fileName: "clip1.mp4", rangeStart: 0, rangeEnd: 2, speed: nil, duration: nil,
            trackID: nil, at: nil))
        XCTAssertTrue(result.contains("\"status\":\"ok\""))
        let plan = await context.plan
        XCTAssertEqual(plan.primaryTrack!.elements.count, 4)
    }

    func testRemoveClipLeavesGapAndKeepsDuration() async throws {
        let context = try makeContext()
        let before = await context.plan.renderedDuration
        let removedDuration = await context.plan.primaryTrack!.elements[1].duration
        let middle = await context.plan.primaryTrack!.elements[1].id

        let result = try await RemoveClipTool(context: context).call(parsed: .init(
            elementID: middle.uuidString))
        XCTAssertTrue(result.contains("\"status\":\"ok\""))

        let after = await context.plan
        guard case .gap(let gapDuration) = after.primaryTrack!.elements[1].content else {
            return XCTFail("中间元素应变成 gap")
        }
        XCTAssertEqual(gapDuration, removedDuration, accuracy: 0.001, "gap 保留被删元素的时长")
        // 「不缩短」而非「不变」：样例 clip1 挂着 dissolve，删中间元素后紧邻变成 gap、
        // 转场悬空被归一化清掉 → 少了 0.5 的重叠，成片反而长 0.5s（有意的取舍，见 Task 14）。
        XCTAssertGreaterThanOrEqual(after.renderedDuration, before, "删除不缩短成片")
    }

    func testSetCaptionTextUpdatesCue() async throws {
        let context = try makeContext()
        let plan = await context.plan
        let cueID = plan.tracks.first { $0.kind == .caption }!.elements[0].id

        let result = try await SetCaptionTextTool(context: context).call(parsed: .init(
            elementID: cueID.uuidString, text: "改过的字幕"))
        XCTAssertTrue(result.contains("\"status\":\"ok\""))

        let after = await context.plan
        let cue = after.tracks.first { $0.kind == .caption }!.elements[0]
        guard case .content(let payload) = cue.content,
              let value = payload.value as? CaptionCuePayload else { return XCTFail("payload 类型不对") }
        XCTAssertEqual(value.text, "改过的字幕")
    }

    func testValidationIssuesCarryElementID() async throws {
        let context = try makeContext()
        let plan = await context.plan
        let clipID = plan.primaryTrack!.elements[0].id

        let result = try await SetSpeedTool(context: context).call(parsed: .init(
            elementID: clipID.uuidString, rate: 99))
        XCTAssertTrue(result.contains("\"status\":\"error\""))
        XCTAssertTrue(result.contains(clipID.uuidString), "issues 应带出出错的元素 ID")
    }
}
