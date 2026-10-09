# 立项路线图（路径 A 落地计划）

> 2026-10-08 POC 结论落定后整理。选型依据见[调研报告](iOS开源视频剪辑框架选型调研报告.md)第 7 节路径 A；POC 验证记录见[poc-verification-checklist.md](poc-verification-checklist.md)。

## 已定论的结论

- **正式立项走路径 A：Kadr 全家桶直达**（2026-10-08）。POC 五个关键字（多段拼接 / 转场 / 变速 / 字幕 / headless 导出）+ EditPlan JSON → DSL 端到端 + 4K HDR CLI 侧全部 ☑。
- Kadr 依赖已切内部镜像 fork（`timehzy/kadr`、`timehzy/kadr-captions`、`timehzy/kadr-photos`），版本约束不变。fork 不会自动跟随上游：第一次需要上游修复时给三个 fork 配 `upstream` remote，手动同步、跑完全部测试再合入。
- **HDR 直通已定调为特性**（2026-10-09）：导出保留 BT.2020 + HLG 元数据，定位「HDR 全链路」；分享到不支持 HDR 平台的发灰问题留到正式版导出管线处理。素材导入侧相应采用 passthrough 优先策略（不重编码、保 HDR/高帧率）。

## 落地顺序（按优先级）

| # | 事项 | 状态 | 说明 |
|---|---|---|---|
| 1 | Kadr fork 内部镜像 + 锁版本 | ✅ 2026-10-08 | 风险登记册「单作者依赖」的核心缓解，成本极低，第一天就做 |
| 2 | 素材导入 | ✅ 2026-10-09 | EditPlan v2 素材登记表（`assets` + `assetID` 引用，为素材管理打底）；kadr-photos fork（v0.11）；App 相册多选导入（passthrough 优先 → 素材库落盘 → 追加时间线）；64 测试全绿 + CLI 契约不变 |
| 3 | 草稿持久化 | ✅ 2026-10-09 | 草稿 = EditPlan JSON（与 Agent 契约同格式，一鱼两吃）：`DraftStore` 原子写入 + sortedKeys 字节稳定 + schema 版本守卫（过新拒绝加载）；完整性守卫 = 存在性 + 元数据重探测比对，缺失/漂移显式报告；App 启动恢复 + 防抖 autosave + 「新建草稿」（经 `EditStore.apply`，可撤销）。**决策**：不引入 kadr-persistence 包（它持久化引擎层 `Video`，恢复需反向桥且丢素材登记表语义），只借鉴理念；不做 SHA-256 内容寻址 |
| 4 | POC 取舍清理入 backlog | ✅ 2026-10-09 | backlog 定级完成：合并「POC 已知取舍」为单一清单，按 P0–P3 优先级 + 执行主体（agent/人工/真机）+ 验收标准梳理，见下节 |
| 5 | 音频（kadr-audio）/ 拍摄（NextLevel）/ MCP 化 | 🔜 下一个任务候选 | 差异化功能，遵循「UI 用 kadr-ui 原型，差异化后置」原则，素材导入 + 持久化已跑通，可排期 |

## Backlog（2026-10-09 第四步清理定级）

定级口径：

- **优先级**：P0 = 有外部时效或暴露正确性风险，尽快；P1 = 影响体验或阻塞后续技术决策，下个迭代；P2 = 功能扩展，随版本排期；P3 = 外部依赖或人工调研，持续观察
- **执行主体**：`agent` = 编码类 agent 可独立完成；`人工` = 需人决策/操作；`真机` = 需真机环境验证
- 每条附验收标准，做完回填日期与结论

### P0

