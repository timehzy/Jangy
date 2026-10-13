# 剪辑 Agent App 接入设计（v1）

> 状态：已拍板（2026-10-13）。上游约束见 [架构公约](../../architecture-covenant.md)；本文只记本次接入的设计决策，不复述公约条款。
> 前置：headless 链路已收口（提交 7c74cb9），见 [roadmap](../../roadmap-path-a.md)「v1 任务进度」。

## 拍板决策（2026-10-13）

1. **撤销粒度 = 整任务一步**：一条用户指令产生的全部编辑进同一撤销步（公约 §2.4「撤销粒度 = 用户操作粒度」的自然延伸）。EditStore 加事务分组机制承载。
2. **loading 态 = 登记新豁免 + 流式呈现**：Agent 任务等待 LLM 期间不以 spinner 呈现，以流式对话流呈现；编辑控件锁定；预览随每步编辑实时重建。公约 §6.2 白名单随实现同 PR 回填。
3. **对话模式 = 连续对话（session 复用）**：同一 session 内用户可追问，模型记得对话历史；`EditAgentRunner` 重构为 `EditAgentSession`。
4. **UI 形态 = 半屏 sheet + 自定义头部**（2026-10-13 细化拍板）：
   - **头部**：左上角关闭按钮（点击收起回主编辑页）；中间拖拽 bar；右上角全屏按钮。拖拽 bar 可在三档悬停：**露出操作条 / 露出时间线 / 只露出预览**（默认档 = 只露出预览）。右上角全屏按钮点击进入全屏态；全屏态下右上角变退出全屏按钮（点击回半屏态），左上角仍是关闭按钮（点击直接回主编辑页）。
   - **对话页**：标准 IM 形态（参考 iMessage）——底部输入框；agent 消息气泡居左、用户消息气泡居右；新消息从底部进入并自动滚动到底。输入框右侧是发送按钮，**等待/输出期间变为停止按钮**。
   - 背景可交互（sheet 未遮住的区域，如预览，仍可操作）。
   - 实现要点：部署下限 iOS 17 没有按内容高度自定义 detent 的 API（`PresentationDetent.custom` 是 iOS 18+），三档用 `.fraction` 近似（数值在模拟器上调校，目标语义是「露出操作条 / 露出时间线 / 只露预览」）；全屏态 = 程序化切到 `.large`，退出全屏切回半屏档；头部按钮行自建于 sheet 内容顶部。
5. **会话生命周期 = 内存态、不持久化**：App 重启即清空（plan 本身有 draft autosave，不受影响）；不提供「新会话」按钮（YAGNI，后续需要再加）。
6. **凭据 = 本地文件注入**（本期）：`Application Support/Jangy/agent-config.json` 手放播种；产品化方案（自备 key / 网关代理 / App Attest）发布前再议。

## 组件拆分与分层

| 组件 | 位置 | 职责 |
|---|---|---|
| `EditStore` 分组事务 | JangyCore（L2） | `beginGrouping()`/`endGrouping()`：组内 apply 照常校验 + 改 plan，但不压撤销栈；`endGrouping` 时 plan 相对组开始有变化则压一步。组内 undo/redo 忽略（防御）。不嵌套 |
| `AgentRunContext` 改造 | JangyAgent | `EditStore` 改为注入（CLI 传临时 store，行为不变）；新增执行器闭包 `executor`（CLI 直通 / App 回跳 MainActor——读和写都经它，规避 `@Observable` 跨 actor 访问）；新增 `didApply` 回调（App 接 `player.rebuild()` + autosave）；`locked` 拆为 `read`/`apply` 两个 async 入口，编辑工具统一走 `apply` |
| `EditAgentSession`（替代 `EditAgentRunner`） | JangyAgent | session 长活：持有 `LanguageModelSession`；`send(instruction:)` 每条用户指令跑一轮 agent loop（现 runner 的 loop 原样搬入：续轮/终止判定/轮次上限/快照回喂/事件发射）；工具步数计数每条指令开始时重置；记录上次 send 结束时的 plan，新指令发出前比对，plan 被外部改过则 prompt 前缀注入「时间线已被手动修改，先用 get_plan 确认」 |
| `AgentController` | App 壳（L1） | `@MainActor @Observable`：lazy 建 session；对话模型 `[AgentChatItem]`；`send`/`stop`；onEvent 归一 MainActor；分组边界管理（send 前 `beginGrouping`，结束/异常/取消 `endGrouping`）；`didApply` 接线 rebuild + autosave |
| `AgentChatView` | App 壳（L0） | 对话流按 IM 形态（agent 气泡居左 / user 气泡居右 / 新消息底部进入，参考 iMessage）：user/assistant 文字气泡、工具卡片（名称 + 参数摘要 + 成败态）、snapshot 图片、done/error 卡片；底部输入框 + 发送按钮（运行中变停止按钮）；自定义头部（左关闭 / 中拖拽 bar / 右全屏切换）；sheet 呈现，三档 detent（露出操作条 / 露出时间线 / 只露出预览，默认只露预览）+ 全屏态，背景可交互 |
| `AgentCredentials` | App 壳 | 读 `agent-config.json`（baseURL/model/apiKey）；缺失 → 入口禁用 + 提示 |

