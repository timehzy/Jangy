# Jangy

视频剪辑 App，iOS 原生技术实现（SwiftUI + AVFoundation）。POC 技术验证已收口（2026-10-13），当前处于 **v1 正式版开发阶段**：基于 [Kadr](https://github.com/SteliyanH/kadr) DSL 引擎，决策记录见 [路线图](docs/roadmap-path-a.md)「正式版启动」。

## 仓库结构

```
├── Jangy.xcodeproj        # iOS App 工程（iOS 17+）
├── Jangy/                 # App 壳源码（SwiftUI 表现层：预览/时间线/操作条/导出/Agent 对话）
├── Packages/
│   └── JangyCore/         # SwiftPM 包：JangyCore 库 + JangyAgent 库 + jangy-cli 可执行 + 125 个测试
│       ├── Sources/JangyCore/  # 编辑状态层（纯 Swift）+ 引擎适配层（唯一 import Kadr 的地方）
│       ├── Sources/JangyAgent/ # 剪辑 Agent：工具层（原子编辑工具）+ 编排层（连续对话 session），App 与 CLI 共用
│       ├── Sources/JangyTestSupport/  # 测试脚手架（样例工程/素材合成器），不进 App 产物
│       ├── Sources/jangy-cli/  # Agent 链路 headless 验证入口（六子命令）
│       ├── Tests/JangyCoreTests/ + JangyAgentTests/
│       └── Assets/        # 测试素材（clip1-3.mp4 + sample.srt，可由 genassets 重新生成）
└── docs/                  # 架构公约 / 选型调研 / 路线图 / 已知坑 / 设计 spec 与计划
```

## 技术栈

Swift 6.3 · Xcode 26.4 · SwiftPM · SwiftUI（iOS 17+）· [Kadr 1.2](https://github.com/SteliyanH/kadr) · [KadrCaptions 0.12](https://github.com/SteliyanH/kadr-captions) · [KadrPhotos 0.11](https://github.com/SteliyanH/kadr-photos) · [AnyLanguageModel 0.16](https://github.com/huggingface/AnyLanguageModel)（剪辑 Agent 的 LLM 接入）· swift-argument-parser

> Kadr 系与 AnyLanguageModel 依赖均走内部镜像 fork（`timehzy/*`），防上游仓库变动。

## 快速开始

### 跑测试（125 个，含导出端到端）

```bash
cd Packages/JangyCore && swift test
```

### CLI 冒烟（headless 导出链路 + 剪辑 Agent）

```bash
cd Packages/JangyCore
swift run jangy-cli genassets                 # 生成测试素材到 ./Assets
swift run jangy-cli sample                    # 输出内置演示 EditPlan JSON
swift run jangy-cli validate plan.json --assets ./Assets   # 结构 + 素材校验
swift run jangy-cli export plan.json -o out.mp4 --assets ./Assets
swift run jangy-cli snapshot plan.json --at 1.0 --assets ./Assets -o ./Frames  # 导出保真单帧

# 剪辑 Agent（凭据找维护者要，source 即用）
source ../../.agent-env.local
swift run jangy-cli agent "把第二段切成两半并加字幕" \
  --plan plan.json -o final.json --assets ./Assets \
  --base-url "$JANGY_AGENT_BASE_URL" --model "$JANGY_AGENT_MODEL"
```

CLI 约定：stdout 只走结构化 JSON/JSONL，日志与错误走 stderr；exit code 0 成功 / 1 JSON 解码失败 / 2 语义校验失败 / 3 引擎错误 / 4 LLM 接入错误。

### iOS App

用 Xcode 打开根目录 `Jangy.xcodeproj`，选择真机或模拟器运行。App 首启是空时间线，要样例内容需往沙盒播种（命令见 [AGENTS.md](AGENTS.md)「常用命令」，Agent 凭据播种同处）。功能：预览播放（字幕叠加层）、撤销/重做、字幕开关、**从相册导入视频素材**（PHPicker 多选，iCloud 自动下载，passthrough 优先保 HDR/高帧率）、导出到系统相册、**剪辑 Agent**（自然语言指令对话式剪辑：半屏 sheet 对话流，编辑实时落到预览，整任务一步撤销，可追问）。

## 当前状态

- [x] Kadr POC 工程骨架（14 任务 + 评审修复，48 测试全绿）：编辑状态层、快照撤销栈、引擎适配层、CLI 四子命令、App 壳
- [x] 导出写入系统相册（临时文件渲染 → PHPhotoLibrary 注册）
- [x] 真机手动验证通过（2026-10-08，清单见 [docs/archive/poc-verification-checklist.md](docs/archive/poc-verification-checklist.md)）
- [x] 4K HDR CLI 侧验证通过（2026-10-08：导出/转场/色调全通过；HDR 直通与 HDR→SDR 双路均验证，见清单）
- [x] **POC 结论落定：正式立项走路径 A（Kadr 全家桶直达）**（2026-10-08，见 [验证清单](docs/archive/poc-verification-checklist.md)）
- [x] 素材导入 v1（2026-10-09）：EditPlan v2 素材登记表（`assets` 表 + `assetID` 引用，替代文件名直引）；App 相册导入（kadr-photos resolver → 素材库落盘 → 时间线追加）
- [x] v1 架构公约落定（2026-10-13，[docs/architecture-covenant.md](docs/architecture-covenant.md)）：L0–L4 分层、单向数据流、所见即所得硬规则
- [x] 剪辑 Agent headless 链路（2026-10-13）：11 个原子编辑工具 + agent loop 编排 + CLI `agent` 子命令，真 key 冒烟通过
- [x] 剪辑 Agent App 接入（2026-10-13/14，[spec](docs/superpowers/specs/2026-10-13-agent-app-integration-design.md)）：EditStore 合一（共享 store + 整任务一步撤销）、连续对话 session、半屏 sheet IM 对话 UI、运行中编辑锁定；真机验证通过
- [ ] iOS 17 覆盖率调研（人工调研项，见清单）

已知取舍：

- 字幕预览以 SwiftUI Text 叠加层近似（Kadr overlay 不进入 `makePlayerItem()` 预览，仅导出时烧录）
- 转场重叠语义：dissolve 与相邻片段重叠，渲染时长 ≠ Kadr `Video.duration` 求和值（实测 9.5s vs 10.5s）

## 文档

- [架构公约（v1，架构约束唯一事实源）](docs/architecture-covenant.md)
- [立项路线图（路径 A 落地计划 + v1 任务进度）](docs/roadmap-path-a.md)
- [已知坑（运行时/行为类排障事实库）](docs/known-pitfalls.md)
- [iOS 开源视频剪辑框架选型调研报告](docs/research/iOS开源视频剪辑框架选型调研报告.md)
- [图片编辑框架设计对比与借鉴分析](docs/research/图片编辑框架设计对比与借鉴分析.md)
- [POC 验证清单](docs/archive/poc-verification-checklist.md)
- [剪辑 Agent App 接入 spec](docs/superpowers/specs/2026-10-13-agent-app-integration-design.md) · [计划](docs/superpowers/plans/2026-10-13-agent-app-integration.md)
- [Kadr POC 设计 spec / 实现计划](docs/superpowers/specs/2026-10-08-kadr-poc-skeleton-design.md) · [计划](docs/superpowers/plans/2026-10-08-kadr-poc-skeleton.md)
