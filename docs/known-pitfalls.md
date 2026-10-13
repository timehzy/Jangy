# 已知坑（运行时 / 行为类）

> 排障事实知识库：记录症状的根因与背景，按主题分组。**约束条款不在这里**——凡已被立规的条目，规则以 [架构公约](architecture-covenant.md) 为准，本文只留成因事实并指向公约章节。构建/编译期高频坑在 [AGENTS.md](../AGENTS.md)。

## 引擎行为

- **字幕不进预览**：Kadr 官方明确 overlay 仅导出时烧录（`AVVideoCompositionCoreAnimationTool`），`makePlayerItem()` 预览无字幕；App 用 SwiftUI Text 叠加层按播放器时间近似显示（降级登记与约束见架构公约 §6.4）
- **转场重叠语义**：dissolve 与相邻片段全额重叠（扣 duration），fade 不重叠（各占相邻片段内 duration/2，总长不变）——渲染时长 ≠ `Video.duration` 求和值（样例工程实测 9.5s vs 10.5s，与 Kadr CompositionBuilder `overlap(during:)` 一致）；时长口径约束见架构公约 §3.3
- **预览 player 生命周期**：旧 player 的回收依赖 dealloc（时机不受控），`PlayerController.rebuild()` 不主动停旧实例会出现「界面无播放器却有声音」的孤儿播放；rebuild 的 await 期间可能又来一次 rebuild。生命周期约束见架构公约 §6.3
- **转场预览直通怪癖（iOS 26 模拟器实测）**：转场路径（双视频轨 composition）中素材分辨率恰等于 preset renderSize 时，显示管线把解码 buffer 直通 CA image queue，像素格式被拒（-11800 / 底层 -19230）→ `AVPlayerItemFailedToPlayToEndTime`，播到转场即停；identity transform 微扰无效（判定基于尺寸相等），`PreviewBridge.breakRenderSizeEquality` 给 renderSize 加 0.5pt 规避。注意 `AVPlayerItem.videoComposition` setter 是 copy 语义，改完要 mutableCopy 赋回。真机已验证无此问题（2026-10-12），微扰为模拟器保留；正式版发布前再移除或按模拟器条件编译（见 roadmap backlog；降级登记见架构公约 §6.4）

## 相册集成（kadr-photos）

- **resolver 要授权**：`PhotosClipResolver` 要求 readWrite 授权（.authorized/.limited），即使 PHPicker 本身免授权——导入前必须先 `PhotosBridge.requestReadAccess()`；App 需 `NSPhotoLibraryUsageDescription`
- **默认 preset 降帧率**：`AVAssetExportPresetHighestQuality` 会把高帧率视频压到 30fps。`PhotosBridge` 优先 passthrough（保 HDR/高帧率且秒级完成），失败回退重编码——改这段逻辑时保留这个顺序
