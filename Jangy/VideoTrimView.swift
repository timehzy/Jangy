import AVFoundation
import SwiftUI

/// 视频 trim 条：样式参照 iOS 相册视频裁剪——胶片条缩略图 + 黄色选中边框 + 首尾把手。
/// 拖把手调区间，最小选区 0.5s。
struct VideoTrimView: View {
    let url: URL
    let duration: TimeInterval
    @Binding var range: ClosedRange<TimeInterval>

    @State private var thumbnails: [UIImage] = []
    private let minLength = 0.5
    private let handleWidth: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                filmstrip(width: width)
                dimming(width: width)
                selectionFrame(width: width)
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .frame(height: 44)
        .task { await loadThumbnails() }
    }

    /// 胶片条：均匀抽帧铺满
    private func filmstrip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(thumbnails.indices, id: \.self) { index in
                Image(uiImage: thumbnails[index])
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: width / CGFloat(max(thumbnails.count, 1)), height: 44)
                    .clipped()
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(.secondarySystemFill)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// 选区外暗化
    private func dimming(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(.black.opacity(0.55)).frame(width: xOffset(of: range.lowerBound, width: width))
            Spacer()
            Rectangle().fill(.black.opacity(0.55)).frame(width: width - xOffset(of: range.upperBound, width: width))
        }
        .allowsHitTesting(false)
    }

    /// 黄色选中框 + 把手
    private func selectionFrame(width: CGFloat) -> some View {
        let left = xOffset(of: range.lowerBound, width: width)
        let right = xOffset(of: range.upperBound, width: width)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.yellow, lineWidth: 3)
                .frame(width: max(right - left, handleWidth * 2), height: 44)
                .offset(x: left)
                .allowsHitTesting(false)
            // 左把手
            handle
                .offset(x: left)
                .gesture(DragGesture().onChanged { value in
                    let seconds = clamp(seconds(at: value.location.x, width: width),
                                        min: 0, max: range.upperBound - minLength)
                    range = seconds...range.upperBound
                })
            // 右把手
            handle
                .offset(x: max(right - handleWidth, left + handleWidth))
                .gesture(DragGesture().onChanged { value in
                    let seconds = clamp(seconds(at: value.location.x + handleWidth, width: width),
                                        min: range.lowerBound + minLength, max: duration)
                    range = range.lowerBound...seconds
                })
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.yellow)
            .frame(width: handleWidth, height: 44)
            .overlay { Image(systemName: "chevron.compact.left").font(.caption2).foregroundStyle(.black.opacity(0.6)) }
            .contentShape(Rectangle())
    }

    private func xOffset(of seconds: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(seconds / duration) * width
    }

    private func seconds(at x: CGFloat, width: CGFloat) -> TimeInterval {
        TimeInterval(x / width) * duration
    }

    private func clamp(_ v: TimeInterval, min: TimeInterval, max: TimeInterval) -> TimeInterval {
        Swift.max(min, Swift.min(max, v))
    }

    /// 抽 8 帧铺胶片条
    private func loadThumbnails() async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 120, height: 88)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        var images: [UIImage] = []
        for i in 0..<8 {
            let time = CMTime(seconds: duration * Double(i) / 8.0, preferredTimescale: 600)
            if let cgImage = try? await generator.image(at: time).image {
                images.append(UIImage(cgImage: cgImage))
            }
        }
        thumbnails = images
    }
}
