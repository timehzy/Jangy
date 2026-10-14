import CryptoKit
import Foundation

/// 文件内容哈希：素材库去重（同一内容只存一份）的依据。
/// 流式读取，4K 大文件不全量进内存。
public enum AssetHasher {
    public static func sha256(of url: URL) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: chunkSize)
            if read < 0 { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
            if read == 0 { break }
            hasher.update(data: Data(bytes: buffer, count: read))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
