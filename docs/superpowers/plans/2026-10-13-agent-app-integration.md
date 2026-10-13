# 剪辑 Agent App 接入 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把剪辑 Agent 接进 App：EditStore 合一（共享 store + 分组撤销）、连续对话 session、IM 形态对话 UI、包接线。

**Architecture:** 设计定案见 [spec](../specs/2026-10-13-agent-app-integration-design.md)（六项拍板已 commit）。核心机制：`EditStore` 加分组事务承载「整任务一步撤销」；`AgentRunContext` 改为注入 store + 调度器回跳 MainActor；`EditAgentRunner` 重构为 `EditAgentSession`（LanguageModelSession 长活、transcript 跨 send 保留）；App 侧 `AgentController`（L1）+ `AgentChatView`（L0）。

**Tech Stack:** Swift 6 / SwiftUI / SwiftPM / AnyLanguageModel（`LanguageModelSession.init(model: any LanguageModel)` 接受存在类型，stub 可注入；`Transcript` 是 `RandomAccessCollection`；Anthropic provider 顺序执行工具调用——已核实）。

**通用命令：**
- 测试：`cd Packages/JangyCore && swift test`（111 个既有测试全绿是每次 commit 的底线）
- 单测过滤：`swift test --filter <TestClassName>`
- App 构建：`xcodebuild -project Jangy.xcodeproj -scheme Jangy -destination 'generic/platform=iOS Simulator' build`
- 提交信息用中文，风格参照 `git log`

---

### Task 1: EditStore 分组事务（JangyCore, L2）

**Files:**
- Modify: `Packages/JangyCore/Sources/JangyCore/EditStore.swift`
- Test: `Packages/JangyCore/Tests/JangyCoreTests/EditStoreGroupingTests.swift`（新建）

- [ ] **Step 1: 写失败测试**

新建 `Packages/JangyCore/Tests/JangyCoreTests/EditStoreGroupingTests.swift`：

```swift
import XCTest
@testable import JangyCore

/// 分组事务：组内 apply 照常校验/改 plan 但不压撤销栈；endGrouping 把整组收成一步。
/// 承载「一次 Agent 任务 = 一步撤销」（公约 §2.4 延伸，spec 拍板 #1）。
final class EditStoreGroupingTests: XCTestCase {

    private func initialPlan() -> EditPlan {
        let assetID = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
        return EditPlan(
            assets: [AssetItem(id: assetID, kind: .video, fileName: "clip1.mp4", duration: 4.0)],
            clips: [PlanClip(assetID: assetID, range: 0...3)]
        )
    }

    func testGroupCollapsesMultipleAppliesIntoOneUndoStep() {
        let store = EditStore(initial: initialPlan())
        let baselineCount = store.historyCount
        store.beginGrouping()
        XCTAssertTrue(store.isGrouping)
        store.apply { $0.clips[0].speed = .flat(0.5) }
        store.apply { $0.clips[0].range = 0...2 }
        XCTAssertEqual(store.historyCount, baselineCount, "组内 apply 不压栈")
        store.endGrouping()
        XCTAssertFalse(store.isGrouping)
        XCTAssertEqual(store.historyCount, baselineCount + 1, "整组只压一步")
        store.undo()
        XCTAssertEqual(store.plan.clips[0].speed, .flat(1.0), "一步撤销回退整组")
        XCTAssertEqual(store.plan.clips[0].range, 0...3)
    }

    func testFailedApplyInsideGroupPushesNothing() {
        let store = EditStore(initial: initialPlan())
        let baselineCount = store.historyCount
        store.beginGrouping()
        let result = store.apply { $0.clips[0].speed = .flat(99) }  // 越界，校验失败
        guard case .failure = result else { return XCTFail("应失败") }
        store.endGrouping()
        XCTAssertEqual(store.historyCount, baselineCount, "组内失败 apply 不留痕，空组不压步")
    }

    func testEmptyGroupPushesNothing() {
        let store = EditStore(initial: initialPlan())
        store.beginGrouping()
        store.endGrouping()
        XCTAssertEqual(store.historyCount, 1, "无 apply 的空组不压步")
    }

    func testUndoRedoIgnoredDuringGrouping() {
        let store = EditStore(initial: initialPlan())
        store.apply { $0.clips[0].speed = .flat(2.0) }
        let beforeGroup = store.plan
        store.beginGrouping()
        XCTAssertFalse(store.canUndo, "分组中 canUndo 报 false（UI 禁用绑定）")
        XCTAssertFalse(store.canRedo)
        store.undo()
        store.redo()
        XCTAssertEqual(store.plan, beforeGroup, "分组中 undo/redo 被忽略")
        store.endGrouping()
    }

    func testNestedBeginGroupingIsNoOp() {
        let store = EditStore(initial: initialPlan())
        store.beginGrouping()
        store.beginGrouping()  // 不嵌套：第二次调用无副作用
        store.apply { $0.clips[0].speed = .flat(0.5) }
        store.endGrouping()
        XCTAssertFalse(store.isGrouping)
        store.undo()
        XCTAssertEqual(store.plan.clips[0].speed, .flat(1.0))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd Packages/JangyCore && swift test --filter EditStoreGroupingTests`
Expected: 编译失败（`isGrouping`/`beginGrouping`/`endGrouping` 未定义）

- [ ] **Step 3: 实现分组事务**

`EditStore.swift` 改动（三处）：

1) 新增属性与方法（加在 `historyCount` 之后）：

```swift
    /// 分组事务基线：非 nil 表示处于分组中，组内 apply 不压撤销栈。
    private var groupBase: EditPlan?

    /// 是否处于分组事务中（UI 据此禁用撤销/重做等编辑入口）。
    public var isGrouping: Bool { groupBase != nil }

    /// 开始分组事务：组内 apply 照常校验、照常改 plan，但不压撤销栈；
    /// endGrouping 时若 plan 相对基线有变化，压一个撤销步。
    /// 不嵌套：分组中再次调用为 no-op。
    public func beginGrouping() {
        guard groupBase == nil else { return }
        groupBase = plan
    }

    /// 结束分组事务：plan 有变化则压一步；无变化（空组/全失败）不压。
    public func endGrouping() {
        guard let base = groupBase else { return }
        groupBase = nil
        if plan != base { undoStack.push(plan) }
    }
```

2) `canUndo`/`canRedo` 加分组守卫（分组中 UI 禁用撤销/重做）：

```swift
    public var canUndo: Bool { groupBase == nil && undoStack.canUndo }
    public var canRedo: Bool { groupBase == nil && undoStack.canRedo }
```

3) `apply` 里压栈条件化，`undo`/`redo` 加守卫：

```swift
    @discardableResult
    public func apply(_ mutate: (inout EditPlan) -> Void) -> Result<EditPlan, ValidationFailure> {
        var next = plan
        mutate(&next)
        let issues = validator.validate(next)
        guard issues.isEmpty else { return .failure(ValidationFailure(issues: issues)) }
        if groupBase == nil { undoStack.push(next) }  // 组内不压栈，endGrouping 统一收
        plan = next
        return .success(next)
    }

    public func undo() {
        guard groupBase == nil else { return }
        if let restored = undoStack.undo() { plan = restored }
    }

    public func redo() {
        guard groupBase == nil else { return }
        if let restored = undoStack.redo() { plan = restored }
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd Packages/JangyCore && swift test --filter EditStore`
Expected: EditStoreTests + EditStoreGroupingTests 全 PASS

