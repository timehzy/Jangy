import Foundation

/// 生成 PCM 静音 WAV —— Kadr 空音频轨规避方案（见 EngineBridge 注释）的配套工具。
///
/// 手写 WAV 头 + 全零采样，无第三方依赖；AVURLAsset 可直接读取。
/// 44.1kHz / 16-bit / 单声道 ≈ 88KB/s，POC 时长量级下文件体积可忽略。
enum SilentAudio {

    /// 在临时目录生成（或复用）至少覆盖 `seconds` 时长的静音 WAV，返回其 URL。
    /// 按时长缓存文件名，同一进程/多次导出只生成一次。
    static func url(covering seconds: TimeInterval) throws -> URL {
        let clamped = max(seconds, 0.1) // 空 data chunk 的 WAV 部分解析器不接受
        let ms = Int((clamped * 1000).rounded(.up))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadrpoc-silence-\(ms)ms.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try wavData(milliseconds: ms).write(to: url, options: .atomic)
        return url
    }

    /// RIFF/WAVE：PCM (format 1)、单声道、16-bit、44.1kHz，采样值全 0。
    static func wavData(milliseconds: Int) -> Data {
        let sampleRate: UInt32 = 44100
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        // 先除后转：UInt32(ms) * 44100 在 > ~97s 时溢出
        let frames = UInt32(UInt64(milliseconds) * UInt64(sampleRate) / 1000)
        let dataSize = frames * UInt32(channels) * UInt32(bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))
        func u32(_ v: UInt32) { var v = v.littleEndian; data.append(Data(bytes: &v, count: 4)) }
        func u16(_ v: UInt16) { var v = v.littleEndian; data.append(Data(bytes: &v, count: 2)) }

        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        u32(36 + dataSize)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        u32(16)                 // fmt chunk size
        u16(1)                  // PCM
        u16(channels)
        u32(sampleRate)
        u32(byteRate)
        u16(blockAlign)
        u16(bitsPerSample)
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        u32(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}
