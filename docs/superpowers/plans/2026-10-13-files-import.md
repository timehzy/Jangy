# 「文件 App 导入」通道实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 新增文件 App 导入通道：UIDocumentPicker 多选视频 → 素材库落盘 → 追加时间线，与相册导入共用尾部链路。

**Architecture:** 设计 spec 见 `docs/superpowers/specs/2026-10-13-files-import-design.md`。新增 `FilesPicker`（`UIDocumentPickerViewController(forOpeningContentTypes:asCopy: true)` 薄封装，系统代拷临时文件，零 security-scope 管理）；AppModel 抽出两条渠道共用的导入管线 `importPipeline`（渠道差异仅在「来源标识 → 临时文件 URL」解析步），新增 `importVideosFromFiles(urls:)` 入口（`origin: .files`）；ContentView「导入」按钮改 Menu。

**Tech Stack:** SwiftUI / UIKit（UIDocumentPickerViewController）/ UniformTypeIdentifiers / Swift Observation。

**关键约束（AGENTS.md 硬性约定）：**
- 编辑必经 `EditStore.apply`（登记素材 + 追加片段放同一次 apply，单撤销步）
- 素材引用走 `assets` 登记表 + `assetID`
- Kadr 依赖收敛在引擎适配层——本计划不新增任何 `import Kadr*`
- 提交信息用中文，风格参照 `git log`

---

### Task 1: FilesPicker（文件选择器薄封装）

**Files:**
- Create: `App/JangyPOC/JangyPOC/FilesPicker.swift`

- [x] **Step 1: 创建 FilesPicker.swift**

```swift
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 文件 App 视频选择器：UIDocumentPickerViewController 的薄封装。
/// asCopy: true —— 系统把选中文件拷入 App 可访问的临时目录，返回 URL 直接可读，
/// 无需手工管理 security-scoped resource；后续 AssetImporter move 入库（与相册路径同构）。
struct FilesPicker: UIViewControllerRepresentable {
    /// 完成回调：选中文件的临时 URL 列表；取消/未选则为空数组
    let onFinish: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.movie], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onFinish: ([URL]) -> Void

        init(onFinish: @escaping ([URL]) -> Void) { self.onFinish = onFinish }

        nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            Task { @MainActor in self.onFinish(urls) }
        }

        nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            Task { @MainActor in self.onFinish([]) }
        }
    }
}
```

说明：模式对照同目录 `PhotoLibraryPicker.swift`（Coordinator + nonisolated 回调 + MainActor 转发）。

- [x] **Step 2: 确认新文件已加入 Xcode target**

JangyPOC.xcodeproj 若用文件系统同步组（Xcode 16 默认），新文件自动进 target。用编译验证：

Run: `xcodebuild -project App/JangyPOC/JangyPOC.xcodeproj -scheme JangyPOC -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED（此时 FilesPicker 尚无引用，可能有未使用警告，属正常）

- [x] **Step 3: Commit**

```bash
git add App/JangyPOC/JangyPOC/FilesPicker.swift
git commit -m "App: 新增 FilesPicker——UIDocumentPicker 视频多选薄封装（asCopy 系统代拷，免 security-scope 管理）

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 2: AppModel 抽出共用导入管线（纯重构，行为不变）

**Files:**
- Modify: `App/JangyPOC/JangyPOC/AppModel.swift:103-148`

- [x] **Step 1: 重构 importVideos，抽出 importPipeline**

将 `AppModel.swift` 第 103-148 行的 `importVideos(assetIdentifiers:)` 整个替换为：

