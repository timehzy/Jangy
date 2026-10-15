# 交接：时间线多轨 · 阶段①（模型 + 引擎）

日期：2026-10-15
分支：`timeline-tracks-model-engine`（Jangy）／`fix/multitrack-layer-order-and-frame-hold`（kadr fork）

**一句话**：模型+引擎已全部打通并通过逐任务审查；**只剩三件收尾事**（Kadr fork 推上去打 tag、Jangy bump 版本约束并提交两处暂存改动、补 Task 12/13/14）。

---

## 一、立即要做的收口序列（**用户已授权，按此执行**）

### 1. Kadr fork：推分支 → 合 main → 打 tag

```bash
cd /Users/insta360/Workspace/sidework/kadr
# 当前在 fix/multitrack-layer-order-and-frame-hold @ eb6758e，main @ 5ebaf69（未动）
git push origin fix/multitrack-layer-order-and-frame-hold
git checkout main && git merge --ff-only fix/multitrack-layer-order-and-frame-hold
git push origin main
git tag v1.2.2 && git push origin v1.2.2
```

改动只有一个文件：`Sources/Kadr/Engine/CompositionBuilder.swift`（+37/−7）。**验证数据**：Kadr 自身测试 663 → 663 无回归。

### 2. 向上游提 issue（公约里对上一个 P0 bug 的同款做法）

仓库：`SteliyanH/kadr`（fork 克隆里已配好 `upstream` remote）。

**Issue 要点**（已实测，证据充分）：

> **多轨层序与文档/注释相反：`layerInstructions` 按 `videoTracks` 顺序构造，导致隐式主链恒在最上层、并行 `Track` 永远不可见**
>
> - AVFoundation 文档明确 `AVMutableVideoCompositionInstruction.layerInstructions` **数组第 0 个是最上层**（*"the track with the trackID of the first instruction in the array will be layered on top"*）。
> - 而 `CompositionBuilder.buildMultiTrack` 把隐式主链**无条件**放进 `videoTracks[0]`，再按该顺序构造 `layerInstructions` → 主轨恒在最上，`Track { }`（画中画/叠加）永远被盖住。
> - 源码两处注释（`CompositionBuilder.swift` 约 `:97` 与 `:293-295`）写的是「earlier = background, later = on top」，**与实现和 AVFoundation 语义都相反**——注释与意图一致，实现反了。
> - **复现**：两条全幅重叠的视频轨，一条在主链、一条在 `Track {}` → 导出抽帧只见主链颜色。裸 AVFoundation 探针（绕过 Kadr，只改 `layerInstructions` 顺序）可复现翻转。
> - **附带 bug**：任何**早于合成末端结束**的轨道，其**末帧会被 AVFoundation 保持**并盖住后续帧（默认路径与自定义 compositor 路径都有）。表现为叠加轨结束后画面被冻结的末帧覆盖。
> - 我们的修法（fork 分支 `fix/multitrack-layer-order-and-frame-hold`）：① `layerInstructions` 构造反转；② 每条轨在内容结束点补 `setOpacity(0, at: contentEnd)`（仅当内容结束早于合成末端）。

### 3. Jangy：bump 版本约束 + 提交两处暂存改动

工作区现有两处**未提交**改动（实现者刻意留着，避免红灯提交）：

- `Packages/JangyCore/Tests/JangyCoreTests/MultiTrackExportEndToEndTests.swift` —— `testOverlayTrackRendersOverMainTrack` 已从 `XCTSkip` 恢复为真测试（两个断言：叠加时段见绿、叠加结束后回红）
- `docs/superpowers/specs/2026-10-15-timeline-tracks-design.md` —— z 序条目回填为「已修复」

