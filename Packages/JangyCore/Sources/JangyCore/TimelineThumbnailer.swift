import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// 缩略图档位：离散高度（点），不随缩放连续变（避免缓存爆炸）。
public enum ThumbnailLevel: Int, CaseIterable, Sendable {
    case small = 80
    case medium = 160
    case large = 320

    /// 由当前 px-per-sec 选一档（供 L0 在缩放稳定后选档）。
    public static func level(forPointsPerSecond pps: CGFloat) -> ThumbnailLevel {
        switch pps {
        case ..<24: return .small
        case ..<80: return .medium
        default: return .large
        }
    }
}

/// 时间桶（秒）：同一桶内的抽帧请求复用一帧，避免相邻帧各抽一次。
private let thumbnailBucket: TimeInterval = 0.5

/// 时间线缩略图：**从源素材抽帧**（不是从 composition），带缓存。
/// 缓存键 = assetID + 档位 + 时间桶；同一素材在时间线上多处出现时复用。
/// 也提供素材库用的单帧缩略图（原 L0 `ThumbnailLoader` 收口到这里——它 import AVFoundation，
/// 违反公约 §1，L0 不该有）。
///
/// `actor`：缓存与生成串行化，避免 Swift 6 严格并发下的静态可变状态告警。
/// 返回 `CGImage` 而非 `UIImage`——JangyCore 在 macOS 上参与 `swift test`，不能 import UIKit。
public actor TimelineThumbnailer {
    private let resolver: AssetResolver
    private let cache = NSCache<NSString, CGImageBox>()

    public init(resolver: AssetResolver) {
        self.resolver = resolver
    }

    /// 为某素材元素在给定**输出偏移**处抽帧。`.still` / 越界 → nil。
    /// - Parameter outputOffsets: 元素内输出偏移（秒，相对元素起点）。
    public func frames(asset: AssetItem, clip: PlanClip, level: ThumbnailLevel,
                       outputOffsets: [TimeInterval]) async -> [CGImage?] {
        var result = [CGImage?](repeating: nil, count: outputOffsets.count)
        // 先查缓存，未命中的收集为 (槽位, 源时间)；生成器一次性复用抽这些点。
        var misses: [(slot: Int, time: TimeInterval, key: NSString)] = []
        for (slot, offset) in outputOffsets.enumerated() {
            guard let sourceTime = clip.sourceTime(forOutputOffset: offset) else { continue }
            let key = cacheKey(assetID: asset.id, level: level, time: sourceTime)
            if let hit = cache.object(forKey: key) { result[slot] = hit.image; continue }
            misses.append((slot, sourceTime, key))
        }
        guard !misses.isEmpty else { return result }
        let url = resolver.resolve(asset)
        let images = await Self.generate(url: url, level: level, times: misses.map(\.time))
        for (miss, image) in zip(misses, images) {
            if let image { cache.setObject(CGImageBox(image), forKey: miss.key) }
            result[miss.slot] = image
        }
        return result
    }

    /// 素材库用的单帧缩略图（视频首帧 / 图片降采样）。
    public func thumbnail(for asset: AssetItem, maxPixel: Int) async -> CGImage? {
        let url = resolver.resolve(asset)
        switch asset.kind {
        case .video:
            return await Self.firstFrame(url: url, maxPixel: maxPixel)
        case .image:
            return ImageDownsampler.downsample(url: url, maxPixel: maxPixel)
        default:
            return nil
        }
    }

    // MARK: - 抽帧（nonisolated：AVAssetImageGenerator 非 Sendable，不进 actor 隔离域）

    /// 用同一生成器对多个源时间抽帧（时间容差 = 桶宽，纯色素材每桶稳定命中）。
    private nonisolated static func generate(url: URL, level: ThumbnailLevel,
                                             times: [TimeInterval]) async -> [CGImage?] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: CGFloat(level.rawValue) * 2, height: CGFloat(level.rawValue))
        generator.requestedTimeToleranceBefore = CMTime(seconds: thumbnailBucket, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: thumbnailBucket, preferredTimescale: 600)
        var images: [CGImage?] = []
        for time in times {
            images.append(try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image)
        }
        return images
    }

    private nonisolated static func firstFrame(url: URL, maxPixel: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        return try? await generator.image(at: .zero).image
    }

    private func cacheKey(assetID: UUID, level: ThumbnailLevel, time: TimeInterval) -> NSString {
        let bucketIndex = Int((time / thumbnailBucket).rounded())
        return "\(assetID.uuidString)-\(level.rawValue)-\(bucketIndex)" as NSString
    }

    /// CGImage 不是 class，NSCache 需要 class 值——薄包装。
    private final class CGImageBox { let image: CGImage; init(_ image: CGImage) { self.image = image } }
}