- [ ] **Step 5: Commit**

```bash
git add Packages/JangyCore/Sources/JangyCore/EditStore.swift Packages/JangyCore/Tests/JangyCoreTests/EditStoreGroupingTests.swift
git commit -m "JangyCore: EditStore 分组事务——组内 apply 不压栈，endGrouping 收成一步（Agent 整任务撤销地基）"
```

---

### Task 2: AgentRunContext 注入化 + 调度器（JangyAgent）

**Files:**
- Modify: `Packages/JangyCore/Sources/JangyAgent/AgentRunContext.swift`（整体重写）
- Test: `Packages/JangyCore/Tests/JangyAgentTests/AgentRunContextTests.swift`（新建）

设计要点（实现时不得偏离）：
- `EditStore` 改为注入；保留 `plan:` 便利构造供 CLI/旧测试。
- `AgentStoreScheduler` 协议：把「访问 store 的闭包」送到 store 所属执行域。闭包类型是 `@Sendable (EditStore) throws -> T`（`T: Sendable`）——App 侧 `MainActor.run` 的 body 是 `@Sendable` 闭包，闭包内只允许捕获 Sendable 值，这是硬约束。
- `withStore` 是唯一的 store 触碰点（读/写复合都在一块内）；块尾比对 plan（`EditPlan` 是 `Equatable`），变了就同步触发 `didApply`。闭包同步、不可 await（snapshot 渲染等异步工作放块外）。
- NSLock 只保留给 `pendingSnapshots`/`toolCallCount` 这两个同步小区间；store 访问串行性依据：Anthropic provider 顺序执行工具调用（已核实 `AnthropicLanguageModel.swift` 里是 for 循环逐个 await）+ MainActor 本身串行。
- `context.plan` 从同步属性改为 async。

- [ ] **Step 1: 写失败测试**

新建 `Packages/JangyCore/Tests/JangyAgentTests/AgentRunContextTests.swift`：

```swift
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
        var fired: [EditPlan] = []
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd Packages/JangyCore && swift test --filter AgentRunContextTests`
Expected: 编译失败（`init(store:...)`/`withStore`/`MainActorStoreScheduler`/`resetToolCallCount` 未定义）

- [ ] **Step 3: 重写 AgentRunContext.swift**

整体替换 `Packages/JangyCore/Sources/JangyAgent/AgentRunContext.swift` 为：

```swift
import Foundation
import JangyCore

/// EditStore 触碰点调度器：把「访问 store 的闭包」送到 store 所属的执行域。
/// CLI/测试 = DirectStoreScheduler 原地直通；App = MainActorStoreScheduler 回跳主 actor
///（共享的 EditStore 被 @Observable/SwiftUI 订阅，变更必须发生在主线程）。
/// 串行性依据：provider 顺序执行工具调用（逐个 await）+ MainActor 本身串行，
/// 因此 store 访问不再需要锁串行化。
public protocol AgentStoreScheduler: Sendable {
    func run<T: Sendable>(on context: AgentRunContext,
                          work: @Sendable (EditStore) throws -> T) async rethrows -> T
}

/// CLI/测试用：当前线程原地执行。
public struct DirectStoreScheduler: AgentStoreScheduler {
    public init() {}
    public func run<T: Sendable>(on context: AgentRunContext,
                                 work: @Sendable (EditStore) throws -> T) async rethrows -> T {
        try work(context.store)
    }
}

/// App 用：回跳 MainActor（共享 AppModel 持有的 EditStore 时必选）。
public struct MainActorStoreScheduler: AgentStoreScheduler {
    public init() {}
    public func run<T: Sendable>(on context: AgentRunContext,
                                 work: @Sendable (EditStore) throws -> T) async rethrows -> T {
        try await MainActor.run { try work(context.store) }
    }
}

/// 单次 Agent 任务的共享态：所有工具执行的出入口。
///
/// EditStore 为注入（App 共享 AppModel 那份；CLI 自建临时份）。
/// store 的唯一触碰点是 withStore——经调度器进入 store 所属执行域，
/// 块尾比对 plan，变了则同步触发 didApply（App 接预览重建 + autosave）。
public final class AgentRunContext: @unchecked Sendable {

    /// 快照帧：snapshot 工具产物，落盘 + 排队等待回喂给模型。
    public struct SnapshotFrame: Sendable {
        public let at: TimeInterval
        public let url: URL
        public let pngData: Data

        public init(at: TimeInterval, url: URL, pngData: Data) {
            self.at = at
            self.url = url
            self.pngData = pngData
        }
    }

    public let resolver: AssetResolver
    /// 快照 PNG 落盘目录（CLI --frames；缺省临时目录）。
    public let framesDirectory: URL
    /// 工具调用步数上限：防自动 tool loop 失控的框架无关兜底。
    public let maxToolCalls: Int
    /// plan 变化回调：在调度块内同步触发（App 侧天然已在 MainActor）。
    public let didApply: (@Sendable (EditPlan) -> Void)?

    /// 仅经 scheduler 触碰；internal 供同模块调度器实现访问。
    let store: EditStore
    private let scheduler: any AgentStoreScheduler

    /// 只护 pendingSnapshots / toolCallCount 两个同步小区间。
    private let lock = NSLock()
    private var pendingSnapshots: [SnapshotFrame] = []
    private var toolCallCount = 0

    public init(store: EditStore, resolver: AssetResolver, framesDirectory: URL,
                maxToolCalls: Int = 30,
                scheduler: any AgentStoreScheduler = DirectStoreScheduler(),
                didApply: (@Sendable (EditPlan) -> Void)? = nil) {
        self.store = store
        self.resolver = resolver
        self.framesDirectory = framesDirectory
        self.maxToolCalls = maxToolCalls
        self.scheduler = scheduler
        self.didApply = didApply
    }

    /// 便利构造（CLI/测试）：自建临时 EditStore，原地直通调度。
    public convenience init(plan: EditPlan, resolver: AssetResolver, framesDirectory: URL,
                            maxToolCalls: Int = 30) {
        self.init(store: EditStore(initial: plan), resolver: resolver,
                  framesDirectory: framesDirectory, maxToolCalls: maxToolCalls)
    }

    /// 当前 plan（经调度器读）。
    public var plan: EditPlan {
        get async { await withStore { $0.plan } }
    }

    /// 调度到 store 执行域执行读/写复合操作；块内 plan 发生变化则在块尾同步触发 didApply。
    /// 注意：闭包同步、不可 await（snapshot 渲染等异步工作放块外做）。
    @discardableResult
    public func withStore<T: Sendable>(_ work: @Sendable (EditStore) throws -> T) async rethrows -> T {
        try await scheduler.run(on: self) { [didApply] store in
            let before = store.plan
            let result = try work(store)
            let after = store.plan
            if after != before { didApply?(after) }
            return result
        }
    }

    /// 步数闸门：每次工具执行前调用；返回 false 表示已超限，工具应返回「请收尾」而不执行。
    public func admitToolCall() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        toolCallCount += 1
        return toolCallCount <= maxToolCalls
    }

    /// 每条指令开始时重置步数计数（上限语义 = 防单次指令失控的兜底，不跨指令累计）。
    public func resetToolCallCount() {
        lock.lock()
        defer { lock.unlock() }
        toolCallCount = 0
    }

    public func enqueueSnapshots(_ frames: [SnapshotFrame]) {
        lock.lock()
        defer { lock.unlock() }
        pendingSnapshots.append(contentsOf: frames)
    }

    /// 取出并清空待回喂快照（outer loop 附图后轮清空）。
    public func drainSnapshots() -> [SnapshotFrame] {
        lock.lock()
        defer { lock.unlock() }
        defer { pendingSnapshots.removeAll() }
        return pendingSnapshots
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

注意：本任务落地后 `AgentTools.swift`（用已删除的 `locked`）与 `AgentCommand.swift`（同步读 `context.plan`）会编译失败，**swift test 此刻跑不了属预期**——编译验证推迟到 Task 3 Step 3，本任务与 Task 3 是一个原子编译单元。

Run: `cd Packages/JangyCore && swift test --filter AgentRunContextTests`
Expected: 编译失败（工具层引用了已删除的 `locked`）——确认报错全部来自 `AgentTools.swift` 的 `locked` 与 `AgentCommand.swift` 的 `context.plan`，而非新代码本身。

- [ ] **Step 5: Commit（与 Task 3 合并提交）**

Task 2 与 Task 3 编译上不可拆分，**合并为一次 commit**（避免中间不可编译提交），在 Task 3 全绿后执行，message 用 Task 3 Step 5 的。

---

### Task 3: 工具层适配 withStore（11 个工具 + 现有测试适配）

**Files:**
- Modify: `Packages/JangyCore/Sources/JangyAgent/AgentTools.swift`
- Modify: `Packages/JangyCore/Tests/JangyAgentTests/AgentToolsTests.swift`、`AgentSnapshotToolTests.swift`

改造规则（三条）：
1. `return context.locked { store in ... }` → `return await context.withStore { store in ... }`（一对一直接替换）。
2. 闭包是 `@Sendable`：禁止捕获后 mutate 局部 `var`（`var outcome: ...!` 模式编译不过）。涉及的工具把「outcome 变量 + payload 构造」全部收进闭包，闭包直接返回信封字符串。
3. `context.plan` 同步读 → `await context.plan`。

逐工具改动清单：

- **GetPlanTool**：`let plan = context.plan` → `let plan = await context.plan`。
- **ListAssetsTool**：`context.plan.assets` → `(await context.plan).assets`。
- **AddClipTool**：`let existing = context.plan.assets.first { ... }` → `let existing = await context.plan.assets.first { ... }`；`return context.locked { store in ... }` 整段替换为：

```swift
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
                let clip = PlanClip(assetID: assetID,
                                    range: args.rangeStart...args.rangeEnd,
                                    speed: .flat(rate))
                plan.clips.append(clip)
            }
            return ToolEnvelope.applied(result) { plan in
                // 从结果 plan 反查刚追加的 clip（末尾）与素材登记状态，避免 @Sendable 闭包捕获可变变量
                let clip = plan.clips.last!
                let registered = plan.assets.first { $0.fileName == asset.fileName }!
                return Payload(clipID: clip.id.uuidString, assetID: registered.id.uuidString,
                               registeredNewAsset: !existingFileNames.contains(asset.fileName),
                               renderedDuration: plan.renderedDuration)
            }
        }
