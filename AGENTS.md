# AGENTS.md

给在本仓库工作的 AI agent（以及协作者）的指引。目标读者是零上下文进入的 agent：看完即可安全改动代码。

## 项目是什么

iOS 视频剪辑 App（SwiftUI + AVFoundation），当前为 Kadr POC 阶段：用 [Kadr](https://github.com/SteliyanH/kadr) DSL 引擎验证「多段拼接 + 转场 + 变速 + 字幕 + headless 导出」最小闭环。架构分三层：

- **POCCore**（`KadrPOC/Sources/POCCore/`）：核心库
  - 编辑状态层（纯 Swift，无 AVFoundation 依赖）：`EditPlan`（v2：含素材登记表 `assets`，clip/字幕用 `assetID` 引用）/ `PlanClip` / `PlanTransition` / `AssetItem` / `EditStore` / `UndoStack` / `EditPlanValidator`
  - 引擎适配层（**唯一允许 `import Kadr` / `import KadrCaptions` / `import KadrPhotos` 的地方**）：`EngineBridge` / `PreviewBridge` / `ExportRunner` / `PhotosBridge`
  - 基础设施：`AssetResolver` / `AssetSynthesizer`（AVAssetWriter 生成测试素材）/ `AssetImporter`（外部文件入库 + 元数据探测）/ `DraftStore`（草稿原子落盘/恢复/完整性校验，格式 = EditPlan JSON）/ `PlanLoader` / `SamplePlan` / `SilentAudio` / `CaptionImageRenderer`
- **kadrpoc-cli**（`KadrPOC/Sources/kadrpoc-cli/`）：Agent 链路 headless 验证入口，四子命令 `sample` / `validate` / `export` / `genassets`
- **App 壳**（`App/JangyPOC/`）：SwiftUI 表现层，薄——只做状态装配与 UI，业务逻辑一律在 POCCore。本地 SwiftPM 引用 KadrPOC 包

## 常用命令

```bash
# 测试（74 个，含导出端到端；全绿才算过）
cd KadrPOC && swift test

# CLI 冒烟
swift run kadrpoc-cli genassets
swift run kadrpoc-cli sample
swift run kadrpoc-cli validate <plan.json> --assets ./Assets
swift run kadrpoc-cli export <plan.json> -o out.mp4 --assets ./Assets

# App 编译验证
xcodebuild -project App/JangyPOC/JangyPOC.xcodeproj -scheme JangyPOC \
  -destination 'generic/platform=iOS Simulator' build
```

## 硬性约定

- **CLI 输出契约**：stdout 只走结构化 JSON/JSONL；日志、错误、人工可读信息一律 stderr。exit code：0 成功 / 1 JSON 解码失败 / 2 语义校验失败 / 3 引擎错误。改动时保持这个契约，自动化链路依赖它
- **编辑必经 `EditStore.apply`**：所有 plan 修改通过它进入，校验失败不压撤销栈。不要绕过它直接改 `store.plan`
- **Kadr 依赖收敛**：新增引擎调用放引擎适配层，不要在状态层或 App 层 `import Kadr` / `KadrCaptions` / `KadrPhotos`
- **素材引用走登记表**：`PlanClip.assetID` / `CaptionTrack.assetID` 必须指向 `plan.assets` 里的 `AssetItem`；不要在 plan JSON 里写文件名直引（v2 起 `MediaRef` 已删除）。新增素材须先登记再引用，登记 + 追加片段放同一次 `EditStore.apply`（单撤销步）
- **草稿读写必经 `DraftStore`**：draft.json 与素材同目录，原子写入 + schema 版本守卫（过新拒绝加载，不静默丢字段）。不要在 App 层手写 draft.json；素材完整性问题经 `verify` 报告显式上报，不静默丢弃
- **命名避让**：模型层用 `PlanClip` / `PlanTransition`，因为 Kadr 有同名 `Clip` 协议与 `Transition` 枚举，同模块会歧义
- **提交信息用中文**，风格参照 `git log`（如 `App: 导出改为写入系统相册（…）`）；代码注释同样用中文
- **生成产物入库**：App 产物目录是 `.gitignore` 的；`KadrPOC/.gitignore` 忽略 `.build/` 与 `TestArtifacts/`（e2e 抽帧核对图不入库）

## 已知坑

- **Xcode 26 SDK 改了 `PHAssetCreationRequest.addResource` 的导入签名**：新 SDK 是 `addResource(with:fileURL:options:)`，旧文档里的 `addResource(_:fileURL:options:)` 编不过
- **字幕不进预览**：Kadr 官方明确 overlay 仅导出时烧录（`AVVideoCompositionCoreAnimationTool`），`makePlayerItem()` 预览无字幕。App 用 SwiftUI Text 叠加层按播放器时间近似显示——「所见即所导」对字幕降级为「预览近似」
- **转场重叠语义**：dissolve 与相邻片段重叠，渲染时长 ≠ `Video.duration` 求和值（样例工程实测 9.5s vs 10.5s）。e2e 断言基于实测值，不要「修正」成求和值
- **App 首次启动**同步合成测试素材会阻塞主线程数秒（幂等，仅首次）——已知 POC 取舍，正式版要移出启动关键路径
- **预览 player 生命周期**：`PlayerController.rebuild()` 换 player 前必须同步 `pause()` 旧实例 + 取消轮询 Task——旧 player 的回收依赖 dealloc（时机不受控），不主动停会出现「界面无播放器却有声音」的孤儿播放；轮询 Task 必须弱捕获 player，防止 Task 泄漏把旧 player 钉在内存里。rebuild 的 await 期间可能又来一次 rebuild，安装 player 前必须再查 `Task.isCancelled`；重建保留播放状态（旧 player 暂停/播完则新的不自动出声）
- **转场预览直通怪癖（iOS 26 模拟器实测）**：转场路径（双视频轨 composition）中素材分辨率恰等于 preset renderSize 时，显示管线把解码 buffer 直通 CA image queue，像素格式被拒（-11800 / 底层 -19230）→ `AVPlayerItemFailedToPlayToEndTime`，播到转场即停；identity transform 微扰无效（判定基于尺寸相等），`PreviewBridge.breakRenderSizeEquality` 给 renderSize 加 0.5pt 规避。注意 `AVPlayerItem.videoComposition` setter 是 copy 语义，改完要 mutableCopy 赋回。真机是否需要规避待验证（见 roadmap backlog）
- **iOS 26 SDK 弃用 `AVMutableVideoComposition` 族**（Swift 侧，提示用 `AVVideoComposition.Configuration`）：目前只是警告，Kadr 与本仓库都还在用；`AVMutableVideoCompositionLayerInstruction(assetTrackID:)` 的 Swift 导入已消失，要用 `init(assetTrack:)`
- **SwiftPM 包身份冲突警告**：kadr-captions / kadr-photos 的 Package.swift 指向上游 `SteliyanH/kadr`，与根包的 `timehzy/kadr` 同身份——SwiftPM 目前仅警告（根包 URL 生效），官方提示未来版本会升级为 error。届时需在 fork 上改写依赖 URL 并打新 tag
- **kadr-photos resolver 要授权**：`PhotosClipResolver` 要求 readWrite 授权（.authorized/.limited），即使 PHPicker 本身免授权——导入前必须先 `PhotosBridge.requestReadAccess()`；App 需 `NSPhotoLibraryUsageDescription`
- **kadr-photos 默认 preset 降帧率**：`AVAssetExportPresetHighestQuality` 会把高帧率视频压到 30fps。`PhotosBridge` 优先 passthrough（保 HDR/高帧率且秒级完成），失败回退重编码——改这段逻辑时保留这个顺序

## 文档地图

| 文件 | 内容 |
|---|---|
| [README.md](README.md) | 项目概览与快速开始 |
| [docs/iOS开源视频剪辑框架选型调研报告.md](docs/iOS开源视频剪辑框架选型调研报告.md) | 框架选型依据（为什么用 Kadr） |
| [docs/图片编辑框架设计对比与借鉴分析.md](docs/图片编辑框架设计对比与借鉴分析.md) | 图片编辑框架借鉴分析 |
| [docs/poc-verification-checklist.md](docs/poc-verification-checklist.md) | 真机手动验证清单 + POC 结论模板 |
| [docs/roadmap-path-a.md](docs/roadmap-path-a.md) | 立项路线图：路径 A 落地顺序、backlog、POC 已知取舍 |
| [docs/superpowers/specs/2026-10-08-kadr-poc-skeleton-design.md](docs/superpowers/specs/2026-10-08-kadr-poc-skeleton-design.md) | POC 设计 spec |
| [docs/superpowers/plans/2026-10-08-kadr-poc-skeleton.md](docs/superpowers/plans/2026-10-08-kadr-poc-skeleton.md) | 实现计划（含 API 核实记录与对 spec 的调整） |