```bash
cd /Users/insta360/Workspace/sidework/Jangy
# 1) Package.swift 里 kadr 依赖：from: "1.2.0" → from: "1.2.2"
# 2) 刷新解析并全量验证
cd Packages/JangyCore && swift package update kadr && swift test   # 期望 268 executed / 0 failures / 0 skipped
# 3) 一起提交
cd /Users/insta360/Workspace/sidework/Jangy
git add Packages/JangyCore/Package.swift Packages/JangyCore/Package.resolved \
        Packages/JangyCore/Tests/JangyCoreTests/MultiTrackExportEndToEndTests.swift \
        docs/superpowers/specs/2026-10-15-timeline-tracks-design.md
git commit -m "Core: 接入 kadr v1.2.2（多轨层序 + 末帧保持修复），解除叠加轨 e2e 挂起"
```

> **关键**：这两处改动**必须**和版本 bump 同一次提交。单独提交它们会让本地全量测试变红（远端 kadr 还是未修的，那条 e2e 会失败于第一个断言）。

---

## 二、计划执行状态（14 个任务）

计划：[2026-10-15-timeline-tracks-model-engine.md](2026-10-15-timeline-tracks-model-engine.md)
Spec：[../specs/2026-10-15-timeline-tracks-design.md](../specs/2026-10-15-timeline-tracks-design.md)

| Task | 状态 | 说明 |
|---|---|---|
| 1 · 核心轨道类型 + payload + 注册表 | ✅ | 逐任务审查通过 |
| 2 · Video 特性片 | ✅ | 审查补了 6 条边界用例 |
| 3 · Caption 特性片 | ✅ | 审查补了 5 条边界用例 + settings 类型校验 |
| 4 · SRT 解析器 | ✅ | 审查修了定位坐标行丢 cue + 坏块计数 + BOM |
| 5 · v3 → v4 迁移 | ✅ | 审查修了编码回落 + notices 通道 |
| 6+7+8 · EditPlan v4 大切换 | ✅ | 一个不可分割的工作单元；两轮审查各修 2 条缺陷 |
| 9 · TrackOperations 测试 | ✅ | 审查用变异测试抓出一条真空测试 |
| 10 · 引擎多轨 e2e | ✅ | gap 黑场已锚定；**叠加轨层序挖出 Kadr 阻塞项 → 已修（见上）** |
| 11 · 字幕逐句化接线 | ✅ | |
| **12 · Agent 工具改造** | ❌ **未做** | 见下 |
| **13 · 可插拔性验收测试** | ❌ **未做** | 见下 |
| **14 · 公约修订与文档同步** | ❌ **未做** | 见下 |

### Task 12 · Agent 工具改造（未做）

Task 6 阶段 B 只做了「编译通过 + 行为等价」的最小适配。**真正的签名改造还没做**，计划 Task 12 节有完整清单：

- `clipID` 参数统一改 `elementID`；`Payload` 字段名同步（`elementID` / `firstElementID` / `secondElementID`）
- `move_clip` → `move_element(elementID, toTrackID?, beforeElementID?, at?)`（**废除下标寻址**）
- 新增轨工具：`add_track` / `remove_track` / `move_track` / `set_track_flags`
- `set_captions` → `set_caption_track`（导入 SRT 并展开）；新增 `set_caption_text`
- `get_plan` 增加扁平元素视图
- `AgentPromptBuilder` 的领域规则段整体改写（计划里有成稿）
- **工具里一律不要自己调 `TrackOperations.maintainInvariants` / `normalizePayloads`**——它们在 `EditStore.apply` 里已单点跑过

### Task 13 · 可插拔性验收（未做）

计划 Task 13 节有完整代码：用 `TrackFeatureRegistry.testOnlyFeatures` 注入一个第四类轨（贴纸轨空壳），断言核心零条件分支改动。`testOnlyFeatures` 是 `internal`（测试经 `@testable import` 访问）。

### Task 14 · 公约修订与文档同步（未做）

计划 Task 14 节有清单，**注意补充一条本次新定的**：

- 归一化在写入口**无条件**跑 → **任何结构变化后悬空的转场一律被清掉**，包括「用户显式把挂转场的片段移到最后」（v3 是校验失败、v4 是清转场后成功）。**这是有意的取舍**（转场不跟在内容元素后面就是悬空引用，同外键语义），不是 bug。