```

其中 `existingFileNames` 在 withStore 之前算好（`Set(context.plan.assets.map(\.fileName))`——用 await 读），`isNew` 语义 = 本次新登记。

- **SplitClipTool**：整段替换为（`secondID` 捕获改为闭包内构造）：

```swift
        return await context.withStore { store in
            let index: Int
            switch AgentToolCommon.clipIndex(store.plan, clipID: args.clipID) {
            case .success(let i): index = i
            case .failure(let error): return error.message
            }
            let clip = store.plan.clips[index]
            guard args.at > clip.range.lowerBound, args.at < clip.range.upperBound else {
                return ToolEnvelope.error("分割点 \(args.at) 须严格落在片段源区间 \(clip.range.lowerBound)–\(clip.range.upperBound) 内")
            }
            let secondID = UUID()
            let result = store.apply { plan in
                var first = plan.clips[index]
                var second = plan.clips[index]
                first.range = clip.range.lowerBound...args.at
                first.transitionAfter = nil
                second.id = secondID
                second.range = args.at...clip.range.upperBound
                plan.clips.replaceSubrange(index...index, with: [first, second])
            }
            return ToolEnvelope.applied(result) { plan in
                Payload(firstClipID: args.clipID, secondClipID: secondID.uuidString,
                        renderedDuration: plan.renderedDuration)
            }
        }
```

（注意原实现有 apply 失败时 `secondID` 已生成但不影响语义的缺陷，新写法天然规避。）

- **TrimClipTool / MoveClipTool / RemoveClipTool / SetSpeedTool / SetTransitionTool**：`return context.locked { store in` → `return await context.withStore { store in`（这些工具的 payload 全部在闭包内构造，无其他改动）。
- **SetCaptionsTool**：`guard context.plan.assets.contains(...)` → `guard await context.plan.assets.contains(...)`；`captionAssetID` 可变捕获收进闭包——整段替换为：

```swift
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
                plan.captions = CaptionTrack(
                    assetID: assetID,
                    isEnabled: args.enabled ?? true,
                    style: CaptionStyle(fontSize: args.fontSize ?? 48, isBold: args.isBold ?? true)
                )
            }
            return ToolEnvelope.applied(result) { plan in
                Payload(captionAssetID: plan.captions?.assetID.uuidString ?? "",
                        isEnabled: plan.captions?.isEnabled ?? false)
            }
        }
