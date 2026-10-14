# AGENTS.md

给在本仓库工作的 AI agent（以及协作者）的指引。目标读者是零上下文进入的 agent：看完即可安全改动代码。

## 项目是什么

iOS 视频剪辑 App（SwiftUI + AVFoundation），基于 [Kadr](https://github.com/SteliyanH/kadr) DSL 引擎（已验证「多段拼接 + 转场 + 变速 + 字幕 + headless 导出」最小闭环）。**阶段状态（2026-10-13）：POC 技术验证已收口，v1 正式版进入执行阶段**——范围（拍摄出局/音频后置/剪辑 Agent 入 v1）、字幕预览（时间对位示意层）、代码起点（基于 POC 演进）三项决策已拍板，见 [docs/roadmap-path-a.md](docs/roadmap-path-a.md)「正式版启动」。仓库结构：

- **JangyCore**（`Packages/JangyCore/Sources/JangyCore/`）：核心库（编辑状态 + 引擎适配 + 基础设施）
- **JangyTestSupport**（`Packages/JangyCore/Sources/JangyTestSupport/`）：测试脚手架（`SamplePlan` 样例工程 + `AssetSynthesizer` 测试素材合成器），仅测试与 CLI 依赖，App 不链接、不进正式产物
- **JangyAgent**（`Packages/JangyCore/Sources/JangyAgent/`）：剪辑 Agent（工具层 = 原子编辑工具集 + 编排层 = agent loop），L1 意图的 headless 消费方，App 与 CLI 共用
- **jangy-cli**（`Packages/JangyCore/Sources/jangy-cli/`）：Agent 链路 headless 验证入口，六子命令 `sample` / `validate` / `export` / `snapshot` / `genassets` / `agent`
- **App 壳**（`Jangy/`，根目录 `Jangy.xcodeproj`）：SwiftUI 表现层，本地 SwiftPM 引用 `Packages/JangyCore` 包

**架构与工程约束的唯一事实源是 [docs/architecture-covenant.md](docs/architecture-covenant.md)**（分层、数据流、建模、联动、预览规则、CLI 契约等一律以它为准），动手改代码前必读；本文件不复述其中的条款。

## 常用命令

```bash
# 测试（125 个，含导出端到端；全绿才算过）
cd Packages/JangyCore && swift test

# CLI 冒烟
swift run jangy-cli genassets
swift run jangy-cli sample
swift run jangy-cli validate <plan.json> --assets ./Assets
swift run jangy-cli export <plan.json> -o out.mp4 --assets ./Assets
swift run jangy-cli snapshot <plan.json> --at 1.0 --assets ./Assets -o ./Frames

# 剪辑 Agent 冒烟（凭据在 .agent-env.local（gitignore，找维护者要）；不打真实 API 的用例都在 swift test 里）
source .agent-env.local
swift run jangy-cli agent "把第二段切成两半并加字幕" \
  --plan draft.json -o final.json --export out.mp4 --assets ./Assets \
  --base-url "$JANGY_AGENT_BASE_URL" --model "$JANGY_AGENT_MODEL"

# 模拟器手动验证要样例内容时，往 App 沙盒播种（App 首启即空时间线，不再自带样例）：
# APP_DIR=$(模拟器上本 App 的 Application Support/Jangy 目录)
swift run jangy-cli genassets --to "$APP_DIR" && swift run jangy-cli sample > "$APP_DIR/draft.json"

# Agent 凭据播种（App 内用 Agent 时需要；字段对应 .agent-env.local 的三个变量）：
# echo '{"baseURL":"...","model":"...","apiKey":"..."}' > "$APP_DIR/agent-config.json"

# App 编译验证
xcodebuild -project Jangy.xcodeproj -scheme Jangy \
  -destination 'generic/platform=iOS Simulator' build
```

## 协作约定

架构与工程约束不在此复述，见 [架构公约](docs/architecture-covenant.md)。本节只留协作流程约定：

- **提交信息用中文**，风格参照 `git log`（如 `App: 导出改为写入系统相册（…）`）；代码注释同样用中文
- **生成产物入库**：App 产物目录是 `.gitignore` 的；`Packages/JangyCore/.gitignore` 忽略 `.build/` 与 `TestArtifacts/`（e2e 抽帧核对图不入库）

## 已知坑（构建/编译期高频）

运行时/行为类坑（引擎行为、预览、相册集成等）在 [docs/known-pitfalls.md](docs/known-pitfalls.md)。本节只留构建编译期就会撞上的：

- **iOS 26 SDK 弃用 `AVMutableVideoComposition` 族**（Swift 侧，提示用 `AVVideoComposition.Configuration`）：目前只是警告，Kadr 与本仓库都还在用；`AVMutableVideoCompositionLayerInstruction(assetTrackID:)` 的 Swift 导入已消失，要用 `init(assetTrack:)`
- **SwiftPM 包身份冲突警告**：kadr-captions / kadr-photos 的 Package.swift 指向上游 `SteliyanH/kadr`，与根包的 `timehzy/kadr` 同身份——SwiftPM 目前仅警告（根包 URL 生效），官方提示未来版本会升级为 error。届时需在 fork 上改写依赖 URL 并打新 tag
- **AnyLanguageModel 宏指纹信任**：JangyAgent 链进 App 后，首次在本机 xcodebuild 可能报 `Macro "AnyLanguageModelMacros" ... must be enabled`——机器级宏信任状态问题，非接线错误；xcodebuild 加 `-skipMacroValidation`，或在 Xcode GUI 里信任一次该 macro plugin

## 文档地图

| 文件 | 内容 |
|---|---|
| [README.md](README.md) | 项目概览与快速开始 |
| [docs/research/iOS开源视频剪辑框架选型调研报告.md](docs/research/iOS开源视频剪辑框架选型调研报告.md) | 框架选型依据（为什么用 Kadr） |
| [docs/research/图片编辑框架设计对比与借鉴分析.md](docs/research/图片编辑框架设计对比与借鉴分析.md) | 图片编辑框架借鉴分析 |
| [docs/archive/poc-verification-checklist.md](docs/archive/poc-verification-checklist.md) | 真机手动验证清单 + POC 结论模板 |
| [docs/roadmap-path-a.md](docs/roadmap-path-a.md) | 立项路线图：路径 A 落地顺序、backlog 定级（P0–P3 + 执行主体 + 验收标准） |
| [docs/architecture-covenant.md](docs/architecture-covenant.md) | **v1 架构公约（架构与工程约束唯一事实源）**：L0–L4 分层、单向数据流、clip 内禀属性建模、原语事件+reactor 联动、特殊素材范围、所见即所得硬规则 |
| [docs/known-pitfalls.md](docs/known-pitfalls.md) | 已知坑（运行时/行为类）：引擎行为、预览、相册集成的排障事实库 |
| [docs/superpowers/specs/2026-10-08-kadr-poc-skeleton-design.md](docs/superpowers/specs/2026-10-08-kadr-poc-skeleton-design.md) | POC 设计 spec |
| [docs/superpowers/plans/2026-10-08-kadr-poc-skeleton.md](docs/superpowers/plans/2026-10-08-kadr-poc-skeleton.md) | 实现计划（含 API 核实记录与对 spec 的调整） |
