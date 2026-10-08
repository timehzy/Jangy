# Kadr POC 工程骨架设计文档

- 日期：2026-10-08
- 状态：已确认（头脑风暴四节设计均获批准）
- 依据：`docs/iOS开源视频剪辑框架选型调研报告.md` 第 10 节「下一步建议」

## 1. 目标与范围

按调研报告第 10 节建议，用 Kadr 跑一个最小 POC，覆盖五个关键字：**多段拼接 + 转场 + 变速 + 字幕 + headless 导出**，并搭建包含**快照撤销栈**和**三层 App 结构**的工程骨架。

POC 需要闭环报告提出的三个验证点：

1. LLM 生成 EditPlan JSON → DSL 的端到端稳定性
2. iOS 17 底线对目标用户群的覆盖率（人工调研项，代码无法验证）
3. 4K HDR 素材的预览与导出表现（真机手动验证项）

### 已确认的关键决策

| 决策点 | 结论 |
|---|---|
| 验证形态 | iOS App + 共享核心层 + macOS CLI 工具 |
| 三层结构 | 表现层（SwiftUI）/ 编辑状态层（EditStore + 快照撤销栈）/ 引擎适配层（EngineBridge） |
| 演示闭环 | 内置工程（bundle 素材 + SRT）+ 固定五类操作：裁剪、拼接/删除、加转场、变速（0.5x/2x）、字幕开关 |
| 工程组织 | SwiftPM 包为核心 + 薄 Xcode App 壳 |
| 核心模型命名 | EditPlan（沿用报告术语，Agent 契约语境） |

### 非目标（YAGNI）

- 相册导入 / kadr-photos 桥接（素材全部内置）
- 曲线变速（`.curved`），POC 只做 `.flat(rate)`
- 增量快照、命令合并等撤销栈优化
- UI 自动化测试（App 侧用真机手动验证清单）
- Tuist / XcodeGen 工程生成
- fork Kadr 内部镜像（立项时动作，POC 用 SPM 远程依赖锁定 `from: "1.0.0"`）

## 2. 整体架构

```
┌─────────────────────────────────────────────────┐
│  App/ (Xcode 工程, iOS 17+, 薄壳)                │
│  ─ 表现层：SwiftUI 视图                            │
│    TimelineView / PreviewView / Toolbar(撤销重做)  │
│    只读状态、上发编辑意图，不 import Kadr           │
└──────────────┬──────────────────────────────────┘
               │ 依赖（本地 SwiftPM）
┌──────────────▼──────────────────────────────────┐
│  KadrPOC/Sources/POCCore (纯 Swift 库)            │
│                                                  │
│  ┌─ 编辑状态层 ─────────────────────────────┐    │
│  │ EditPlan        不可变值类型树（唯一事实源） │    │
│  │ EditStore       @Observable，持有当前快照   │    │
│  │ UndoStack       快照栈 + 指针，undo/redo   │    │
│  │ EditPlanJSON    Codable schema（= Agent 契约）│  │
│  └──────────────────────────────────────────┘    │
│  ┌─ 引擎适配层 ─────────────────────────────┐    │
│  │ EngineBridge    EditPlan → Kadr DSL 单向映射│   │
│  │ PreviewBridge   → makePlayerItem（预览）    │    │
│  │ ExportRunner    → exporter.run()（headless）│   │
│  │                 ↑ 唯一 import Kadr 的地方    │   │
│  └──────────────────────────────────────────┘    │
└──────────────▲──────────────────────────────────┘
               │ 依赖（同一 POCCore）
┌──────────────┴──────────────────────────────────┐
│  KadrPOC/Sources/kadrpoc-cli (macOS executable)  │
│  swift run kadrpoc-cli plan.json -o out.mp4     │
│  无 UI，走同一 EngineBridge → ExportRunner        │
└─────────────────────────────────────────────────┘
```

### 目录结构

