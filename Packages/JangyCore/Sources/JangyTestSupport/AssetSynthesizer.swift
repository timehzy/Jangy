import AVFoundation
import CoreGraphics
import ImageIO
import JangyCore
import UniformTypeIdentifiers

/// 用 AVAssetWriter 合成确定性测试素材：三段 4 秒纯色 720p 视频 + 一份 SRT + 一张纯色 PNG 测试图。
/// 无二进制资产进 git，CI/真机/CLI 随时可再生成。幂等：已存在则跳过。
/// 仅测试与 CLI 使用（JangyTestSupport），不进 App 产物。
public enum AssetSynthesizer {

    public static let clipFileNames = ["clip1.mp4", "clip2.mp4", "clip3.mp4"]
    public static let srtFileName = "sample.srt"
    public static let imageFileName = "still.png"

    /// SRT 时间轴按 sample 工程的合成时间轴编写（clip1 3s@1x + 转场 0.5s + clip2 3s@0.5x=6s + clip3 2s@2x=1s）。
    static let srtContent = """
    1
    00:00:00,000 --> 00:00:02,500
    第一段：开场

    2
    00:00:03,000 --> 00:00:07,500
    第二段：慢动作

    3
    00:00:08,000 --> 00:00:09,000
    第三段：收尾

    """

    @discardableResult
    public static func synthesize(into directory: URL) throws -> AssetResolver {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let colors: [CGColor] = [
            CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1),
            CGColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1),
            CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1),
        ]
        for (i, name) in clipFileNames.enumerated() {
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try writeSolidColorVideo(to: url, color: colors[i], seconds: 4)
            }
        }
        let srtURL = directory.appendingPathComponent(srtFileName)
        if !FileManager.default.fileExists(atPath: srtURL.path) {
            try srtContent.write(to: srtURL, atomically: true, encoding: .utf8)
        }
        let imageURL = directory.appendingPathComponent(imageFileName)
        if !FileManager.default.fileExists(atPath: imageURL.path) {
            try writeSolidColorImage(to: imageURL, color: CGColor(red: 0.95, green: 0.85, blue: 0.1, alpha: 1),
                                     width: 640, height: 360)
        }
        return AssetResolver(directory: directory)
    }

    /// 合成纯色 PNG 测试图（16:9，非 preset 画幅——用于验证 letterbox 无变形）。
    static func writeSolidColorImage(to url: URL, color: CGColor, width: Int, height: Int) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "AssetSynthesizer", code: 2, userInfo: [NSLocalizedDescriptionKey: "图片合成失败"])
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "AssetSynthesizer", code: 3, userInfo: [NSLocalizedDescriptionKey: "图片写入失败"])
        }
    }

    /// 合成单个纯色视频。internal 供测试用（@testable）：回归测试需要非默认尺寸素材
    /// （如 1080x1920 == preset renderSize，触发转场预览的 identity-transform 路径）。
    static func writeSolidColorVideo(to url: URL, color: CGColor, seconds: Double,
                                     width: Int = 1280, height: Int = 720) throws {
        let fps: Int32 = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int(seconds * Double(fps))
        for frame in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error! }  // 写入中途失败时退出，避免空转
                Thread.sleep(forTimeInterval: 0.005)
            }
            let buffer = try makePixelBuffer(pool: adaptor.pixelBufferPool!, width: width, height: height, color: color)
            let time = CMTime(value: CMTimeValue(frame), timescale: fps)
            guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error! }
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status != .failed else { throw writer.error! }
    }

    private static func makePixelBuffer(pool: CVPixelBufferPool, width: Int, height: Int, color: CGColor) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw NSError(domain: "AssetSynthesizer", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法分配像素缓冲"]) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
