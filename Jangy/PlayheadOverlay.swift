import SwiftUI

/// 播放头：固定钉在视口水平中央（**不做任何偏移**），由外层居中放置。
/// 2pt 竖线贯穿全高 + 顶部时间气泡。
struct PlayheadOverlay: View {
    let time: TimeInterval

    var body: some View {
        VStack(spacing: 2) {
            Text(Self.format(time))
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
        }
    }

    /// `0:03.4` 形式（分:秒.十分位）。
    static func format(_ t: TimeInterval) -> String {
        let clamped = max(0, t)
        let minutes = Int(clamped) / 60
        let seconds = clamped - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, seconds)
    }
}