```swift
    /// 两条导入渠道（相册/文件）共用的导入管线：来源标识 → 临时文件 URL（resolve 闭包，
    /// 渠道差异只在这一步）→ 逐个 move 进素材库 → 一次 apply 登记素材 + 追加片段
    /// （单撤销步）。失败的单个素材不阻断其余导入。
    /// - Parameters:
    ///   - origin: 登记到 AssetItem.origin 的渠道标识
    ///   - failureHint: 失败汇总文案里的原因提示（按渠道区分）
    ///   - resolve: 把来源标识解析成 importer 可接管的临时文件 URL；
    ///     回调参数为 (来源, 序号, 总数)，供相册渠道换算 iCloud 下载细粒度进度
    private func importPipeline<Source>(_ sources: [Source],
                                        origin: AssetOrigin,
                                        failureHint: String,
                                        resolve: (Source, Int, Double) async throws -> URL) async {
        let total = Double(sources.count)
        var items: [AssetItem] = []
        var failures = 0
        for (index, source) in sources.enumerated() {
            do {
                let tempFile = try await resolve(source, index, total)
                let item = try await importer.importVideo(from: tempFile, origin: origin)
                items.append(item)
            } catch {
                failures += 1
            }
            importProgress = Double(index + 1) / total
        }
        if !items.isEmpty {
            edit {
                $0.assets.append(contentsOf: items)
                for item in items {
                    // duration 探测失败时不追加片段（避免 range 无依据），素材仍入库
                    if let duration = item.duration {
                        $0.clips.append(PlanClip(assetID: item.id, range: 0...duration))
                    }
                }
            }
        }
        importProgress = nil
        if failures > 0 {
            importMessage = "\(failures) 个素材导入失败（\(failureHint)）"
        }
    }

    /// 从相册导入视频：授权 → 逐个解析（iCloud 自动下载）→ 共用管线入库。
    func importVideos(assetIdentifiers: [String]) {
        guard !assetIdentifiers.isEmpty else { return }
        importProgress = 0
        importMessage = nil
        Task { @MainActor in
            guard await PhotosBridge.requestReadAccess() else {
                importProgress = nil
                importMessage = "没有相册读取权限（请在系统设置中允许访问相册）"
                return
            }
            await importPipeline(assetIdentifiers, origin: .photoLibrary,
                                 failureHint: "iCloud 下载或格式不支持") { identifier, index, total in
                try await PhotosBridge.resolveVideoFile(assetIdentifier: identifier) { fraction in
                    Task { @MainActor in
                        self.importProgress = (Double(index) + fraction) / total
                    }
                }
            }
        }
    }
```

行为等价核对点（重构红线，逐项对照原实现）：
- 进度语义不变：每项完成推进 `(index+1)/total`，相册渠道的 fraction 细粒度进度保留
- 失败计数与文案不变：「N 个素材导入失败（iCloud 下载或格式不支持）」
- `items` 为空不进 apply；duration 为 nil 只入库不追加片段
- 授权失败提前 return 的路径不变

- [x] **Step 2: 编译验证**

Run: `xcodebuild -project App/JangyPOC/JangyPOC.xcodeproj -scheme JangyPOC -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED

- [x] **Step 3: POCCore 测试回归（重构未触碰 POCCore，但必须确认全绿）**

Run: `cd KadrPOC && swift test`
Expected: 77 个测试全绿（0 failures）

- [x] **Step 4: Commit**

```bash
git add App/JangyPOC/JangyPOC/AppModel.swift
git commit -m "App: 导入尾部逻辑抽为 importPipeline——相册/文件两渠道共用，行为不变

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 3: AppModel 新增文件导入入口

**Files:**
- Modify: `App/JangyPOC/JangyPOC/AppModel.swift`（紧跟 Task 2 的 `importVideos` 之后插入）

- [x] **Step 1: 新增 importVideosFromFiles**

在 `importVideos(assetIdentifiers:)` 方法之后插入：

```swift
    /// 从文件 App 导入视频：picker（asCopy）已把文件拷入 App 临时目录，
    /// 无授权申请、无 iCloud 解析步，直接进共用管线。origin 登记为 .files。
    func importVideosFromFiles(urls: [URL]) {
        guard !urls.isEmpty else { return }
        importProgress = 0
        importMessage = nil
        Task { @MainActor in
            await importPipeline(urls, origin: .files,
                                 failureHint: "文件拷贝或格式不支持") { url, _, _ in url }
        }
    }
```

- [x] **Step 2: 编译验证**

Run: `xcodebuild -project App/JangyPOC/JangyPOC.xcodeproj -scheme JangyPOC -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED

- [x] **Step 3: Commit**

```bash
git add App/JangyPOC/JangyPOC/AppModel.swift
git commit -m "App: 新增文件 App 导入入口 importVideosFromFiles（origin .files，复用共用管线）

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 4: ContentView 入口改 Menu + 接线

**Files:**
- Modify: `App/JangyPOC/JangyPOC/ContentView.swift`

- [x] **Step 1: 修改 ContentView**

四处改动（行号以当前文件为准，共 69 行的小文件，直接对照改）：

1. 第 6 行后新增 state：

```swift
    @State private var showPhotoPicker = false
    @State private var showFilesPicker = false
```

2. 操作条注释与「导入」按钮（第 13、21-22 行）改为 Menu：

```swift
            // 操作条：撤销/重做 + 字幕开关 + 导入（相册/文件）+ 新建草稿 + 导出
```
```swift
                Menu("导入") {
                    Button("从相册导入") { showPhotoPicker = true }
                    Button("从文件导入") { showFilesPicker = true }
                }
                .disabled(model.isPreparingAssets || model.importProgress != nil)
```