- [x] **向 Kadr 上游提三个 issue**（✅ 2026-10-09，已提交 `SteliyanH/kadr`，跟进回复即可）
  - Issue 1（Critical）：无音频素材导出静默 passthrough → [#201](https://github.com/SteliyanH/kadr/issues/201)
  - Issue 2（macOS 平台）：TextOverlay 的 CATextLayer 在 headless 导出不渲染 → [#202](https://github.com/SteliyanH/kadr/issues/202)
  - Issue 3（iOS 模拟器）：转场双轨 composition + 素材分辨率 == renderSize → CA image queue 拒绝直通 buffer（-11800/-19230），播到转场即停 → [#203](https://github.com/SteliyanH/kadr/issues/203)；POC 侧已用 renderSize+0.5pt 规避（`PreviewBridge.breakRenderSizeEquality`），回归测试 `PreviewPlaybackTests`
  - 提交前已对 v1.1.0 源码逐条核实根因描述；若上游有回复需跟进，回填结论到本节
  - 后续（2026-10-09）：#201 已提修复 PR → [#204](https://github.com/SteliyanH/kadr/pull/204)（根因修复：构建期移除空音频轨 + ClipVolume 仅在真实插入音频时登记；663 测试全绿）。CLA 已签署（提交邮箱已改 yiliforever@qq.com），等作者 review；合并后 POC 侧可评估移除 `SilentAudio` 兜底

### P1

- [ ] **素材导入真机验证**（`真机`）：授权弹窗 / iCloud 素材下载进度 / HDR 相册视频导入后导出（passthrough 保真链路）/ 慢动作视频保帧率
  - 验收：四项逐条记录结果，问题单独立项
- [ ] **转场预览直通问题真机验证**（`真机`）：若真机无此问题（模拟器 CA image queue 像素格式支持更窄），正式版移除 renderSize 微扰
  - 验收：真机结论记录；若移除微扰，`PreviewPlaybackTests` 回归全绿
- [ ] **App 真机 4K HDR 预览流畅度/发热**（`真机`）：清单验证点③最后一格，主观记录即可
- [ ] **首次启动同步合成测试素材阻塞主线程**（`agent`）：正式版移出启动关键路径（异步合成 + 进度态）
  - 验收：启动首屏渲染不等待素材合成；`swift test` 全绿

### P2

- [ ] **「文件 App 导入」通道**（`agent`）：UIDocumentPicker，`AssetOrigin.files` 已预留
  - 验收：文件 App 多选导入 → 素材库落盘 → 追加时间线全链路，测试覆盖
- [ ] **App 内素材库管理 UI**（`agent`）：网格/缩略图/删除未引用素材；kadr-photos 有 `assets(in:)` 相册列举可用，缩略图需自建 PHImageManager + 缓存
  - 验收：素材库网格展示 + 删除未引用素材后 plan 完整性校验通过
- [ ] **字幕预览近似的正式版决策**（`人工` 决策 + `agent` 执行）：Kadr overlay 仅导出时烧录，POC 用 SwiftUI Text 叠加层近似——「所见即所导」对字幕降级为「预览近似」
  - 验收：决策记录（接受近似 / 出精确预览技术方案）
- [ ] **转场重叠语义的时长口径统一**（`agent`）：渲染时长 ≠ `Video.duration` 求和值（实测 9.5s vs 10.5s）——e2e 断言已基于实测值，UI 时长显示同样要用实测口径
  - 验收：App 各处时长展示与导出实测时长一致
- [ ] **导出管线 HDR→SDR 降级选项**（`agent`，正式版）：HDR 直通已定调为特性，但分享到不支持 HDR 平台的发灰问题需导出侧提供 SDR 降级（SDR 路径 POC 已验证：Kadr Codec.h264 或 709 composition）
  - 验收：导出设置提供 HDR 直通 / SDR 降级两档，SDR 档产物在不支持 HDR 设备上显示正常

### P3

- [ ] **iOS 17 底线覆盖率调研**（`人工`）：App Store Connect 或第三方统计，确认目标用户群 iOS 17+ 覆盖率
- [ ] **SwiftPM 包身份冲突预警**（外部依赖；届时 `agent` 执行）：kadr-captions / kadr-photos 的 Package.swift 指向上游 kadr，与 timehzy 镜像同身份——当前仅警告，官方称未来版本升级为 error
  - 验收（触发时）：在 fork 上改写依赖 URL 并打新 tag，全量测试通过后切版本约束

### 已关闭

- [x] ~~HDR 直通产品决策~~ → 已定调为特性（2026-10-09，见「已定论的结论」）

## 素材导入选型记录（2026-10-09）

对比 kadr-photos / YPImagePicker / 原生 PhotosPicker 后选定 **kadr-photos fork**：

- YPImagePicker 出局：选中后强制 AVAssetExportSession 重编码才给回调——HDR/full-range 元数据有丢失先例（issue #806）、4K 大文件有内存爆炸史（#498），与「HDR 直通特性」直接冲突；内置 trimmer/滤镜与 Kadr 管线重复建设；需 readWrite 全量授权；不支持文件 App 导入；Stevia/PryntTrimmerView 双 `.exact` 依赖。
- 原生 PhotosPicker 出局（作为长期方案）：`loadTransferable` 可用但 iCloud 进度、慢动作保帧率、Live Photo、typed error 都要自建；且系统选择器 UI 零定制，撑不起未来的 App 内素材库。
- kadr-photos 入选：PHAsset→文件 URL 的异步桥（iCloud 进度/慢动作/Live Photo/typed error）正是缺的；`assets(in:)` 相册列举可支撑未来自建素材库 UI；Apache-2.0 与镜像策略同构。弱项（选择器 UI 零定制、无缩略图/持久化）反正都要自建。

## 下一步任务的入口

任务 #4 已完成（2026-10-09）：backlog 定级见上节。下一个任务从 backlog P0/P1（上游 issue、首次启动阻塞治理——agent 可直接做；真机验证项需人配合）或 #5（音频/拍摄/MCP 化）中排。进会话后先读 [AGENTS.md](../AGENTS.md)，关键约束：编辑必经 `EditStore.apply`、素材引用走 `assets` 登记表 + `assetID`、Kadr 依赖收敛在引擎适配层、CLI stdout 只走结构化 JSON、草稿读写必经 `DraftStore`。