```

（`CaptionTrack.assetID` 是公开字段，从结果 plan 反查即可，无需可变捕获。）

- **SnapshotTool**：`let plan = context.plan` → `let plan = await context.plan`（其余不动——`enqueueSnapshots` 仍是同步锁保护）。

- [ ] **Step 1: 适配现有测试的同步读**

`AgentToolsTests.swift` 与 `AgentSnapshotToolTests.swift` 里所有 `context.plan` 同步读改为 `await context.plan`（测试函数已是 async）。逐个 grep 替换：

```bash
grep -n "context.plan" Packages/JangyCore/Tests/JangyAgentTests/*.swift
```

每处 `context.plan.X` → `(await context.plan).X`，`context.plan` 单独赋值 → `await context.plan`。

- [ ] **Step 1b: CLI 同步读适配（一行）**

`Packages/JangyCore/Sources/jangy-cli/AgentCommand.swift` 收尾处：`let finalPlan = context.plan` → `let finalPlan = await context.plan`。（CLI 里的 `EditAgentRunner` 构造此刻仍可编译，重构在 Task 4。）

- [ ] **Step 2: 跑测试确认通过**

Run: `cd Packages/JangyCore && swift test --filter Agent`
Expected: AgentToolsTests（21）+ AgentSnapshotToolTests（3）+ AgentRunContextTests（4）全 PASS

- [ ] **Step 3: 全量回归**

Run: `cd Packages/JangyCore && swift test`
Expected: 111 + 新增 9 = 120 个测试全绿

- [ ] **Step 4: Commit**

```bash
git add Packages/JangyCore/Sources/JangyAgent/AgentRunContext.swift Packages/JangyCore/Sources/JangyAgent/AgentTools.swift Packages/JangyCore/Tests/JangyAgentTests/
git commit -m "JangyAgent: AgentRunContext 注入化 + 工具层适配——共享 EditStore、调度器回跳 MainActor、didApply 联动"
```

---

### Task 4: EditAgentSession（连续对话 session）+ snapshot 事件 + CLI 适配

**Files:**
- Create: `Packages/JangyCore/Sources/JangyAgent/EditAgentSession.swift`（吸收 EditAgentRunner）
- Delete: `Packages/JangyCore/Sources/JangyAgent/EditAgentRunner.swift`
- Modify: `Packages/JangyCore/Sources/JangyAgent/AgentEvent.swift`（加 `.snapshot` 事件）
- Modify: `Packages/JangyCore/Sources/jangy-cli/AgentCommand.swift`
- Test: `Packages/JangyCore/Tests/JangyAgentTests/EditAgentSessionTests.swift`（新建）

- [ ] **Step 1: AgentEvent 加 snapshot 事件**

`AgentEvent.swift`：enum 加 case，CodingKeys 加 `at, path`，encode 加分支：

```swift
    case snapshot(turn: Int, at: TimeInterval, path: String)
```

```swift
    private enum CodingKeys: String, CodingKey {
        case event, instruction, model, hasInitialPlan, turn, content, name, arguments, status, summary, turns, planPath, exported, kind, message, at, path
    }
```

```swift
        case .snapshot(let turn, let at, let path):
            try container.encode("snapshot", forKey: .event)
            try container.encode(turn, forKey: .turn)
            try container.encode(at, forKey: .at)
            try container.encode(path, forKey: .path)
```

（只带路径不带 PNG 数据：事件保持轻量，App 从路径读图，CLI 原样打印。JSONL 纯增量，契约不破坏。）

- [ ] **Step 2: 写失败测试（stub LanguageModel）**

新建 `Packages/JangyCore/Tests/JangyAgentTests/EditAgentSessionTests.swift`：

```swift
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
                rawContent: (try? GeneratedContent(text)) ?? GeneratedContent(properties: [:]),
                transcriptEntries: []
            )
        }

        func streamResponse<Content>(within session: LanguageModelSession, to prompt: Prompt,
                                     generating type: Content.Type, includeSchemaInPrompt: Bool,
                                     options: GenerationOptions) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
            fatalError("测试不走流式")
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

    /// 线程不安全但够用的测试事件收集器。
    final class UnsafeEventLog: @unchecked Sendable {
        private(set) var events: [String] = []
        func append(_ event: AgentEvent) {
            let data = try? JSONEncoder().encode(event)
            events.append(String(decoding: data ?? Data(), as: UTF8.self))
        }
    }

    private func makeContext() -> AgentRunContext {
        AgentRunContext(plan: SamplePlan.make(),
                        resolver: AssetResolver(directory: URL(fileURLWithPath: "/tmp/jangy-nonexistent-assets")),
                        framesDirectory: FileManager.default.temporaryDirectory)
    }

    func testTranscriptPersistsAcrossSends() async throws {
        let context = makeContext()
        let (session, stub, _) = makeSession(script: ["第一次收尾", "第二次收尾"], context: context)
        try await session.send("第一条指令")
        try await session.send("第二条指令")
        XCTAssertEqual(stub.requests.count, 2)
        XCTAssertGreater(stub.requests[1].transcriptCount, stub.requests[0].transcriptCount,
                         "第二次 send 的 transcript 包含第一次的对话历史")
    }

    func testExternalModificationInjectsHint() async throws {
        let context = makeContext()
        let (session, stub, _) = makeSession(script: ["收尾一", "收尾二"], context: context)
        try await session.send("第一条指令")
        // 模拟用户在会话间隙手动编辑（直接改共享 store）
        await context.withStore { store in
            _ = store.apply { $0.clips[0].speed = .flat(2.0) }
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
```

注意：`EditAgentSession` 需要 internal 可注入 session 的构造器（`@testable` 已开）。`GeneratedContent(text)` 若编译不过（String 到 GeneratedContent 的转换 API 名以 `AnyLanguageModel` 实际为准，备选 `GeneratedContent(String)` 或 `text.generatedContent`），以实现期 IDE 补全为准——只影响 stub 的 rawContent 一行。

- [ ] **Step 3: 实现 EditAgentSession，删除 EditAgentRunner**

新建 `Packages/JangyCore/Sources/JangyAgent/EditAgentSession.swift`：

```swift
import AnyLanguageModel
import Foundation
import JangyCore

/// Agent 运行配置。
public struct AgentRunConfiguration: Sendable {
    /// 模型 ID（如 claude-sonnet-5-5）。
    public var model: String
    /// API base URL（缺省官方；公司网关在此覆盖）。
    public var baseURL: URL?
    public var apiKey: String
    /// 最大轮次：一轮 = 一次模型响应（内含的自动 tool loop 不计轮次，另有工具步数上限兜底）。
    /// 按每条指令计（连续对话 session 跨 send 复用，轮次预算不跨指令累计）。
    public var maxTurns: Int
    /// 单次响应 token 上限。思维链模型（如 K2.8 thinking-only）会先烧思考预算，
    /// 框架缺省 1024 极易在思考中途截断 → 空响应静默收尾，必须放大。
    public var maxResponseTokens: Int

    public init(model: String, baseURL: URL? = nil, apiKey: String, maxTurns: Int = 10,
                maxResponseTokens: Int = 32768) {
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.maxTurns = maxTurns
        self.maxResponseTokens = maxResponseTokens
    }
}

public enum AgentRunError: Error, Equatable {
    /// 轮次耗尽仍未收尾（显式报错，不像参考实现那样静默退出）。
    case turnLimitExceeded(turns: Int)
    /// 空响应催促后仍为空（模型静默，通常是 token 预算或端点异常）。
    case emptyResponse
}

/// 编排层：连续对话 session。LanguageModelSession 长活、transcript 跨 send 保留；
/// 每条用户指令一次 send（agent loop 本体：续轮/终止判定/轮次上限/快照回喂/事件发射）。
///
/// 注意 AnyLanguageModel 的 Anthropic provider **不在 respond 内续轮**：
/// 一次 respond = 一次 HTTP 请求，工具执行完（结果入 transcript）即返回，续轮是调用方的职责。
public final class EditAgentSession {
    private let context: AgentRunContext
    private let configuration: AgentRunConfiguration
    private let llmSession: LanguageModelSession
    private let forwarder: EventForwarder
    private let onEvent: (AgentEvent) -> Void
    /// 上次 send 结束时的 plan：新指令发出前比对，变了说明用户在会话间隙手动编辑过（含撤销）。
    private var lastPlanAtSendEnd: EditPlan?

    /// 生产入口：按配置建 Anthropic provider。
    public init(context: AgentRunContext, configuration: AgentRunConfiguration,
                hasInitialPlan: Bool, onEvent: @escaping (AgentEvent) -> Void) {
        let model: AnthropicLanguageModel
        if let baseURL = configuration.baseURL {
            model = AnthropicLanguageModel(baseURL: baseURL, apiKey: configuration.apiKey, model: configuration.model)
        } else {
            model = AnthropicLanguageModel(apiKey: configuration.apiKey, model: configuration.model)
        }
        self.init(context: context, configuration: configuration,
                  session: LanguageModelSession(
                      model: model,
                      tools: AgentToolSet.make(context: context),
                      instructions: AgentPromptBuilder.instructions(hasInitialPlan: hasInitialPlan)),
                  onEvent: onEvent)
    }

    /// 测试入口：注入任意 LanguageModel（stub）组装好的 session。
    init(context: AgentRunContext, configuration: AgentRunConfiguration,
         session: LanguageModelSession, onEvent: @escaping (AgentEvent) -> Void) {
        self.context = context
        self.configuration = configuration
        self.llmSession = session
        self.onEvent = onEvent
        self.forwarder = EventForwarder(onEvent: onEvent)
        session.toolExecutionDelegate = forwarder
    }

    /// 跑一条用户指令，返回消耗轮次。LLM 接入错误原样抛出，由调用方归类。
    @discardableResult
    public func send(_ instruction: String) async throws -> Int {
        context.resetToolCallCount()

        // 外部修改检测：plan 相对上次 send 结束变了 → 提示模型先 get_plan 对齐现状
        var prompt = instruction
        if let last = lastPlanAtSendEnd, await context.plan != last {
            prompt = """
            注意：上次任务结束后时间线被手动修改过。请先调用 get_plan 确认当前状态，再执行用户的新指令。

            用户指令：\(instruction)
            """
        }

        var images: [Transcript.ImageSegment] = []
        var nudged = false
        let options = GenerationOptions(maximumResponseTokens: configuration.maxResponseTokens)
        do {
            for turn in 1...configuration.maxTurns {
                forwarder.beginTurn(turn)
                let response: LanguageModelSession.Response<String>
                if images.isEmpty {
                    response = try await llmSession.respond(to: prompt, options: options)
                } else {
                    response = try await llmSession.respond(to: prompt, images: images, options: options)
                }
                onEvent(.assistant(turn: turn, content: response.content))

                // 终止判定优先级：待回喂快照 > 工具续轮 > 文字收尾 > 空响应催促
                let pending = context.drainSnapshots()
                if !pending.isEmpty {
                    for frame in pending {
                        onEvent(.snapshot(turn: turn, at: frame.at, path: frame.url.path))
                    }
                    images = pending.map { Transcript.ImageSegment(data: $0.pngData, mimeType: "image/png") }
                    prompt = "以上图片是当前时间线在指定时刻的真实渲染画面（导出保真，含字幕烧录）。请检查是否符合用户预期：符合则用文字总结收尾；不符合则继续调用工具修正。"
                    continue
                }

                // 本轮有工具调用 = 结果刚入 transcript、模型还没看到，必须续轮让它消化
                if forwarder.madeToolCallsThisTurn() {
                    images = []
                    prompt = "工具已执行完毕，结果已返回。请继续：任务未完成则继续调用工具，已完成则用文字总结编辑结果。"
                    continue
                }

                let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    lastPlanAtSendEnd = await context.plan
                    return turn
                }

                // 空响应且无工具调用 = 模型静默：催一次，再空显式报错
                guard !nudged else { throw AgentRunError.emptyResponse }
                nudged = true
                prompt = "你的上一次响应为空。请继续完成任务：调用编辑工具，或用文字总结当前编辑结果。"
                images = []
            }
            throw AgentRunError.turnLimitExceeded(turns: configuration.maxTurns)
        } catch {
            lastPlanAtSendEnd = await context.plan
            throw error
        }
    }
}

/// 框架 delegate → AgentEvent 的转发器（事件流的发射点）。
private final class EventForwarder: ToolExecutionDelegate, @unchecked Sendable {
    // —— 从 EditAgentRunner.swift 原样搬入，不改 ——
}
```

`EventForwarder` 整个类从 `EditAgentRunner.swift` 原样搬入（含注释，只把 JSONL 相关注释措辞里的「JSONL 事件流」改为「事件流」）。搬完后 `git rm Packages/JangyCore/Sources/JangyAgent/EditAgentRunner.swift`。

- [ ] **Step 4: CLI 适配**

`AgentCommand.swift` 一处改动——runner 构造改为 session（`context.plan` 的 async 适配已在 Task 3 Step 1b 完成）：

```swift
        let session = EditAgentSession(
            context: context,
            configuration: AgentRunConfiguration(
                model: model,
                baseURL: baseURL.map { URL(string: $0) } ?? nil,
                apiKey: apiKey,
                maxTurns: maxTurns
            ),
            hasInitialPlan: plan != nil,
            onEvent: emit
        )

        let turns: Int
        do {
            turns = try await session.send(instruction: instruction)
```

（`AgentRunContext(plan:...)` 便利构造保留，CLI 这处不用改。）

- [ ] **Step 5: 跑测试确认通过**

Run: `cd Packages/JangyCore && swift test`
Expected: 全绿（120 + session 4 = 124 个）

- [ ] **Step 6: CLI 冒烟（不打真实 API 的部分）**

```bash
cd Packages/JangyCore
swift run jangy-cli genassets && swift run jangy-cli sample > /tmp/draft.json
swift run jangy-cli validate /tmp/draft.json --assets ./Assets
```

Expected: 与主线行为一致（stdout 结构化 JSON，exit 0）。

- [ ] **Step 7: Commit**

```bash
git add Packages/JangyCore/Sources/JangyAgent/ Packages/JangyCore/Sources/jangy-cli/AgentCommand.swift Packages/JangyCore/Tests/JangyAgentTests/EditAgentSessionTests.swift
git commit -m "JangyAgent: EditAgentRunner 重构为 EditAgentSession——连续对话 session 复用、外部修改提示注入、snapshot 事件、逐指令步数重置"
```

---

### Task 5: 包接线（Package.swift + Xcode 工程）

**Files:**
- Modify: `Packages/JangyCore/Package.swift`
- Modify: `Jangy.xcodeproj/project.pbxproj`

- [ ] **Step 1: Package.swift 加 library product**

products 数组里 `jangy-cli` 行之后加：

```swift
        // 剪辑 Agent：App 链接入口（CLI 走 executable 直接依赖 target，不经 product）
        .library(name: "JangyAgent", targets: ["JangyAgent"]),
```

- [ ] **Step 2: pbxproj 加 JangyAgent 链接（四处编辑）**

`Jangy.xcodeproj/project.pbxproj`（新 UUID 用 `44E03CF33077C1E70009DB63`/`44E03CF43077C1E70009DB63`，与现有 ID 同前缀风格）：

1) PBXBuildFile section（现有 JangyCore 行之后）：

```
		44E03CF43077C1E70009DB63 /* JangyAgent in Frameworks */ = {isa = PBXBuildFile; productRef = 44E03CF33077C1E70009DB63 /* JangyAgent */; };
