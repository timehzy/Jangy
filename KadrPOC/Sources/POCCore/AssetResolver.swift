import Foundation

/// 把素材条目的 fileName 解析为磁盘 URL。文件名相对 resolver 目录解析；
/// 绝对路径原样透传（CLI 喂任意素材、4K HDR 验证用）。
/// clip/字幕到 fileName 的映射由 EditPlan.assets 登记表负责（见 EditPlan.asset(withID:)）。
public struct AssetResolver: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func resolve(_ asset: AssetItem) -> URL {
        resolve(fileName: asset.fileName)
    }

    public func resolve(fileName: String) -> URL {
        if fileName.hasPrefix("/") {
            return URL(fileURLWithPath: fileName)
        }
        return directory.appendingPathComponent(fileName)
    }

    public func exists(_ asset: AssetItem) -> Bool {
        FileManager.default.fileExists(atPath: resolve(asset).path)
    }
}