还要同步：`AGENTS.md` 的测试数、`README.md`、`docs/roadmap-path-a.md`（加「阶段① 已完成」条目 + 「阶段② 时间线 UI」待办）。

---

## 三、新会话必须知道的上下文

### 环境

- **Kadr fork 的独立克隆**：`/Users/insta360/Workspace/sidework/kadr`（`origin` = `timehzy/kadr`，`upstream` = `SteliyanH/kadr`）
- **`.build/checkouts/kadr` 是 SwiftPM 管的，不要直接改**。要在本地把 fork 改动接进 Jangy 用：
  ```bash
  cd Packages/JangyCore && swift package edit kadr --path /Users/insta360/Workspace/sidework/kadr
  # 用完 swift package unedit kadr（它会把 Package.resolved 的 originHash 改掉，记得 git checkout 还原）
  ```
- 跑测试：`cd Packages/JangyCore && swift test`；App 构建：`xcodebuild -project Jangy.xcodeproj -scheme Jangy -destination 'generic/platform=iOS Simulator' build -skipMacroValidation`

### 验证基线

- **接本地已修的 fork 时**：`268 executed / 0 failures / 0 skipped`
- **接远端未修的 kadr 1.2.1 时**：`267 passed + 1 failed`（就是那条叠加轨 e2e）——这正是必须 bump 版本的原因

### 设计决定（**不要"顺手修"**）

1. **删除语义 = lift 而非 ripple**：删主轨元素 = 原地留等长 gap（时长保留），其他轨不动。跟桌面 NLE 走、不跟剪映走。
2. **两条不变式由 `EditStore.apply` 单点维持**：`normalizePayloads` → `maintainInvariants` → `validate`。**顺序不能反**（normalize 清悬空转场会减少重叠→增加 renderedDuration）。
3. **成片时长 = `EditPlan.renderedDuration`（主轨链长）**，**不等于** `PlanTrack.span`（后者不含转场重叠）。校验器与不变式一律用前者。
4. **`TrackPayload` 的 `type` 判别字段由 box 注入**，payload 自己不写。
5. **`Kadr.Track { }` 内部元素的 `.at(time:)` 被忽略是设计**（Track 内是 track-relative 隐式链）。叠加轨元素定位要**每个元素一个 `Track(at:)`**——**这条还没落到 `VideoEngine` 里，是 Task 10 之外的一个遗留**（见下）。
6. **归一化会清掉悬空转场**（含用户显式 move）——见 Task 14。

### ⚠️ 一个已知的遗留（本次没做）

`VideoEngine.makeParallelTrack` 现在用 `Kadr.Track(name:)` + 元素级 `.at(time:)`，而**元素级 `.at` 是被忽略的**（上面第 5 条）。所以**叠加轨元素目前都会落在轨道起点**，绝对定位不生效。

本次的 e2e（`testOverlayTrackRendersOverMainTrack`）只用了**一个**叠加元素且 `at: 0.5`，它碰巧没能暴露这个问题——**这条测试的通过并不代表叠加轨定位正确**。

修法：`makeParallelTrack` 改成**每个元素产出一个 `Track(at: element.at)`**。**建议在 Task 12 之前或之后尽快补一个多元素叠加轨的 e2e 来钉住它。**

### 审查过程中反复出现的模式（对后续任务有用）

- **「同一套规则两份、新的那份零覆盖」**：Task 6 会删旧实现，删之前必须先把新实现的边界用例钉住——Task 2/3 都因此补了测试
- **「真空测试」**：Task 9 审查者用**变异测试**（把被测函数改成 no-op）验证测试是否真的有区分度，抓出一条 fixture 造得让断言恒真的测试。**后续写测试建议沿用这个自查手法**
- **「实现先于测试」**：Task 9/10/11 的源码都在 Task 6 前向落地了，所以那三个任务只剩补测试。写测试时**不要改源码迁就测试**，有冲突先报