`EditAgentRunner` 删除，CLI 改用 `EditAgentSession`（建一个、`send` 一次，行为与 stdout JSONL/exit code 契约不变）。公约 §1 组件表同步更名回填。

## 数据流

```
用户输入指令 → AgentChatView → AgentController.send
  → store.beginGrouping()
  → EditAgentSession.send（[外部修改提示?] + 指令 → LLM loop）
      → 工具经 context.apply → executor(MainActor) → EditStore.apply
          → 成功: didApply → player.rebuild() + 防抖 autosave   （预览实时跟随）
          → 失败: 错误信封回喂模型自纠（现状不变）
      → onEvent → MainActor → 对话流追加卡片
  → 结束/异常/停止 → store.endGrouping()（整任务一步撤销）
```

会话期间 sheet 遮住编辑区，天然互斥；sheet 收起后用户可手动编辑，下条指令靠 plan 比对兜底提示。

## 事件与错误处理

- `AgentEvent` 新增 `.snapshot(turn:at:path:)`：只带路径不带 PNG 数据（事件保持轻量 Encodable）；App 从路径读图渲染，CLI 原样打印。JSONL 纯增量，契约不破坏。
- LLM 错误 / 轮次耗尽 / 空响应 / 用户停止：一律 error 或中断卡片 + `endGrouping` 收尾，已生效编辑保留为一步可撤销。
- 轮次上限 `maxTurns` 按每条指令计；工具步数上限每条指令重置（语义与现状一致：防单次失控的兜底）。

## 包接线

- `Package.swift` 加 `.library(name: "JangyAgent", targets: ["JangyAgent"])` product；Xcode App target 链接 `JangyAgent`。

## 公约修订（随实现同 PR 回填）

- §6.2 白名单加一行：**剪辑 Agent 任务**——等待 LLM 期间不以 spinner 呈现，以流式对话流呈现；编辑控件锁定（sheet 遮挡）；预览随每步编辑实时重建。
- §1 现有组件表：`EditAgentRunner` → `EditAgentSession`（连续对话 session 复用形态）。

## 测试与验收

- 新增单测：
  - 分组事务：组内多 apply 一步撤销 / 组内校验失败不压栈 / 空组不压步 / 组内 undo 忽略
  - `AgentRunContext`：注入形态 + executor 回跳
  - `EditAgentSession`：跨 `send` transcript 保留 + 工具计数重置 + 外部修改提示注入（`LanguageModel` 协议开放可 stub——headless 阶段已验证；stub 不起来的部分降级为 CLI live 冒烟核对）
- 既有 111 测试全绿；CLI 五子命令冒烟无回归 + `agent` 真 key 冒烟（追问场景：同 session 连发两条指令）。
- App 模拟器构建通过；模拟器手动验证：sheet 里发指令 → 预览实时跟随 → 撤销一步整体回退。

## 明确不做（本期）

- 凭据产品化（自备 key / 网关 / App Attest）：发布前再议。
- 会话持久化、「新会话」按钮：YAGNI。
- Kimi/Claude 之外的模型表现评估：沿用 roadmap 遗留项。
