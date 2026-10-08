# Jangy

视频剪辑 App，iOS 原生技术实现（SwiftUI + AVFoundation）。当前处于 **Kadr POC 阶段**：基于 [Kadr](https://github.com/SteliyanH/kadr) DSL 引擎验证「多段拼接 + 转场 + 变速 + 字幕 + headless 导出」的最小闭环。

## 仓库结构

```
├── App/JangyPOC/          # iOS App 壳（SwiftUI，iOS 17+，Xcode 工程）
│   └── JangyPOC/          #   表现层源码：预览/时间线/操作条/导出（本地引用 KadrPOC 包）
├── KadrPOC/               # SwiftPM 包：POCCore 库 + kadrpoc-cli 可执行 + 48 个测试
│   ├── Sources/POCCore/   #   编辑状态层（纯 Swift）+ 引擎适配层（唯一 import Kadr 的地方）
│   ├── Sources/kadrpoc-cli/#   Agent 链路 headless 验证入口
│   ├── Tests/POCCoreTests/#
│   └── Assets/            #   测试素材（clip1-3.mp4 + sample.srt，可由 genassets 重新生成）
└── docs/                  # 选型调研报告 / POC 验证清单 / 设计 spec 与计划
```

## 技术栈

Swift 6.3 · Xcode 26.4 · SwiftPM · SwiftUI（iOS 17+）· [Kadr 1.0](https://github.com/SteliyanH/kadr) · [KadrCaptions 0.12](https://github.com/SteliyanH/kadr-captions) · swift-argument-parser

## 快速开始

### 跑测试（48 个，含导出端到端）

```bash
cd KadrPOC && swift test
```

### CLI 冒烟（headless 导出链路）

```bash
cd KadrPOC
swift run kadrpoc-cli genassets                 # 生成测试素材到 ./Assets
swift run kadrpoc-cli sample                    # 输出内置演示 EditPlan JSON
swift run kadrpoc-cli validate plan.json --assets ./Assets   # 结构 + 素材校验
swift run kadrpoc-cli export plan.json -o out.mp4 --assets ./Assets
```

CLI 约定：stdout 只走结构化 JSON/JSONL，日志与错误走 stderr；exit code 0 成功 / 1 JSON 解码失败 / 2 语义校验失败 / 3 引擎错误。

### iOS App

用 Xcode 打开 `App/JangyPOC/JangyPOC.xcodeproj`，选择真机或模拟器运行。首次启动会同步合成测试素材（阻塞数秒，仅一次）。功能：预览播放（字幕叠加层）、撤销/重做、字幕开关、追加片段、导出到系统相册。

## 当前状态

- [x] Kadr POC 工程骨架（14 任务 + 评审修复，48 测试全绿）：编辑状态层、快照撤销栈、引擎适配层、CLI 四子命令、App 壳
- [x] 导出写入系统相册（临时文件渲染 → PHPhotoLibrary 注册）
- [x] 真机手动验证通过（2026-10-08，清单见 [docs/poc-verification-checklist.md](docs/poc-verification-checklist.md)）
- [ ] 4K HDR 素材验证 · iOS 17 覆盖率调研（待办，见清单）

已知取舍：

- 字幕预览以 SwiftUI Text 叠加层近似（Kadr overlay 不进入 `makePlayerItem()` 预览，仅导出时烧录）
- 转场重叠语义：dissolve 与相邻片段重叠，渲染时长 ≠ Kadr `Video.duration` 求和值（实测 9.5s vs 10.5s）

## 文档

- [iOS 开源视频剪辑框架选型调研报告](docs/iOS开源视频剪辑框架选型调研报告.md)
- [图片编辑框架设计对比与借鉴分析](docs/图片编辑框架设计对比与借鉴分析.md)
- [POC 验证清单](docs/poc-verification-checklist.md)
- [Kadr POC 设计 spec / 实现计划](docs/superpowers/specs/2026-10-08-kadr-poc-skeleton-design.md) · [计划](docs/superpowers/plans/2026-10-08-kadr-poc-skeleton.md)
