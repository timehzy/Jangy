import AVFoundation
import CoreGraphics
import Foundation

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
/// `actor`：缓存（NSCache，线程安全）跨调用共享且命中判定串行化；
/// 抽帧本身在 `nonisolated` 辅助里跑，多次并发调用可并行解码（每次调用内复用同一个 generator，
/// 上限 = 并发调用数）。返回 `CGImage` 而非 `UIImage`——JangyCore 在 macOS 上参与 `swift test`，不能 import UIKit。
public actor TimelineThumbnailer {
    private let resolver: AssetResolver
    private let cache = NSCache<NSString, CGImageBox>()

    public init(resolver: AssetResolver) {
        self.resolver = resolver
    }

    /// 为某素材元素在给定**输出偏移**处抽帧。`.still`（无源区间）→ nil。
    /// - Parameter outputOffsets: 元素内输出偏移（秒，相对元素起点）。
    public func frames(asset: AssetItem, clip: PlanClip, level: ThumbnailLevel,
                       outputOffsets: [TimeInterval]) async -> [CGImage?] {
        var result = [CGImage?](repeating: nil, count: outputOffsets.count)
        // 先查缓存；未命中的按「键 → 槽位」归并（同桶的多个偏移只解码一次），生成器一次性复用抽这些点。
        var misses: [NSString: (time: TimeInterval, slots: [Int])] = [:]
        for (slot, offset) in outputOffsets.enumerated() {
            guard let sourceTime = clip.sourceTime(forOutputOffset: offset) else { continue }
            let key = cacheKey(assetID: asset.id, level: level, time: sourceTime)
            if let hit = cache.object(forKey: key) { result[slot] = hit.image; continue }
            misses[key, default: (sourceTime, [])].slots.append(slot)
        }
        guard !misses.isEmpty else { return result }
        let url = resolver.resolve(asset)
        let keys = Array(misses.keys)
        let images = await Self.generate(url: url, level: level, times: keys.map { misses[$0]!.time })
        for (key, image) in zip(keys, images) {
            if let image { cache.setObject(CGImageBox(image), forKey: key) }
            for slot in misses[key]!.slots { result[slot] = image }
        }
        return result
    }

    /// 素材库用的单帧缩略图（视频首帧 / 图片降采样）。按 assetID + maxPixel 缓存
    /// （网格滚动时 cell `.task` 会重跑，命中缓存即不重新解码）。
    public func thumbnail(for asset: AssetItem, maxPixel: Int) async -> CGImage? {
        let key = "\(asset.id.uuidString)-thumb-\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit.image }
        let url = resolver.resolve(asset)
        let image: CGImage?
        switch asset.kind {
        case .video: image = await Self.firstFrame(url: url, maxPixel: maxPixel)
        case .image: image = ImageDownsampler.downsample(url: url, maxPixel: maxPixel)
        default: image = nil
        }
        if let image { cache.setObject(CGImageBox(image), forKey: key) }
        return image
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
