import AnyLanguageModel
import Foundation
import XCTest

@testable import JangyAgent
@testable import JangyCore
@testable import JangyTestSupport

/// 连续对话 session：transcript 跨 send 保留、外部修改提示注入、工具计数逐 send 重置。
/// 用 StubLanguageModel（LanguageModel 协议开放可 stub）不打真实 API。
final class EditAgentSessionTests: XCTestCase {

    /// 罐头响应 stub：每次 respond 弹出下一条脚本化文本，记录 prompt 与 transcript 规模。
    final class StubLanguageModel: LanguageModel, @unchecked Sendable {
        struct RecordedRequest {
            let promptText: String
            let transcriptCount: Int
        }
        private(set) var requests: [RecordedRequest] = []
        private var script: [String]

        init(script: [String]) { self.script = script }

        func respond<Content>(within session: LanguageModelSession, to prompt: Prompt,
                              generating type: Content.Type, includeSchemaInPrompt: Bool,
                              options: GenerationOptions) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
            requests.append(RecordedRequest(promptText: prompt.description,
                                            transcriptCount: session.transcript.count))
            let text = script.isEmpty ? "（stub 脚本耗尽）" : script.removeFirst()
            let content = text as! Content  // 测试只驱动 String 响应
            return LanguageModelSession.Response(
                content: content,
                rawContent: GeneratedContent(text),
                transcriptEntries: []
            )
        }

        func streamResponse<Content>(within session: LanguageModelSession, to prompt: Prompt,
                                     generating type: Content.Type, includeSchemaInPrompt: Bool,
                                     options: GenerationOptions) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
            fatalError("测试不走流式")
        }
    }

    /// 线程不安全但够用的测试事件收集器。
    final class UnsafeEventLog: @unchecked Sendable {
        private(set) var events: [String] = []
        func append(_ event: AgentEvent) {
            let data = try? JSONEncoder().encode(event)
            events.append(String(decoding: data ?? Data(), as: UTF8.self))
        }
    }

    private func makeSession(script: [String], context: AgentRunContext)
        -> (EditAgentSession, StubLanguageModel, UnsafeEventLog) {
        let stub = StubLanguageModel(script: script)
        let log = UnsafeEventLog()
        let llmSession = LanguageModelSession(
            model: stub,
            tools: AgentToolSet.make(context: context),
            instructions: AgentPromptBuilder.instructions(hasInitialPlan: true)
        )
        let session = EditAgentSession(
            context: context,
            configuration: AgentRunConfiguration(model: "stub", apiKey: "stub"),
            session: llmSession,
            onEvent: { log.append($0) }
        )
        return (session, stub, log)
    }

    private func makeContext() -> AgentRunContext {
        // 去掉字幕轨：字幕是绝对定位轨，clip 变速会缩短主轨、使越界的 cue 被校验拦下。
        var plan = SamplePlan.make()
        plan.tracks.removeAll { $0.kind == .caption }
        return AgentRunContext(plan: plan,
                               resolver: AssetResolver(directory: URL(fileURLWithPath: "/tmp/jangy-nonexistent-assets")),
                               framesDirectory: FileManager.default.temporaryDirectory)
    }

    func testTranscriptPersistsAcrossSends() async throws {
        let context = makeContext()
        let (session, stub, _) = makeSession(script: ["第一次收尾", "第二次收尾"], context: context)
        try await session.send("第一条指令")
        try await session.send("第二条指令")
        XCTAssertEqual(stub.requests.count, 2)
        XCTAssertGreaterThan(stub.requests[1].transcriptCount, stub.requests[0].transcriptCount,
                             "第二次 send 的 transcript 包含第一次的对话历史")
    }

    func testExternalModificationInjectsHint() async throws {
        let context = makeContext()
        let (session, stub, _) = makeSession(script: ["收尾一", "收尾二"], context: context)
        try await session.send("第一条指令")
        // 模拟用户在会话间隙手动编辑（直接改共享 store）
        await context.withStore { store in
            _ = store.apply { $0.updatePrimaryClip(at: 0) { $0.speed = .flat(2.0) } }
        }
        try await session.send("第二条指令")
        XCTAssertTrue(stub.requests[1].promptText.contains("手动修改"),
                      "plan 被外部改过 → prompt 注入提示")
        XCTAssertTrue(stub.requests[1].promptText.contains("第二条指令"))
    }

    func testNoHintWhenPlanUntouched() async throws {
        let context = makeContext()
        let (session, stub, _) = makeSession(script: ["收尾一", "收尾二"], context: context)
        try await session.send("第一条指令")
        try await session.send("第二条指令")
        XCTAssertFalse(stub.requests[1].promptText.contains("手动修改"))
    }

    func testSnapshotEventEncoding() throws {
        let data = try JSONEncoder().encode(AgentEvent.snapshot(turn: 2, at: 1.5, path: "/tmp/a.png"))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(#""event":"snapshot""#))
        XCTAssertTrue(json.contains(#""turn":2"#))
        XCTAssertTrue(json.contains(#""at":1.5"#))
        XCTAssertTrue(json.contains(#""path":"\/tmp\/a.png""#))
    }

    func testTurnLimitThrows() async throws {
        let context = makeContext()
        // 空响应脚本：每轮都返回空白 → nudge 一次后抛 emptyResponse
        let (session, _, _) = makeSession(script: ["", ""], context: context)
        do {
            _ = try await session.send("指令")
            XCTFail("应抛出 emptyResponse")
        } catch AgentRunError.emptyResponse {
            // 预期
        }
    }
}
