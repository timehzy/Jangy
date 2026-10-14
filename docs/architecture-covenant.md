# Jangy 架构公约（v1）

> 状态：已拍板（2026-10-13）。**本文档是本仓库架构与工程约束的唯一事实源**；AGENTS.md 只做导航指引，不复述约束。违反公约的改动不得合入。修订公约需显式决策并回填本文档（AGENTS.md 同步导航指针）。
>
> 业界依据：数据模型对齐 [OTIO](https://opentimelineio.readthedocs.io/en/v0.16.0/tutorials/architecture.html)（Pixar/ASWF 剪辑时间线标准）；引擎分层对齐 [GES](https://gstreamer.freedesktop.org/documentation/gst-editing-services/index.html)（GStreamer Editing Services）；「预览/渲染同源」对齐 GES GESPipeline 三模式（preview / render / smart render）；前端状态拆分参照 NLE 前端实践（播放头高频状态与时间线结构状态分离）。

## 0. 总纲

1. **时间线是指令集，不是媒体**。EditPlan 只存剪辑意图（素材引用 + 区间 + 参数），永不修改源素材文件。分割/移动/变速都是零成本指针操作。
2. **单向数据流**：UI 发 Intent → 操作层翻译 → `EditStore.apply` 单入口改 plan → 状态下行驱动 UI。禁止任何绕过该环路的反向写。
3. **内核封闭、特性开放**：编辑操作集（split/trim/move/insert/delete/setSpeed/setTransition…）是稳定内核，不可插拔；特性（字幕、转场、变速档位、未来贴纸/滤镜）经 reactor 注册表插拔。

## 1. 分层架构（L0–L4）

```
┌─────────────────────────────────────────────┐
│ L0  UI 表现层（Jangy/，SwiftUI）              │  只呈现、只发 Intent；零业务逻辑
├─────────────────────────────────────────────┤
│ L1  交互操作层（JangyCore/Interaction）        │  手势→原子意图组合；处理隐含语义
├─────────────────────────────────────────────┤
│ L2  领域模型层（JangyCore/Plan）               │  EditPlan + 原子操作 + 校验 + 联动
│     纯 Swift，禁 import AVFoundation/Kadr     │
├─────────────────────────────────────────────┤
│ L3  引擎适配层（JangyCore/Engine）             │  唯一允许 import Kadr/AVFoundation
├─────────────────────────────────────────────┤
│ L4  引擎（AVFoundation / Kadr，外部依赖）       │
└─────────────────────────────────────────────┘
```

**依赖方向只允许向下**：L0→L1→L2→L3→L4。禁止反向依赖、禁止跨层调用（如 L0 直接碰 L2 的校验或 L3 的引擎）。

### 各层职责与禁令

| 层 | 职责 | 禁令 |
|---|---|---|
| L0 UI | 界面呈现、手势采集、发 Intent、订阅状态 | 不得含任何剪辑规则；不得直接改 `store.plan`；不得 import Kadr/AVFoundation（PlayerController 除外——播放器壳属表现层例外，只持 player 不拼 composition） |
| L1 交互操作 | 把一次用户操作翻译为一个或多个原子编辑意图；处理操作级隐含语义（如拖动吸附、手势期间连续 intent 的节流合并） | 不得写合法性校验（那是 L2 的）；不得认识具体特性模块（字幕/转场） |
| L2 领域模型 | EditPlan 及原子操作实现；不变量校验（EditPlanValidator）；原语事件发射与 reactor 联动 | 纯 Swift，无 AVFoundation/Kadr 依赖；所有修改经 `EditStore.apply` |
| L3 引擎适配 | EditPlan→Kadr.Video 的翻译、预览/导出执行、素材导入探测 | 不得含剪辑语义决策（如「分割后继承变速」）；只做翻译与执行。`import Kadr` / `KadrCaptions` / `KadrPhotos` / `AVFoundation` 只许出现在本层，新增引擎调用一律进本层 |

### 现有代码落位

| 现有组件 | 层 | 备注 |
|---|---|---|
| `EditPlan` / `PlanClip` / `AssetItem` / `TimelineDuration` | L2 | |
| `EditStore` / `UndoStack` / `EditPlanValidator` | L2 | apply 是全库唯一写入口 |
| `AssetResolver` / `ProjectStore` / `AssetLibrary` / `PlanLoader` | L2 基础设施 | ProjectStore 多项目持久化；AssetLibrary 全局素材登记表 |
| `EngineBridge` / `PreviewBridge` / `ExportRunner` / `PhotosBridge` / `AssetImporter` / `CaptionImageRenderer` | L3 | |
| App 壳全部 SwiftUI + `AppModel` | L0/L1 | AppModel 目前是 L1 雏形，正式版拆出 Interaction 层 |
| `AgentToolSet` / `EditAgentSession` / `AgentRunContext`（`JangyAgent` target） | L1 headless 消费方 | 剪辑 Agent：工具层（原子编辑 → `EditStore.apply`，校验失败结构化回喂）+ 编排层（连续对话 session，agent loop + snapshot 视觉自检）；App 与 CLI 共用 |
| `AssetSynthesizer` / `SamplePlan`（`JangyTestSupport` target） | 测试脚手架 | 不分层：仅测试与 CLI 依赖，App 不链接，不进正式产物 |
| **待建** | L1 | Interaction 层（手势→意图翻译）当前尚不存在独立模块 |
| **待建** | L2 | 原语事件 + reactor 注册表（见 §4） |

## 2. 数据流公约

1. **唯一写入口**：一切 plan 修改经 `EditStore.apply`（沿用现有硬性约定），校验失败不压撤销栈。
2. **播放状态隔离**：播放头位置、播放/暂停态等高频状态（30/60fps）**不进 EditStore**，由 PlayerController 独立发布；时间线 UI 不订阅播放头，字幕预览叠加层等需要播放时间的组件单独订阅。理由：防止播放头每帧触发整棵 SwiftUI 树重算。
3. **Intent 是用户操作的唯一表达**：L0 不发「改 plan 第 3 段 speed」这种指令，只发语义 Intent（`userRequestedSplit(clipID, at:)`），由 L1 翻译成原子操作组合。
4. **撤销粒度 = 用户操作粒度**：一次用户操作产生的所有原子修改（含 reactor 追加的联动）进同一撤销步。

## 3. 数据建模公约

1. **片段级属性内禀化**：变速、未来的滤镜/调色/音量等「跟着片段走」的属性，一律存为 `PlanClip` 的字段，**禁止**建成按时间区间生效的独立实体。分割/移动时随节点拷贝，联动零成本。（依据：OTIO effects-on-clip、GES GESClip 子元素、剪映同款建模；2026-10-13 拍板。）
2. **素材引用走登记表**：`PlanClip.assetID` / `CaptionTrack.assetID` 必须指向 `plan.assets` 里的 `AssetItem`；禁止在 plan JSON 里写文件名直引（v2 起 `MediaRef` 已删除）。新增素材须先登记再引用，登记 + 追加片段放同一次 `EditStore.apply`（单撤销步）。
3. **时间口径统一**：渲染时长只认 `EditPlan.renderedDuration`——dissolve 与相邻片段全额重叠（扣 duration），fade 不重叠（各占相邻片段内 duration/2，总长不变）；与 Kadr CompositionBuilder `overlap(during:)` 一致，实测锚点 9.5s ≠ `Video.duration` 求和值 10.5s。UI 展示、e2e 断言都锚它；禁止「修正」成求和值，禁止另写求和。
4. **无源区间素材**：图片等静态素材的 clip 无 source range，只有 duration；模型层显式建模（如 `PlanClip.source` 枚举：`.video(range)` / `.still(duration)`），不用魔法值（如 range 置零）表达。
5. **schema 版本守卫**：plan/draft JSON 带 `version`，过新拒绝加载，不静默丢字段。
6. **工程读写必经 `ProjectStore`**：`Projects/<uuid>/project.json`（plan 格式不变）+ `meta.json`，原子写入 + 完整性校验；禁止在 App 层手写 project.json；素材完整性问题经 `verify` 报告显式上报，不静默丢弃。素材实体归全局 `AssetLibrary`（`library.json` 登记表 + `Assets/`），项目只持有引用子集。
7. **命名避让**：模型层用 `PlanClip` / `PlanTransition`——Kadr 有同名 `Clip` 协议与 `Transition` 枚举，同模块会歧义。新增模型类型命名前先查 Kadr 符号表。

## 4. 跨实体联动：原语事件 + reactor 注册表

### 背景

「变速段被分割后两段都带变速」这类需求**不是联动**——属性内禀化（§3.1）后由数据模型天然解决。真正需要联动机制的是**跨实体**场景，已知清单：

- 分割点横跨字幕 → 字幕裂为两条
- 分割/删除落在转场区域 → 转场取消或收缩
- 变速改变 outputDuration → 全局时长、后续字幕对位
- 删除中间段 → 后续段 ripple 前移（若启用 ripple 模式）

### 机制（2026-10-13 拍板）

1. `EditStore.apply` 执行原子操作后，产生一组**原语事件**（事实陈述，如 `clipSplit(id, at:)` / `clipRemoved(id)` / `clipSpeedChanged(id, rate)`）。
2. 特性模块（字幕、转场等）向注册表登记自己的 **reactor**，声明关心的原语事件类型。
3. apply 在同一事务内同步调用匹配的 reactor，reactor 返回对 plan 的追加修改，**并入同一撤销步**。
4. **reactor 三禁令**：
   - reactor 之间互不可见（字幕 reactor 不知道转场 reactor 存在）；
   - reactor 不得再发射原语事件（只允许扇出一层，杜绝级联）；
   - reactor 不得做异步操作（联动必须同步、确定性）。
5. 需要二级联动时，由 L1 显式发起新事务（新撤销步），不在 reactor 内偷跑。
6. **可插拔性验收**：卸载某特性模块 = 注销其 reactor 注册项，内核操作集与其他特性行为不变。新增特性不得改动内核操作与其他 reactor 的代码。
7. **反对方案备忘**：不用事件总线（因果链不可见、时序无保证、撤销边界模糊）；不用 L1 编排器显式认识各特性（新增特性要改协调层，可插拔性弱）。

## 5. 特殊素材公约（2026-10-13 拍板）

### 5.1 图片素材

- 模型层按 §3.4 建「无源区间素材」；引擎层合固定时长帧序列（写帧能力可移植自 `JangyTestSupport.AssetSynthesizer`）。
- 图片 clip 支持的操作集与视频一致（分割/变速语义：变速 = 改 duration）。

### 5.2 全景视频（360°）

v1 范围：**导入 + 剪辑 + 导出保元数据**；球形交互预览进 backlog。

- **预览**：等距柱状 2D 直显（解码即普通帧序列，变速/转场/字幕直接可用，零引擎改动）。
- **导出保元数据**：优先 AVFoundation APMP 链路（iOS 26 SDK 起可读球面 V1/V2 并转写 APMP，FCP 已采用）；兜底为导出后注入球面元数据（spatial-media 方案）。两条路径都需在 e2e 测试中断言产物元数据存活。
- **分辨率基线**：全景源按 4K–5.7K 验证 preset renderSize 与导出性能；超出 preset 能力的素材在导入期显式提示，不静默降质。
- **backlog**：Metal 球面交互预览（绕开 AVPlayerLayer 自建渲染管线，工作量单列）；代理素材（proxy）生成以保拖动流畅。

## 6. 所见即所得公约

1. **同源规则**：预览与导出共用同一 composition 构建入口（现 `EngineBridge.makeComposition`）。禁止预览单独拼一套渲染逻辑。任何无法在预览中实时呈现的效果，不入 v1。
2. **零 loading 白名单**：允许出现 loading 的操作仅有——素材导入（探测/转码）、导出、剪辑 Agent 任务。**一切编辑操作禁止 loading**。剪辑 Agent 任务的呈现方式：不以 spinner 呈现，以流式对话流呈现（assistant 文字/工具卡片实时下落）；任务期间编辑控件锁定（sheet 遮挡 + disabled）；预览随每步编辑实时重建。
3. **增量重建**：编辑后预览更新优先就地修改 composition（AVMutableComposition 区间增删 + videoComposition 热更新），不做全量重建。注意已知坑：`AVPlayerItem.videoComposition` setter 是 copy 语义，改完要 mutableCopy 赋回。**player 生命周期规则**：换 player 前必须同步 `pause()` 旧实例 + 取消轮询 Task（旧 player 回收依赖 dealloc 时机不受控，不主动停会出现「界面无播放器却有声音」的孤儿播放）；轮询 Task 必须弱捕获 player；rebuild 的 await 期间可能又来一次 rebuild，安装 player 前必须再查 `Task.isCancelled`；重建保留播放状态（旧 player 暂停/播完则新的不自动出声）。
4. **降级登记制**：预览允许近似的项目必须登记在下表，新降级项不进表不准合入。

| 降级项 | 预览行为 | 导出行为 | 原因 |
|---|---|---|---|
| 字幕 | SwiftUI Text 叠加层按播放时间近似 | 烧录（AVVideoCompositionCoreAnimationTool） | Kadr overlay 仅导出时生效 |
| 转场直通规避 | renderSize +0.5pt 微扰（仅模拟器） | 无微扰 | iOS 26 模拟器像素格式直通怪癖 |
| 拖动期间帧率 | trim/拖动手势期间允许降帧率 | 不受影响 | 交互流畅优先 |

5. **高频操作合并**：拖动类手势（trim 手柄、滑块）产生的连续 Intent 在 L1 节流/合并，手势结束才落一个撤销步。

## 7. 测试与验收公约

1. L2（领域模型 + 联动）纯 Swift 可测，**单元测试全覆盖**；reactor 联动必须有「分割变速段」「分割横跨字幕」等场景用例。
2. L3 引擎行为以 e2e 导出产物断言为准（沿用现有 TestArtifacts 抽帧核对）。
3. **CLI 输出契约**：stdout 只走结构化 JSON/JSONL；日志、错误、人工可读信息一律 stderr。exit code：0 成功 / 1 JSON 解码失败 / 2 语义校验失败 / 3 引擎错误 / 4 LLM 接入错误（`agent` 子命令：key 缺失、网络/API 报错、轮次耗尽）。自动化链路依赖此契约，改动须保持。Agent 链路是 L1 意图的 headless 消费方，与 UI 共用操作集。
4. 公约合规检查纳入 code review 清单：依赖方向、import 收敛、写入口唯一、loading 白名单、降级登记表。

## 8. 修订流程

- 公约修订 = 一次显式决策（issue/讨论 → 拍板 → 回填本文档）。
- 其他文档（AGENTS.md、README、roadmap）只放指向本文档的导航指针，**不复述本文档的任何约束条款**。
- 与公约冲突的临时实现必须带 `// 公约豁免：` 注释 + backlog 条目 + 移除条件，否则视为违规。
