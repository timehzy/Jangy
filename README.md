# Jangy

视频剪辑 App，iOS 原生技术实现（SwiftUI + AVFoundation）。POC 技术验证已收口（2026-10-13），当前处于 **v1 正式版开发阶段**：基于 [Kadr](https://github.com/SteliyanH/kadr) DSL 引擎，决策记录见 [路线图](docs/roadmap-path-a.md)「正式版启动」。

## 仓库结构

```
├── Jangy.xcodeproj        # iOS App 工程（iOS 17+）
├── Jangy/                 # App 壳源码（SwiftUI 表现层：预览/时间线/操作条/导出）
├── Packages/
│   └── JangyCore/         # SwiftPM 包：JangyCore 库 + jangy-cli 可执行 + 85 个测试
│       ├── Sources/JangyCore/  # 编辑状态层（纯 Swift）+ 引擎适配层（唯一 import Kadr 的地方）
│       ├── Sources/JangyTestSupport/  # 测试脚手架（样例工程/素材合成器），不进 App 产物
│       ├── Sources/jangy-cli/  # Agent 链路 headless 验证入口
│       ├── Tests/JangyCoreTests/
│       └── Assets/        # 测试素材（clip1-3.mp4 + sample.srt，可由 genassets 重新生成）
└── docs/                  # 选型调研报告 / POC 验证清单 / 路线图 / 设计 spec 与计划
```

## 技术栈

Swift 6.3 · Xcode 26.4 · SwiftPM · SwiftUI（iOS 17+）· [Kadr 1.0](https://github.com/SteliyanH/kadr) · [KadrCaptions 0.12](https://github.com/SteliyanH/kadr-captions) · [KadrPhotos 0.11](https://github.com/SteliyanH/kadr-photos) · swift-argument-parser

> Kadr 系依赖均走内部镜像 fork（`timehzy/kadr`、`timehzy/kadr-captions`、`timehzy/kadr-photos`），防上游单作者仓库变动。

## 快速开始

### 跑测试（85 个，含导出端到端）

```bash
cd Packages/JangyCore && swift test
```

### CLI 冒烟（headless 导出链路）

```bash
cd Packages/JangyCore
swift run jangy-cli genassets                 # 生成测试素材到 ./Assets
swift run jangy-cli sample                    # 输出内置演示 EditPlan JSON
swift run jangy-cli validate plan.json --assets ./Assets   # 结构 + 素材校验
swift run jangy-cli export plan.json -o out.mp4 --assets ./Assets
```

CLI 约定：stdout 只走结构化 JSON/JSONL，日志与错误走 stderr；exit code 0 成功 / 1 JSON 解码失败 / 2 语义校验失败 / 3 引擎错误。

### iOS App

用 Xcode 打开根目录 `Jangy.xcodeproj`，选择真机或模拟器运行。首次启动会在后台合成测试素材（仅一次）。功能：预览播放（字幕叠加层）、撤销/重做、字幕开关、**从相册导入视频素材**（PHPicker 多选，iCloud 自动下载，passthrough 优先保 HDR/高帧率）、导出到系统相册。

## 当前状态

- [x] Kadr POC 工程骨架（14 任务 + 评审修复，48 测试全绿）：编辑状态层、快照撤销栈、引擎适配层、CLI 四子命令、App 壳
- [x] 导出写入系统相册（临时文件渲染 → PHPhotoLibrary 注册）
- [x] 真机手动验证通过（2026-10-08，清单见 [docs/poc-verification-checklist.md](docs/poc-verification-checklist.md)）
- [x] 4K HDR CLI 侧验证通过（2026-10-08：导出/转场/色调全通过；HDR 直通与 HDR→SDR 双路均验证，见清单）
- [x] **POC 结论落定：正式立项走路径 A（Kadr 全家桶直达）**（2026-10-08，见 [验证清单](docs/poc-verification-checklist.md)）
- [x] 素材导入 v1（2026-10-09）：EditPlan v2 素材登记表（`assets` 表 + `assetID` 引用，替代文件名直引）；App 相册导入（kadr-photos resolver → 素材库落盘 → 时间线追加）
- [ ] iOS 17 覆盖率调研（人工调研项，见清单）

已知取舍：

- 字幕预览以 SwiftUI Text 叠加层近似（Kadr overlay 不进入 `makePlayerItem()` 预览，仅导出时烧录）
- 转场重叠语义：dissolve 与相邻片段重叠，渲染时长 ≠ Kadr `Video.duration` 求和值（实测 9.5s vs 10.5s）

## 文档

- [iOS 开源视频剪辑框架选型调研报告](docs/iOS开源视频剪辑框架选型调研报告.md)
- [图片编辑框架设计对比与借鉴分析](docs/图片编辑框架设计对比与借鉴分析.md)
- [POC 验证清单](docs/poc-verification-checklist.md)
- [立项路线图（路径 A 落地计划）](docs/roadmap-path-a.md)
- [Kadr POC 设计 spec / 实现计划](docs/superpowers/specs/2026-10-08-kadr-poc-skeleton-design.md) · [计划](docs/superpowers/plans/2026-10-08-kadr-poc-skeleton.md)