```

2) Frameworks build phase `files = (` 里加一行：

```
				44E03CF43077C1E70009DB63 /* JangyAgent in Frameworks */,
```

3) PBXNativeTarget 的 `packageProductDependencies = (` 里加：

```
				44E03CF33077C1E70009DB63 /* JangyAgent */,
```

4) XCSwiftPackageProductDependency section 末尾（`End` 行之前）加：

```
		44E03CF33077C1E70009DB63 /* JangyAgent */ = {
			isa = XCSwiftPackageProductDependency;
			productName = JangyAgent;
		};
```

- [ ] **Step 3: 验证 App 构建**

Run: `xcodebuild -project Jangy.xcodeproj -scheme Jangy -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED。若报「no such product JangyAgent」，检查 Step 1 的 product 名与 Step 2 的 productName 拼写一致。

- [ ] **Step 4: Commit**

```bash
git add Packages/JangyCore/Package.swift Jangy.xcodeproj/project.pbxproj
git commit -m "包接线：JangyAgent 加 library product，App target 链接"
```

---

### Task 6: AgentCredentials + AgentController + AppModel 接线（App 壳 L1）

**Files:**
- Create: `Jangy/AgentCredentials.swift`
- Create: `Jangy/AgentController.swift`
- Modify: `Jangy/AppModel.swift`

- [ ] **Step 1: AgentCredentials（凭据本地文件注入）**

新建 `Jangy/AgentCredentials.swift`：

```swift
import Foundation

/// Agent 凭据：开发期从 Application Support/Jangy/agent-config.json 读取（gitignore 手放播种，
/// 与 genassets 同套路）。产品化方案（自备 key / 网关代理 / App Attest）发布前再议。
/// JSON 格式：{"baseURL": "...", "model": "...", "apiKey": "..."}（baseURL 可缺省）
struct AgentCredentials: Codable {
    var baseURL: String?
    var model: String
    var apiKey: String

    static var fileName: String { "agent-config.json" }

    /// 缺失/损坏一律返回 nil（入口禁用态由调用方呈现），不炸启动。
    static func load(from directory: URL) -> AgentCredentials? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AgentCredentials.self, from: data)
    }
}
```

- [ ] **Step 2: AgentController**

新建 `Jangy/AgentController.swift`：

```swift
import Foundation
import JangyAgent
import JangyCore

/// 对话流条目：IM 形态渲染的数据源。
struct AgentChatItem: Identifiable {
    enum Content {
        case user(String)
        case assistant(String)
        /// 工具卡片：name + 参数摘要；status 由 toolResult 事件回填（pending → ok/error）
        case tool(name: String, summary: String, status: Status)
        case snapshot(path: String, at: TimeInterval)
        case done(turns: Int)
        case error(String)
        case stopped
    }
    enum Status { case pending, ok, error }
    let id = UUID()
    var content: Content
}

/// 剪辑 Agent 的 App 侧装配（L1）：session 生命周期、分组撤销边界、事件流 → 对话模型。
/// 连续对话：session lazy 创建后长活（内存态，不持久化——spec 拍板 #5）。
@MainActor
@Observable
final class AgentController {
    private(set) var items: [AgentChatItem] = []
    private(set) var isRunning = false
    let isConfigured: Bool

    private let store: EditStore
    private let resolver: AssetResolver
    private let credentials: AgentCredentials?
    /// plan 变化联动（AppModel 注入：预览重建 + autosave）
    private let onAppliedEdit: () -> Void
    private var session: EditAgentSession?
    private var runTask: Task<Void, Never>?
    /// 待回填状态的工具卡片：key = turn:name
    private var pendingToolItems: [String: UUID] = [:]

    init(store: EditStore, resolver: AssetResolver, credentials: AgentCredentials?,
         onAppliedEdit: @escaping () -> Void) {
        self.store = store
        self.resolver = resolver
        self.credentials = credentials
        self.isConfigured = credentials != nil
        self.onAppliedEdit = onAppliedEdit
    }

    func send(_ text: String) {
        let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !isRunning, let credentials else { return }
        items.append(AgentChatItem(content: .user(instruction)))
        isRunning = true
        // 整任务一步撤销（spec 拍板 #1）：分组边界 = 一条指令的完整 run
        store.beginGrouping()
        let session = self.session ?? makeSession(credentials: credentials)
        self.session = session
        runTask = Task { @MainActor in
            defer {
                store.endGrouping()
                isRunning = false
            }
            do {
                let turns = try await session.send(instruction)
                items.append(AgentChatItem(content: .done(turns: turns)))
            } catch is CancellationError {
                items.append(AgentChatItem(content: .stopped))
            } catch AgentRunError.turnLimitExceeded(let limit) {
                items.append(AgentChatItem(content: .error("轮次耗尽（\(limit)）仍未收尾，已生效的编辑可用「撤销」整体回退")))
            } catch {
                items.append(AgentChatItem(content: .error("LLM 接入错误：\(error.localizedDescription)")))
            }
        }
    }

    func stop() {
        runTask?.cancel()
    }

    private func makeSession(credentials: AgentCredentials) -> EditAgentSession {
        let context = AgentRunContext(
            store: store,
            resolver: resolver,
            framesDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("jangy-agent-frames", isDirectory: true),
            scheduler: MainActorStoreScheduler(),
            didApply: { [onAppliedEdit] _ in
                // didApply 在 MainActor 调度块内同步触发，直接联动即可
                MainActor.assumeIsolated { onAppliedEdit() }
            }
        )
        return EditAgentSession(
            context: context,
            configuration: AgentRunConfiguration(
                model: credentials.model,
                baseURL: credentials.baseURL.flatMap { URL(string: $0) },
                apiKey: credentials.apiKey
            ),
            hasInitialPlan: !store.plan.clips.isEmpty,
            onEvent: { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
        )
    }

    /// AgentEvent → 对话流条目（事件从后台线程来，已在 send/makeSession 处归一 MainActor）。
    private func handle(_ event: AgentEvent) {
        switch event {
        case .start:
            break
        case .assistant(_, let content):
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { items.append(AgentChatItem(content: .assistant(text))) }
        case .toolCall(let turn, let name, let arguments):
            let item = AgentChatItem(content: .tool(name: name,
                                                    summary: Self.truncate(arguments),
                                                    status: .pending))
            items.append(item)
            pendingToolItems["\(turn):\(name)"] = item.id
        case .toolResult(let turn, let name, let status, let summary):
            let key = "\(turn):\(name)"
            guard let id = pendingToolItems.removeValue(forKey: key),
                  let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].content = .tool(name: name, summary: Self.truncate(summary),
                                         status: status == "ok" ? .ok : .error)
        case .snapshot(_, let at, let path):
            items.append(AgentChatItem(content: .snapshot(path: path, at: at)))
        case .done:
            break  // CLI 契约事件；App 侧由 send 的返回路径追加 done 卡片
        case .error(let kind, let message):
            items.append(AgentChatItem(content: .error("[\(kind.rawValue)] \(message)")))
        }
    }

    private static func truncate(_ text: String, limit: Int = 140) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
```

注意 `MainActor.assumeIsolated`：didApply 只在 `MainActorStoreScheduler` 的块内触发（本控制器固定用这个调度器），假设成立；若崩溃说明调度器被换成直通——这是编程错误，早炸早好。

- [ ] **Step 3: AppModel 接线**

`AppModel.swift` 改动：

1) 加属性（`lastIssues` 声明附近）：

```swift
    /// 剪辑 Agent 入口（L1）：sheet 对话 UI 的数据源；凭据缺失时 isConfigured = false。
    private(set) var agent: AgentController!
```

2) `init` 末尾（`verifyDraftIntegrity()` 之前）加：

