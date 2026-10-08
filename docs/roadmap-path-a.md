# 立项路线图（路径 A 落地计划）

> 2026-10-08 POC 结论落定后整理。选型依据见[调研报告](iOS开源视频剪辑框架选型调研报告.md)第 7 节路径 A；POC 验证记录见[poc-verification-checklist.md](poc-verification-checklist.md)。

## 已定论的结论

- **正式立项走路径 A：Kadr 全家桶直达**（2026-10-08）。POC 五个关键字（多段拼接 / 转场 / 变速 / 字幕 / headless 导出）+ EditPlan JSON → DSL 端到端 + 4K HDR CLI 侧全部 ☑。
- Kadr 依赖已切内部镜像 fork（`timehzy/kadr`、`timehzy/kadr-captions`），版本约束不变。fork 不会自动跟随上游：第一次需要上游修复时给两个 fork 配 `upstream` remote，手动同步、跑完 48 测试再合入。

## 落地顺序（按优先级）

| # | 事项 | 状态 | 说明 |
|---|---|---|---|
| 1 | Kadr fork 内部镜像 + 锁版本 | ✅ 2026-10-08 | 风险登记册「单作者依赖」的核心缓解，成本极低，第一天就做 |
| 2 | 素材导入 | 🔜 下一个任务 | kadr-photos 或 YPImagePicker；App 从「只能用合成素材」到能选相册真实视频的第一道门槛 |
| 3 | 草稿持久化 | 待做 | kadr-persistence（内容寻址 + 完整性守卫），同时是 Agent 指令序列化格式，一鱼两吃 |
| 4 | POC 取舍清理入 backlog | 待做 | 见下节 |
| 5 | 音频（kadr-audio）/ 拍摄（NextLevel）/ MCP 化 | 后置 | 差异化功能，遵循「UI 用 kadr-ui 原型，差异化后置」原则，素材导入 + 持久化跑通后再排 |

## POC 遗留跟进项（backlog，不阻塞立项）

- [ ] App 真机 4K HDR 预览流畅度/发热（清单验证点③最后一格，主观记录即可）
- [ ] iOS 17 底线覆盖率调研（人工项：App Store Connect 或第三方统计）
- [ ] **HDR 直通产品决策**：产物保留 BT.2020 + HLG 元数据是特性（HDR 全链路）还是问题（分享到不支持 HDR 的平台发灰）——影响导出管线设计，需在素材导入落地前定调
- [ ] 向 Kadr 上游提两个 issue（草稿已写在[清单](poc-verification-checklist.md)第 69 行起）：
  - Issue 1（Critical）：无音频素材导出静默 passthrough
  - Issue 2（macOS 平台）：TextOverlay 的 CATextLayer 在 headless 导出不渲染

## POC 已知取舍（正式版要处理）

- 首次启动同步合成测试素材阻塞主线程数秒——正式版移出启动关键路径
- 字幕预览以 SwiftUI Text 叠加层近似（Kadr overlay 仅导出时烧录）——「所见即所导」对字幕降级为「预览近似」，正式版需决策是否接受
- 转场重叠语义：渲染时长 ≠ `Video.duration` 求和值（实测 9.5s vs 10.5s）——e2e 断言基于实测值，UI 时长显示同样要用实测口径

## 下一步任务的入口

任务 #2「素材导入」开新会话进行。进会话后先读 [AGENTS.md](../AGENTS.md)，关键约束：编辑必经 `EditStore.apply`、Kadr 依赖收敛在引擎适配层、CLI stdout 只走结构化 JSON。