```
Jangy/
├── KadrPOC/                  ← SwiftPM 包，POC 的核心资产
│   ├── Package.swift         ← Kadr 依赖锁定 from: "1.0.0"
│   ├── Sources/
│   │   ├── POCCore/          ← EditPlan / UndoStack / EditStore / EngineBridge（纯 Swift，零 UI）
│   │   └── kadrpoc-cli/      ← macOS executable：EditPlan JSON → headless 导出
│   └── Tests/POCCoreTests/
├── App/                      ← Xcode 工程，仅 SwiftUI 表现层，本地引用 KadrPOC 包
└── docs/
```

### 三条硬边界规则

1. **只有引擎适配层允许 `import Kadr`**——表现层和编辑状态层对 Kadr 一无所知，未来换引擎只重写一个文件族
2. **EditPlan 是唯一事实源**——撤销栈快照、磁盘存档、CLI 的 JSON 输入、Agent 的生成目标，四者是同一个 Codable 模型
3. **依赖方向单向**：App → POCCore ← CLI，App 与 CLI 互不感知

## 3. EditPlan 数据模型与快照撤销栈

### EditPlan —— 唯一事实源（Codable + 值类型）

```swift
struct EditPlan: Codable, Equatable {
    var version: Int = 1                 // schema 版本，Agent 契约的演进锚点
    var clips: [Clip]                    // 多段拼接 = 数组顺序
    var captions: CaptionTrack?          // 字幕（SRT 文件引用 + 样式 + 开关）
    var preset: OutputPreset             // 画幅预设，POC 固定 .reelsAndShorts (9:16)
}

struct Clip: Codable, Equatable, Identifiable {
    var id: UUID
    var source: MediaRef                 // bundle 内置素材引用（文件名）
    var range: ClosedRange<TimeInterval> // 裁剪，对应 Kadr trimmed(to:) 闭区间
    var speed: SpeedPlan                 // POC 只做 .flat(rate)，0.25x–4x，保调
    var transitionAfter: Transition?     // 转场挂在片段尾部，是时间线一等元素
}
```

设计要点：**转场不是独立轨道，而是 `Clip` 的可选属性**——与 Kadr DSL 里 `Transition` 作为时间线一等元素的位置一一对应，JSON 里也更难写出非法状态（如转场悬空）。

### 快照撤销栈 —— 整树快照，不做命令模式

```swift
struct UndoStack {
    private var snapshots: [EditPlan]    // 快照数组
    private var index: Int               // 当前指针，index 之后是 redo 分支
    // push: 截断 index 之后的 redo 尾部 → 追加新快照
    // undo/redo: 纯指针移动，O(1)
    // 上限 100 个快照，超出丢最旧
}
```

整树快照的可行性依据：Swift 值类型 + Copy-on-Write，未修改的 clips 在快照间共享存储，一次「改速度」快照的实际内存开销只是一个结构体壳。POC 不做增量快照、不做命令合并。

### 数据流（一次编辑的完整旅程）

```
UI 手势 → EditStore.apply { $0.clips[1].speed = .flat(0.5) }
        → 产出新 EditPlan → UndoStack.push
        → EngineBridge 用新快照重建 Kadr DSL → makePlayerItem 刷新预览
        → 同一份快照可 JSON 编码 → 磁盘存档 / 喂给 CLI / 喂给 Agent
```

撤销 = 指针回退 → 同样走 EngineBridge 重建预览。预览与导出共用同一映射，保证「所见即所导」。

## 4. CLI 契约与错误处理

### 三个子命令（对应 Agent 工作流三环节）

```bash
swift run kadrpoc-cli sample                        # 输出内置演示工程的 EditPlan JSON
                                                    # → LLM 的 few-shot 样例 / schema 活文档
swift run kadrpoc-cli validate plan.json            # 只校验不导出，毫秒级返回
                                                    # → Agent 生成后快速自检，廉价迭代
swift run kadrpoc-cli export plan.json -o out.mp4   # 完整管线：JSON → DSL → headless 导出
                                                    # 进度事件以 JSON Lines 逐行输出 stdout
```

