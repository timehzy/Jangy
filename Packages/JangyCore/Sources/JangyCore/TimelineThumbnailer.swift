import AVFoundation
import CoreGraphics
import Foundation

/// 时间线缩略图：**从源素材抽帧**（不是从 composition），带缓存。
/// 缓存键 = assetID + 抽帧像素高 + 时间桶；同一素材在时间线上多处出现时复用。
/// 也提供素材库用的单帧缩略图（原 L0 `ThumbnailLoader` 收口到这里——它 import AVFoundation，
/// 违反公约 §1，L0 不该有）。两条路径共用同一套键（素材库那条即时间桶 0）。
///
/// `actor`：缓存（NSCache，线程安全）跨调用共享且命中判定串行化；
/// 抽帧本身在 `nonisolated` 辅助里跑，多次并发调用可并行解码（每次调用内复用同一个 generator，
/// 上限 = 并发调用数）。返回 `CGImage` 而非 `UIImage`——JangyCore 在 macOS 上参与 `swift test`，不能 import UIKit。
public actor TimelineThumbnailer {
    /// 抽帧**时间桶**（秒）：同一桶内复用一帧，也就是缓存键的粒度。
    /// **它决定「相邻格会不会显示同一帧」**——必须小于相邻格的**源时间**间距
    /// （`TimelineFilmstrip.minCellWidth / TimelineViewportState.maxPointsPerSecond × speedRange.lowerBound`
    /// ≈ 0.0167s，`TimelineThumbnailerTests` 钉住这个不变式），否则高倍缩放 × 慢放下相邻格会重复。
    public static let frameBucket: TimeInterval = 0.01

    /// 抽帧**时间容差**（秒）：与桶粒度无关——它只决定「解码可以落在请求时间附近多远」，
    /// 影响的是解码代价（放宽即可复用邻近样本），不决定两格是否同一帧。
    private static let frameTolerance: TimeInterval = 0.1

    private let resolver: AssetResolver
    private let cache = NSCache<NSString, CGImageBox>()

    public init(resolver: AssetResolver) {
        self.resolver = resolver
        // 桶细 → 条目多（一帧一条），给缓存一个内存上限，靠 cost 淘汰而不是无界增长。
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    /// 为某素材元素在给定**输出偏移**处抽帧。
    /// 图片（`.still`，无源区间）任一输出偏移看到的都是同一张图——降采样一次、所有槽位共用，
    /// 于是 L0 不必为图片单开一条分支。
    /// - Parameter maxPixel: 抽帧像素高（宽按素材比例、给足余量）。调用方须把它**量化到固定档**
    ///   ——连续值会把缓存碎成大量条目、命中率崩。
    /// - Parameter outputOffsets: 元素内输出偏移（秒，相对元素起点）。
    public func frames(asset: AssetItem, clip: PlanClip, maxPixel: Int,
                       outputOffsets: [TimeInterval]) async -> [CGImage?] {
        if case .still = clip.source {
            let image = await stillImage(asset: asset, maxPixel: maxPixel)
            return [CGImage?](repeating: image, count: outputOffsets.count)
        }
        var result = [CGImage?](repeating: nil, count: outputOffsets.count)
        // 先查缓存；未命中的按「键 → 槽位」归并（同桶的多个偏移只解码一次），生成器一次性复用抽这些点。
        var misses: [NSString: (time: TimeInterval, slots: [Int])] = [:]
        for (slot, offset) in outputOffsets.enumerated() {
            guard let sourceTime = clip.sourceTime(forOutputOffset: offset) else { continue }
            let key = cacheKey(assetID: asset.id, maxPixel: maxPixel, time: sourceTime)
            if let hit = cache.object(forKey: key) { result[slot] = hit.image; continue }
            misses[key, default: (sourceTime, [])].slots.append(slot)
        }
        guard !misses.isEmpty else { return result }
        let url = resolver.resolve(asset)
        let keys = Array(misses.keys)
        let images = await Self.generate(url: url, maxPixel: maxPixel, times: keys.map { misses[$0]!.time })
        for (key, image) in zip(keys, images) {
            if let image { cache.setObject(CGImageBox(image), forKey: key, cost: image.bytes) }
            for slot in misses[key]!.slots { result[slot] = image }
        }
        return result
    }

    /// **只查缓存、不抽帧**（不命中返回 nil）。
    /// 给「裁剪窗回到刚看过的区域」用：元素的呈现视图被窗口移出时会连 `@State` 一起销毁，
    /// 重建时若等 debounce 才取帧，整条就会先空白一下再出现。先铺缓存里已有的帧，空白期就只剩真要解码的那些。
    public func cachedFrames(asset: AssetItem, clip: PlanClip, maxPixel: Int,
                             outputOffsets: [TimeInterval]) -> [CGImage?] {
        outputOffsets.map { offset in
            // 图片没有源区间，与 `frames` 的口径一致：统一用源时间 0。
            let time = clip.sourceTime(forOutputOffset: offset) ?? 0
            return cache.object(forKey: cacheKey(assetID: asset.id, maxPixel: maxPixel, time: time))?.image
        }
    }

    /// 素材库用的单帧缩略图（视频首帧 / 图片降采样）。按 assetID + maxPixel 缓存
    /// （网格滚动时 cell `.task` 会重跑，命中缓存即不重新解码）。
    /// 视频走与 `frames` **同一条抽帧路径**（故键同源：素材库那条就是时间桶 0），
    /// 同一素材既进素材库又上时间线时只解码一次。
    public func thumbnail(for asset: AssetItem, maxPixel: Int) async -> CGImage? {
        switch asset.kind {
        case .video:
            let key = cacheKey(assetID: asset.id, maxPixel: maxPixel, time: 0)
            if let hit = cache.object(forKey: key) { return hit.image }
            let image = await Self.generate(url: resolver.resolve(asset), maxPixel: maxPixel, times: [0]).first ?? nil
            if let image { cache.setObject(CGImageBox(image), forKey: key, cost: image.bytes) }
            return image
        case .image:
            return await stillImage(asset: asset, maxPixel: maxPixel)
        default:
            return nil
        }
    }

    /// 图片的降采样（与时间线抽帧共用一条缓存：键的时间桶为 0）。
    /// `maxPixel` 按**高**理解（与视频帧一致）；ImageIO 的 `ThumbnailMaxPixelSize` 是**最长边**，
    /// 故按素材宽高比折算——否则宽图会被降得比格还小、放大发虚。
    private func stillImage(asset: AssetItem, maxPixel: Int) async -> CGImage? {
        let key = cacheKey(assetID: asset.id, maxPixel: maxPixel, time: 0)
        if let hit = cache.object(forKey: key) { return hit.image }
        let image = ImageDownsampler.downsample(url: resolver.resolve(asset),
                                                maxPixel: Self.longestSide(for: asset, targetHeight: maxPixel))
        if let image { cache.setObject(CGImageBox(image), forKey: key, cost: image.bytes) }
        return image
    }

    /// 目标高 → ImageIO 的最长边。宽高比未知（探测失败）时按正方形处理（最长边 = 高）。
    /// 上限与视频路径同口径（`generate` 的宽上限 = 4 倍高），挡住超宽全景图把缩略图撑到几 MB。
    private static func longestSide(for asset: AssetItem, targetHeight: Int) -> Int {
        let cap = targetHeight * 4
        guard let w = asset.pixelWidth, let h = asset.pixelHeight, w > 0, h > 0 else { return targetHeight }
        let side = Int((Double(targetHeight) * Double(max(w, h)) / Double(h)).rounded())
        return min(max(1, side), cap)
    }

    // MARK: - 抽帧（nonisolated：AVAssetImageGenerator 非 Sendable，不进 actor 隔离域）

    /// 用同一生成器对多个源时间抽帧。
    private nonisolated static func generate(url: URL, maxPixel: Int,
                                             times: [TimeInterval]) async -> [CGImage?] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        // 只按**高**定档：宽给足余量，超宽画幅（21:9）也不会被压。
        generator.maximumSize = CGSize(width: CGFloat(maxPixel) * 4, height: CGFloat(maxPixel))
        generator.requestedTimeToleranceBefore = CMTime(seconds: frameTolerance, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: frameTolerance, preferredTimescale: 600)
        var images: [CGImage?] = []
        for time in times {
            images.append(try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image)
        }
        return images
    }

    /// 缓存键：assetID + 像素高 + 时间桶。时间桶 0 = 素材库的单帧缩略图。
    private func cacheKey(assetID: UUID, maxPixel: Int, time: TimeInterval) -> NSString {
        let bucketIndex = Int((time / Self.frameBucket).rounded())
        return "\(assetID.uuidString)-\(maxPixel)-\(bucketIndex)" as NSString
    }

    /// CGImage 不是 class，NSCache 需要 class 值——薄包装。
    private final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
}

private extension CGImage {
    /// 缓存代价（字节）：用来给 NSCache 设内存上限。
    var bytes: Int { height * bytesPerRow }
}
