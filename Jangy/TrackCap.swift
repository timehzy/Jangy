import SwiftUI
import JangyCore

/// 轨道头：图标（注册表按 kind 给，未知 kind 回落通用符号——不 switch kind）+ 轨号 + 静音/隐藏开关。
/// 由 `TimelineView` 钉在视口左缘、随轨道行纵向移动；**无实色底**，靠阴影在任意素材上保持可读。
struct TrackCap: View {
    let track: PlanTrack
    let number: Int
    /// 是否主轨（链式基底）。主轨不可隐藏——隐藏会让成片没有主轨。
    let isPrimary: Bool
    let onToggleMute: () -> Void
    let onToggleHidden: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: TrackLaneRegistry.icon(for: track.kind))
            Text("\(number)").monospacedDigit()
            // 静音开关：v1 音频后置，`isMuted` 目前无播放效果（引擎未接音频）。
            // 仍保留开关——它是模型字段，剪辑 Agent 的 set_track_flags 也会用它。
            Button(action: onToggleMute) {
                Image(systemName: track.isMuted ? "speaker.slash.fill" : "speaker.wave.1")
            }
            .accessibilityLabel(track.isMuted ? "取消静音" : "静音")
            Button(action: onToggleHidden) {
                Image(systemName: track.isHidden ? "eye.slash.fill" : "eye")
            }
            .disabled(isPrimary)
            .accessibilityLabel(track.isHidden ? "显示轨道" : "隐藏轨道")
        }
        .font(.caption)
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
    }
}
