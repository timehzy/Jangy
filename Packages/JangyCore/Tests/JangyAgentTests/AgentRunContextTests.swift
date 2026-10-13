import Foundation
import XCTest

@testable import JangyAgent
@testable import JangyCore
@testable import JangyTestSupport

/// AgentRunContext 注入化：共享 store、调度器、didApply 联动、步数计数重置。
final class AgentRunContextTests: XCTestCase {

    private func makeStore() -> EditStore {
        EditStore(initial: SamplePlan.make())
    }

    func testInjectedStoreIsShared() async {
        let store = makeStore()
        let context = AgentRunContext(
            store: store,
            resolver: AssetResolver(directory: URL(fileURLWithPath: "/tmp/jangy-nonexistent-assets")),
            framesDirectory: FileManager.default.temporaryDirectory
        )
        await context.withStore { s in
            _ = s.apply { $0.clips[0].speed = .flat(2.0) }
        }
        XCTAssertEqual(store.plan.clips[0].speed, .flat(2.0), "写入直达注入的共享 store")
        XCTAssertEqual(store.historyCount, 2, "共享 store 的撤销栈同步增长")
    }

    func testDidApplyFiresOnPlanChangeOnly() async {
        let store = makeStore()
        // 依赖 Direct 调度器同执行域同步执行；换 MainActorStoreScheduler 会变真竞争
        nonisolated(unsafe) var fired: [EditPlan] = []
        let context = AgentRunContext(
            store: store,
            resolver: AssetResolver(directory: URL(fileURLWithPath: "/tmp/jangy-nonexistent-assets")),
            framesDirectory: FileManager.default.temporaryDirectory,
            didApply: { fired.append($0) }
        )
        _ = await context.plan  // 纯读：不触发
        XCTAssertTrue(fired.isEmpty)
        await context.withStore { s in
            _ = s.apply { $0.clips[0].speed = .flat(2.0) }
        }
        XCTAssertEqual(fired.count, 1, "plan 变化触发一次 didApply")
        await context.withStore { s in
            _ = s.apply { $0.clips[0].speed = .flat(99) }  // 校验失败，plan 不变
        }
        XCTAssertEqual(fired.count, 1, "失败 apply 不触发 didApply")
    }

    func testToolCallCountReset() {
        let context = AgentRunContext(
            plan: SamplePlan.make(),
            resolver: AssetResolver(directory: URL(fileURLWithPath: "/tmp/jangy-nonexistent-assets")),
            framesDirectory: FileManager.default.temporaryDirectory,
            maxToolCalls: 2
        )
        XCTAssertTrue(context.admitToolCall())
        XCTAssertTrue(context.admitToolCall())
        XCTAssertFalse(context.admitToolCall(), "超限拒绝")
        context.resetToolCallCount()
        XCTAssertTrue(context.admitToolCall(), "重置后恢复放行")
    }

    func testMainActorSchedulerRunsOnMainThread() async {
        let store = makeStore()
        let context = AgentRunContext(
            store: store,
            resolver: AssetResolver(directory: URL(fileURLWithPath: "/tmp/jangy-nonexistent-assets")),
            framesDirectory: FileManager.default.temporaryDirectory,
            scheduler: MainActorStoreScheduler()
        )
        let onMain = await context.withStore { _ in Thread.isMainThread }
        XCTAssertTrue(onMain)
    }
}