3. 文件 picker sheet（紧跟现有 `.sheet(isPresented: $showPhotoPicker)` 块之后，第 62 行后）新增：

```swift
        .sheet(isPresented: $showFilesPicker) {
            FilesPicker { urls in
                showFilesPicker = false
                model.importVideosFromFiles(urls: urls)
            }
            .ignoresSafeArea()
        }
```

- [x] **Step 2: 编译验证**

Run: `xcodebuild -project App/JangyPOC/JangyPOC.xcodeproj -scheme JangyPOC -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED

- [x] **Step 3: 全量回归**

Run: `cd KadrPOC && swift test`
Expected: 77 个测试全绿

- [x] **Step 4: Commit**

```bash
git add App/JangyPOC/JangyPOC/ContentView.swift
git commit -m "App: 导入入口改 Menu（从相册导入/从文件导入），接入 FilesPicker

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 5: 模拟器手动验收 + roadmap 回填

**Files:**
- Modify: `docs/roadmap-path-a.md:47-48`

- [x] **Step 1: 模拟器准备导入源**

启动模拟器后，用 `xcrun simctl` 把测试视频放进文件 App（或直接用素材库已有文件）：

```bash
# 先跑一次 genassets 确保有测试素材
cd KadrPOC && swift run kadrpoc-cli genassets
# 找一个模拟器设备并打开文件 App，把素材拖入（或 simctl 分享）
xcrun simctl openurl booted "shareddocuments://"
```

也可在模拟器里直接把 `KadrPOC/Assets/*.mp4` 拖进 Files App 窗口。

- [x] **Step 2: 手动验收全链路**

在模拟器跑 App，逐项核对：

1. 「导入」Menu 出现两项：从相册导入 / 从文件导入
2. 从文件导入 → 文件 App 多选 ≥2 个视频 → 确认
3. 进度条按文件个数推进，完成后时间线追加对应片段
4. 预览可正常播放追加的片段
5. 导出成功（导出到相册）
6. 单个失败不阻断：混选一个非视频伪装文件（如改后缀的文本文件）时，其余正常导入，末尾出现「N 个素材导入失败（文件拷贝或格式不支持）」
7. 撤销一步：登记 + 追加整体回退（单撤销步）
8. 相册导入回归：从相册导入仍正常（Task 2 重构的行为等价性终验）

- [x] **Step 3: CLI 核对草稿完整性**

App  autosave 的 draft.json 即 EditPlan JSON，用 CLI 验证契约：

```bash
# draft.json 路径：模拟器容器 Documents 目录，先定位
find ~/Library/Developer/CoreSimulator/Devices -name "draft.json" -path "*JangyPOC*" 2>/dev/null
cd KadrPOC && swift run kadrpoc-cli validate <上一步找到的 draft.json> --assets <同目录的素材目录>
```

Expected: exit code 0，stdout 为校验通过的结构化 JSON

- [x] **Step 4: roadmap 回填**

将 `docs/roadmap-path-a.md` P2 第一条改为：

```markdown
- [x] **「文件 App 导入」通道**（✅ 2026-10-13）：UIDocumentPicker asCopy 多选导入 → 素材库落盘 → 追加时间线全链路（`AssetOrigin.files` 落地）；AppModel 导入尾部抽为 `importPipeline` 两渠道共用；模拟器验收含混选失败文件不阻断、单撤销步回退、相册导入回归
```

- [x] **Step 5: Commit**

```bash
git add docs/roadmap-path-a.md
git commit -m "文档：P2 文件 App 导入通道验收回填（模拟器全链路 + CLI 草稿核对通过）

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Self-Review 记录

- **Spec 覆盖**：FilesPicker（Task 1）/ importPipeline 抽取 + importVideosFromFiles（Task 2、3）/ Menu 入口（Task 4）/ 验收与测试口径（Task 5）——spec 各节均有对应任务
- **占位符扫描**：无 TBD/TODO；所有代码步骤含完整代码
- **类型一致性**：`importPipeline(_:origin:failureHint:resolve:)`、`importVideosFromFiles(urls:)`、`FilesPicker(onFinish:)` 在 Task 2/3/4 间签名一致；`AssetOrigin.files` / `AssetItem` / `PlanClip(assetID:range:)` 均为 POCCore 现有公开类型
- **TDD 说明**：改动全部在 App 壳层（无测试 target），POCCore 零改动；可执行验证 = 77 测试回归 + xcodebuild 编译 + Task 5 手动验收，与 spec「测试与验收」节口径一致
