import Foundation

/// 把 MediaRef 解析为磁盘 URL。文件名相对 resolver 目录解析；
/// 绝对路径原样透传（CLI 喂任意素材、4K HDR 验证用）。
public struct AssetResolver: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func resolve(_ ref: MediaRef) -> URL {
        if ref.fileName.hasPrefix("/") {
            return URL(fileURLWithPath: ref.fileName)
        }
        return directory.appendingPathComponent(ref.fileName)
    }

    public func exists(_ ref: MediaRef) -> Bool {
        FileManager.default.fileExists(atPath: resolve(ref).path)
    }
}
