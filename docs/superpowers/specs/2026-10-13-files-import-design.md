# 「文件 App 导入」通道设计（P2）

> 2026-10-13 定稿。Backlog 条目：roadmap-path-a.md P2「文件 App 导入」通道。
> 验收标准（roadmap 原文）：文件 App 多选导入 → 素材库落盘 → 追加时间线全链路，测试覆盖。

## 目标

在现有相册导入（PHPicker → PhotosBridge → AssetImporter → EditStore.apply）之外，新增文件 App 导入通道：UIDocumentPicker 多选视频 → 素材库落盘 → 追加时间线。`AssetOrigin.files` 枚举值已在 EditPlan v2 预留，本设计将其落地为真实的导入渠道。

## 范围

- **支持类型**：仅视频（`UTType.movie`）。与相册导入能力对齐；图片/音频目前上不了时间线（无对应的编辑/预览/导出链路），不收。
- **UI 入口**：现有「导入」按钮改为 Menu（「从相册导入」/「从文件导入」），不新增操作条按钮。
- **不做**：iCloud Drive 内大文件的下载进度展示（picker 的 asCopy 模式由系统处理拷贝，无法挂钩进度；进度按文件个数推进）、图片/音频导入、素材库管理 UI（另一条 P2）。

## 技术选型（已定）

采用 `UIDocumentPickerViewController(forOpeningContentTypes:asCopy: true)`：

- 系统把选中文件拷入 App 可访问的临时目录，返回 URL 直接可读——`AssetImporter.importVideo` 的 move 语义原样适用，与 kadr-photos 导出临时文件完全同构，无需手工管理 security-scoped resource。
- 与现有 `PhotoLibraryPicker` 同为 `UIViewControllerRepresentable` 薄封装，风格一致。
- 代价：picker 期间磁盘短暂双份（系统拷贝 + 入库 move 前），与相册路径临时文件行为一致，可接受。

被否决的备选：

- `asCopy: false` + `startAccessingSecurityScopedResource`：素材库模型本就要求自己持有文件，最终仍要 copy；scope 生命周期与 iCloud Drive 流式 file provider 协调是额外坑。
- SwiftUI `.fileImporter`：代码最少，但返回 URL 需手工管理 security scope（系统不代拷），且与现有 picker 封装风格不一致。

## 组件设计

### 1. `FilesPicker.swift`（App 层，新增）

`UIViewControllerRepresentable` 薄封装，对照 `PhotoLibraryPicker` 模式：

- 包装 `UIDocumentPickerViewController(forOpeningContentTypes: [UTType.movie], asCopy: true)`
- `allowsMultipleSelection = true`
- 完成回调 `[URL]`；取消/未选为空数组

### 2. AppModel：尾部逻辑抽取 + 新入口

相册路径 `importVideos(assetIdentifiers:)` 的尾部逻辑（逐个 `AssetImporter.importVideo` → 收集 `AssetItem` → 一次 `EditStore.apply` 登记素材 + 按 duration 追加 `PlanClip` → 失败计数汇总）抽成共用私有方法，两条渠道共用：

- 新增 `importVideosFromFiles(urls:)`：无授权申请、无 iCloud 解析步；进度按文件个数推进（`index/total`）；`origin: .files`；`displayName` 沿用源文件名（`importVideo` 默认行为）
- 单个文件失败不阻断其余导入；全部失败则不进入 `apply`
- 错误文案按渠道区分（文件渠道：拷贝或格式不支持）

`apply` 闭包语义不变（沿用相册路径）：`plan.assets.append(contentsOf:)` + 对每个 `duration` 探测成功的素材追加 `PlanClip(assetID:, range: 0...duration)`；duration 为 nil 的素材只入库不追加片段。登记 + 追加在同一次 `apply`，单撤销步。

### 3. ContentView：入口改 Menu

- 「导入」按钮改为 `Menu`：「从相册导入」/「从文件导入」
- 新增 `showFilesPicker` state + sheet 呈现 `FilesPicker`
- 门禁不变：`isPreparingAssets || importProgress != nil` 时禁用

## 数据流

```
FilesPicker(asCopy: true)
  → [URL]（系统已拷入 App 临时目录）
  → 循环 AssetImporter.importVideo(from: url, origin: .files)
      → move 进素材库（UUID 命名）+ 元数据探测 → AssetItem
  → 一次 EditStore.apply：assets 登记 + 按 duration 追加 PlanClip（单撤销步）
  → player.rebuild() + 防抖 autosave（edit() 既有行为）
  → 失败计数非零时 importMessage 汇总
```

## 错误处理

- picker 取消/未选：空数组，直接返回，无副作用
- 单文件 move/探测失败：累计 failures，末尾 `importMessage` 汇总，不阻断其余
- 全部失败：不进入 `apply`（plan 不变，不压撤销栈）
- `AssetImporter.importVideo` 探测失败不抛错（元数据留 nil），素材仍入库，仅不追加片段——与相册路径一致

## 测试与验收

- POCCore：`importVideo` 已有测试覆盖（`AssetImporterTests`），move 语义与元数据探测不变，无需新增；现有 77 测试须保持全绿
- 共用尾部逻辑抽取后行为等价，由现有 EditStore/validator 测试隐式覆盖
- 手动验收（模拟器/真机）：文件 App 多选导入 → 素材库落盘 → 时间线追加 → 预览正常 → 导出正常；导入后经 `kadrpoc-cli validate` 核对 plan JSON 完整性（draft.json 与 Agent 契约同格式）
