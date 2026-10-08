import AVFoundation
import CoreGraphics

/// 用 AVAssetWriter 合成确定性测试素材：三段 4 秒纯色 720p 视频 + 一份 SRT。
/// 无二进制资产进 git，CI/真机/CLI 随时可再生成。幂等：已存在则跳过。
public enum AssetSynthesizer {

    public static let clipFileNames = ["clip1.mp4", "clip2.mp4", "clip3.mp4"]
    public static let srtFileName = "sample.srt"

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
        return AssetResolver(directory: directory)
    }

    private static func writeSolidColorVideo(to url: URL, color: CGColor, seconds: Double) throws {
        let width = 1280, height = 720, fps: Int32 = 30
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