```swift
        agent = AgentController(
            store: store,
            resolver: resolver,
            credentials: AgentCredentials.load(from: resolver.directory),
            onAppliedEdit: { [weak self] in self?.handleAgentAppliedEdit() }
        )
```

3) 加联动方法（`edit(_:)` 之后）：

```swift
    /// Agent 工具每步编辑落 plan 后的联动：与手动编辑同一条下行路径（预览重建 + 防抖落盘）。
    private func handleAgentAppliedEdit() {
        lastIssues = nil
        player.rebuild()
        scheduleAutosave()
    }
```

- [ ] **Step 4: 验证 App 构建**

Run: `xcodebuild -project Jangy.xcodeproj -scheme Jangy -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Jangy/AgentCredentials.swift Jangy/AgentController.swift Jangy/AppModel.swift
git commit -m "App: AgentController 落地——session 装配、整任务分组撤销、事件流归一 MainActor、didApply 联动预览与落盘"
```

---

### Task 7: AgentChatView + ContentView 集成（App 壳 L0）

**Files:**
- Create: `Jangy/AgentChatView.swift`
- Modify: `Jangy/ContentView.swift`

UI 定案（spec 拍板 #4 细化）：自定义头部（左关闭 / 中拖拽示意 / 右全屏切换）；三档 detent（露出操作条 / 露出时间线 / 只露预览，默认只露预览）+ 全屏态；IM 对话布局（agent 居左 / user 居右 / 新消息底部进入）；输入框右侧发送按钮，运行中变停止。