`export` 的进度流直接消费 Kadr `exporter.run()` 返回的 `AsyncThrowingStream`，每行一条 JSON：`{"progress": 0.42}` / `{"done": "out.mp4", "durationMs": 8312}`。**stdout 只走结构化数据，日志和错误走 stderr**。

### 错误分三层

| 层 | 典型错误 | 处理方式 |
|---|---|---|
| ① JSON 层 | 字段缺失、类型错误 | 把 `DecodingError` 翻译成具体字段路径（`clips[1].speed`） |
| ② 语义层 | 裁剪区间越界、速度超出 0.25x–4x、转场时长 > 相邻片段时长、素材不存在 | `EditPlanValidator` 在进引擎前拦截，一次报全 |
| ③ 引擎层 | Kadr 导出失败、解码器异常 | 包装为 `EngineError`，保留完整错误链，exit code 3 |

exit code 约定：`0` 成功 / `1` JSON 解码失败 / `2` 语义校验失败 / `3` 引擎错误——Agent 只凭退出码即可决定重试策略。

### App 侧错误语义

`EditStore.apply` 校验失败 = 不产出新快照 = 栈不变。快照模型天然是事务语义：不存在「改了一半的状态需要回滚」，失败只是「什么都没发生」。

## 5. 测试与验证方案

### 自动化测试（`swift test`，不经 Xcode，CI/Agent 可跑）

| 测试组 | 覆盖点 | 断言方式 |
|---|---|---|
| UndoStack 单测 | push / undo / redo / redo 分支截断 / 100 上限淘汰 | 纯逻辑，穷举边界 |
| EditPlan JSON round-trip | encode → decode 恒等；`sample` 输出与 schema 一致 | 黄金文件比对 |
| Validator 单测 | 每种非法输入都被拦截且报对字段路径 | 参数化用例 |
| EngineBridge 单测 | 固定 EditPlan → DSL 树结构正确（转场位置、速度值、字幕挂载） | 结构断言 |
| CLI 端到端黄金测试 | sample JSON → headless 导出 → AVFoundation 读回产物元数据 | 见下 |

端到端可断言项：

- **多段拼接** → 产物时长 = Σ 片段时长 − 转场重叠
- **变速** → 0.5x 片段时长翻倍
- **转场** → 产物时长正确（重叠区只计一次）
- **字幕烧录** → 无法从元数据断言；务实处理：导出后自动抽 3 帧存 PNG 人工核对，像素级对比留作后续

### 报告三个验证点的闭环

| 验证点 | POC 中的闭环 |
|---|---|
| ① EditPlan JSON → DSL 端到端稳定性 | 整套 CLI 测试 + `validate` 命令给 LLM 廉价自检 |
| ② iOS 17 底线覆盖率 | 工程 deployment target 锁 iOS 17；覆盖率数据列为**人工调研项**（查目标用户群系统分布） |
| ③ 4K HDR 预览与导出 | CLI `export` 支持任意素材路径 + App 真机手动验证清单（4K HDR 素材各跑一次预览/导出，记录耗时与发热） |

### App 侧测试

POC 骨架阶段不写 UI 测试，用**真机手动验证清单**兜底：预览流畅、五个编辑操作各撤销重做一次、App 导出产物与 CLI 同 JSON 产物一致。

## 6. 风险与缓解

| 风险 | 缓解 |
|---|---|
| Kadr 单作者项目，无生产验证 | 引擎适配层隔离（硬边界规则 1），换引擎只重写 EngineBridge 文件族；POC 不 fork，立项时再建内部镜像 |
| Kadr DSL 实际 API 与本设计假设有出入 | 实现阶段以对齐 Kadr v1.x 真实 API 为准，EditPlan schema 不变，差异吸收在 EngineBridge 内 |
| 4K HDR 性能不达标 | 验证点③的手动清单会暴露；届时再评估 preset 降级或引擎参数调整 |

## 7. 后续步骤

设计批准 → writing-plans 制定实现计划 → 搭建骨架 → 跑通五个 POC 关键字的端到端验证 → 形成 POC 结论（是否正式立项走报告路径 A）。