iOS 17 约束：`PresentationDetent.custom` 是 iOS 18+，三档用 `.fraction` 近似——`0.35`（露出操作条）/ `0.55`（露出时间线）/ `0.8`（只露预览），数值在模拟器调校，语义目标以 spec 为准。

- [ ] **Step 1: AgentChatView**

新建 `Jangy/AgentChatView.swift`：

```swift
import SwiftUI
import JangyCore

/// 剪辑 Agent 对话页（L0）：半屏 sheet，IM 形态对话流 + 底部输入框。
/// 零业务逻辑：所有状态来自 AgentController，操作只有 send/stop/dismiss。
struct AgentChatView: View {
    var controller: AgentController
    @Environment(\.dismiss) private var dismiss

    /// 档位：small = 露出操作条，medium = 露出时间线，half = 只露预览（默认），full = 全屏
    @State private var detent: PresentationDetent = .fraction(0.8)
    @State private var input = ""

    private static let small = PresentationDetent.fraction(0.35)
    private static let medium = PresentationDetent.fraction(0.55)
    private static let half = PresentationDetent.fraction(0.8)

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
            inputBar
        }
        .presentationDetents([Self.small, Self.medium, Self.half, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled)
        .presentationDragIndicator(.visible)
    }

    /// 自定义头部：左关闭（回主编辑页）/ 中标题 / 右全屏切换（全屏态变退出全屏，回半屏档）
    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold))
            }
            Spacer()
            Text("剪辑 Agent").font(.subheadline.weight(.semibold))
            Spacer()
            Button {
                withAnimation { detent = (detent == .large) ? Self.half : .large }
            } label: {
                Image(systemName: detent == .large ? "arrow.down.right.and.arrow.up.left"
                                                   : "arrow.up.left.and.arrow.down.right")
                    .font(.body.weight(.semibold))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.items) { item in
                        bubble(for: item).id(item.id)
                    }
                }
                .padding()
            }
            // 新消息从底部进入：追加后自动滚到底（iMessage 同款）
            .onChange(of: controller.items.count) {
                if let last = controller.items.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(for item: AgentChatItem) -> some View {
        switch item.content {
        case .user(let text):
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
            }
        case .assistant(let text):
            HStack {
                Text(text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 16))
                Spacer(minLength: 60)
            }
        case .tool(let name, let summary, let status):
            HStack(spacing: 6) {
                Image(systemName: iconName(for: status))
                    .foregroundStyle(color(for: status))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.caption.weight(.semibold).monospaced())
                    Text(summary).font(.caption2.monospaced())
                        .foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer()
            }
            .padding(8)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
        case .snapshot(let path, let at):
            VStack(alignment: .leading, spacing: 4) {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable().scaledToFit()
                        .frame(maxWidth: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text(String(format: "快照 @ %.1fs", at)).font(.caption2).foregroundStyle(.secondary)
            }
        case .done(let turns):
            Label("任务完成（\(turns) 轮；可用「撤销」整体回退）", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red)
        case .stopped:
            Label("已停止", systemImage: "stop.circle")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func iconName(for status: AgentChatItem.Status) -> String {
        switch status {
        case .pending: "circle.dotted"
        case .ok: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    private func color(for status: AgentChatItem.Status) -> Color {
        switch status {
        case .pending: .secondary
        case .ok: .green
        case .error: .red
        }
    }

    /// 底部输入框：运行中发送按钮变停止按钮（spec 拍板 #4）
    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("描述你想要的剪辑…", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(controller.isRunning)
            if controller.isRunning {
                Button { controller.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
            } else {
                Button {
                    controller.send(input)
                    input = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
```

- [ ] **Step 2: ContentView 集成**

`ContentView.swift` 改动三处：

1) `@State` 加 `showAgent`：

```swift
    @State private var showAgent = false
```

2) 操作条加 Agent 按钮（「导出」按钮之前），运行中禁用编辑入口：

```swift
                Button("撤销") { model.undo() }.disabled(!model.store.canUndo || model.agent.isRunning)
                Button("重做") { model.redo() }.disabled(!model.store.canRedo || model.agent.isRunning)
```
（`store.canUndo/canRedo` 在分组中已报 false，这里的 `|| model.agent.isRunning` 是双保险——按钮 disabled 态在 run 开始前就位。）

```swift
                Menu("导入") {
                    Button("从相册导入") { showPhotoPicker = true }
                    Button("从文件导入") { showFilesPicker = true }
                }
                .disabled(model.importProgress != nil || model.agent.isRunning)
                Button("新建") { showResetConfirm = true }.disabled(model.agent.isRunning)
                Button("Agent") { showAgent = true }
                    .disabled(!model.agent.isConfigured)
                Button("导出") { showExportPanel = true }
                    .disabled(model.exportProgress != nil || model.agent.isRunning)
```

3) 凭据缺失提示 + sheet 挂载（其他 sheet 修饰符旁边）：

```swift
            if !model.agent.isConfigured {
                Text("未配置 Agent 凭据：把 agent-config.json 放入 Application Support/Jangy/")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
```

```swift
        .sheet(isPresented: $showAgent) {
            AgentChatView(controller: model.agent)
        }
```

- [ ] **Step 3: 验证 App 构建**

Run: `xcodebuild -project Jangy.xcodeproj -scheme Jangy -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Jangy/AgentChatView.swift Jangy/ContentView.swift
git commit -m "App: Agent 对话 UI——半屏 sheet 三档 + 全屏切换，IM 对话流（气泡/工具卡片/快照图），运行中停止按钮"
```

---

### Task 8: 文档回填 + 全量验收

**Files:**
- Modify: `docs/architecture-covenant.md`（§1 组件表 + §6.2 白名单）
- Modify: `docs/roadmap-path-a.md`（v1 任务进度）
- Modify: `AGENTS.md`（凭据播种说明，若涉及）

- [ ] **Step 1: 公约回填（两处）**

1) §1 现有组件表，`AgentToolSet` / `EditAgentRunner` / `AgentRunContext` 行的组件列改为：

```
| `AgentToolSet` / `EditAgentSession` / `AgentRunContext`（`JangyAgent` target） | L1 headless 消费方 | 剪辑 Agent：工具层（原子编辑 → `EditStore.apply`，校验失败结构化回喂）+ 编排层（连续对话 session，agent loop + snapshot 视觉自检）；App 与 CLI 共用 |
```

2) §6.2 零 loading 白名单第 2 条改为：

```
2. **零 loading 白名单**：允许出现 loading 的操作仅有——素材导入（探测/转码）、导出、剪辑 Agent 任务。**一切编辑操作禁止 loading**。剪辑 Agent 任务的呈现方式：不以 spinner 呈现，以流式对话流呈现（assistant 文字/工具卡片实时下落）；任务期间编辑控件锁定（sheet 遮挡 + disabled）；预览随每步编辑实时重建。
```

- [ ] **Step 2: roadmap v1 任务进度追加**

`docs/roadmap-path-a.md`「v1 任务进度」节，`剪辑 Agent headless 链路` 条目之后追加：

```markdown
- [x] **剪辑 Agent App 接入**（✅ 2026-10-13，spec：[agent-app-integration-design](superpowers/specs/2026-10-13-agent-app-integration-design.md)）：
  - **EditStore 合一**：AgentRunContext 改为注入共享 store + AgentStoreScheduler 调度器（App 回跳 MainActor，CLI 直通）；didApply 回调接预览重建 + autosave，Agent 每步编辑实时落到预览
  - **整任务一步撤销**：EditStore 分组事务（beginGrouping/endGrouping），组内逐工具校验反馈保留、撤销栈只压一步（公约 §2.4 延伸拍板）
  - **连续对话**：EditAgentRunner 重构为 EditAgentSession——LanguageModelSession 长活、transcript 跨 send 保留可追问；会话间隙 plan 被手动改过则新指令注入「先 get_plan 对齐」提示；工具步数上限逐指令重置
  - **UI**：半屏 sheet（三档：露操作条/露时间线/只露预览 + 全屏态）+ iMessage 式对话流（气泡/工具卡片/snapshot 图）+ 运行中停止按钮；`AgentEvent` 增 `.snapshot` 事件（纯增量，CLI 契约不破）
  - **凭据**：本期本地文件注入（Application Support/Jangy/agent-config.json），产品化发布前再议
  - **公约回填**：§6.2 白名单登记「剪辑 Agent 任务」（流式呈现，不以 spinner 呈现）
  - 验收：124 测试全绿 + App 模拟器构建通过 + CLI 冒烟无回归 + 真 key 冒烟（同 session 连发两条指令验证追问）
```

- [ ] **Step 3: AGENTS.md 播种说明**

AGENTS.md「常用命令」节的模拟器播种注释之后加一行：

```bash
# Agent 凭据播种（App 内用 Agent 时需要；字段对应 .agent-env.local 的三个变量）：
# echo '{"baseURL":"...","model":"...","apiKey":"..."}' > "$APP_DIR/agent-config.json"
```

- [ ] **Step 4: 全量验收**

```bash
cd Packages/JangyCore && swift test
```
Expected: 124 全绿

```bash
xcodebuild -project Jangy.xcodeproj -scheme Jangy -destination 'generic/platform=iOS Simulator' build
```
Expected: BUILD SUCCEEDED

CLI 真 key 冒烟（追问场景，验证 session 复用不回归单指令链路）：

```bash
cd Packages/JangyCore
source ../../.agent-env.local
swift run jangy-cli genassets && swift run jangy-cli sample > /tmp/draft.json
swift run jangy-cli agent "把第二段切成两半并加字幕" \
  --plan /tmp/draft.json -o /tmp/final.json --assets ./Assets \
  --base-url "$JANGY_AGENT_BASE_URL" --model "$JANGY_AGENT_MODEL"
```
Expected: exit 0，JSONL 含 start/assistant/tool_call/tool_result/snapshot/done 事件序列

- [ ] **Step 5: 模拟器手动验证（真机行为核对）**

```bash
APP_DIR=$(模拟器上本 App 的 Application Support/Jangy 目录)
swift run jangy-cli genassets --to "$APP_DIR" && swift run jangy-cli sample > "$APP_DIR/draft.json"
echo '{"baseURL":"...","model":"...","apiKey":"..."}' > "$APP_DIR/agent-config.json"
```

模拟器里核对清单：
1. Agent 按钮可用；sheet 默认档只露预览，拖拽三档悬停正确，全屏/退出全屏正常，关闭回主编辑页
2. 发指令「把第一段切成两半」→ 对话流逐条下落（assistant 文字 + 工具卡片状态回填）→ **预览实时跟随每步编辑**
3. 任务完成卡片出现 → 收起 sheet → 点「撤销」→ 整个 Agent 任务一步回退
4. 运行中发送按钮变停止按钮，点击可中断
5. 撤销/重做/导入/新建/导出在运行中禁用

- [ ] **Step 6: Commit**

```bash
git add docs/architecture-covenant.md docs/roadmap-path-a.md AGENTS.md
git commit -m "docs: Agent App 接入验收回填——公约 §6.2 白名单登记 + 组件表更名 + roadmap 进度 + 凭据播种说明"
```
