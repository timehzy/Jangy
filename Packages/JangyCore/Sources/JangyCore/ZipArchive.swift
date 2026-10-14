import Foundation

/// 最小 ZIP 读写：工程包容器。写 = store（不压缩——媒体文件本身已压缩，压缩无收益）；
/// 读 = 仅支持 store 条目（本 App 自产包）。防 zip slip（拒绝含 ".." 的条目名）。
public enum ZipArchive {

    public enum ZipError: Error, Equatable, CustomStringConvertible {
        case unsupportedCompression(String)
        case malformedArchive
        case unsafeEntryName(String)
        case crcMismatch(String)

        public var description: String {
            switch self {
            case .unsupportedCompression(let name):
                return "不支持的压缩条目（仅支持 store）: \(name)"
            case .malformedArchive:
                return "zip 文件损坏或格式不符"
            case .unsafeEntryName(let name):
                return "zip 包含不安全的路径条目: \(name)"
            case .crcMismatch(let name):
                return "zip 条目校验失败（数据损坏）: \(name)"
            }
        }
    }

    // MARK: - CRC32

    private static let crcTable: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB88320 : c >> 1 }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - 写

    /// 把目录内全部文件（递归）打进 zip。条目名用相对路径（/ 分隔）。
    public static func zip(contentsOf directory: URL, to zipURL: URL) throws {
        let fm = FileManager.default
        // 用 atPath 枚举：条目名直接是相对路径，避开 /var↔/private/var（firmlink）
        // 导致 URL 路径前缀不一致的坑
        guard let enumerator = fm.enumerator(atPath: directory.path) else { return }

        var entries: [(name: String, data: Data, crc: UInt32, offset: UInt32)] = []
        var out = Data()
        for case let name as String in enumerator {
            let fileURL = directory.appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fileURL.path, isDirectory: &isDir)
            guard !isDir.boolValue else { continue }
            let data = try Data(contentsOf: fileURL)
            let crc = crc32(data)
            entries.append((name, data, crc, UInt32(out.count)))

            out.appendLE(UInt32(0x04034b50))  // local header sig
            out.appendLE(UInt16(20))          // version needed
            out.appendLE(UInt16(0))           // flags
            out.appendLE(UInt16(0))           // method: store
            out.appendLE(UInt16(0)); out.appendLE(UInt16(0))  // mod time/date（不记录）
            out.appendLE(crc)
            out.appendLE(UInt32(data.count)); out.appendLE(UInt32(data.count))
            out.appendLE(UInt16(name.utf8.count)); out.appendLE(UInt16(0))
            out.append(contentsOf: name.utf8)
            out.append(data)
        }

        let centralOffset = UInt32(out.count)
        for entry in entries {
            out.appendLE(UInt32(0x02014b50))  // central sig
            out.appendLE(UInt16(20)); out.appendLE(UInt16(20))
            out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
            out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
            out.appendLE(entry.crc)
            out.appendLE(UInt32(entry.data.count)); out.appendLE(UInt32(entry.data.count))
            out.appendLE(UInt16(entry.name.utf8.count))
            out.appendLE(UInt16(0)); out.appendLE(UInt16(0))  // comment/extra
            out.appendLE(UInt16(0)); out.appendLE(UInt16(0))  // disk/internal attrs
            out.appendLE(UInt32(0))                            // external attrs
            out.appendLE(entry.offset)
            out.append(contentsOf: entry.name.utf8)
        }

        let centralSize = UInt32(out.count - Int(centralOffset))  // 先算长度再写 EOCD
        out.appendLE(UInt32(0x06054b50))  // EOCD sig
        out.appendLE(UInt16(0)); out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count)); out.appendLE(UInt16(entries.count))
        out.appendLE(centralSize); out.appendLE(centralOffset)
        out.appendLE(UInt16(0))
        try out.write(to: zipURL, options: .atomic)
    }

    // MARK: - 读

    /// 解包到目录（自动创建）。只支持 store 条目；CRC 校验；拒绝 ".." 路径。
    /// 所有解析读取都带边界检查：坏包抛 malformedArchive，绝不越界崩溃。
    public static func unzip(_ zipURL: URL, into directory: URL) throws {
        let data = try Data(contentsOf: zipURL)
        // EOCD 本身 22 字节，文件比它还小必然不是 zip
        guard data.count >= 22 else { throw ZipError.malformedArchive }
        // 从尾部找 EOCD（无 comment 的自产包直接在末尾，宽容起见扫最后 64KB）
        let searchStart = max(0, data.count - 65536 - 22)
        var eocdOffset: Int?
        var i = data.count - 22
        while i >= searchStart {
            if data[i] == 0x50 && data[i + 1] == 0x4B && data[i + 2] == 0x05 && data[i + 3] == 0x06 {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard let eocd = eocdOffset else { throw ZipError.malformedArchive }

        let entryCount = Int(try readUInt16(data, at: eocd + 10))
        var offset = Int(try readUInt32(data, at: eocd + 16))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for _ in 0..<entryCount {
            guard try readUInt32(data, at: offset) == 0x02014b50 else { throw ZipError.malformedArchive }
            let method = try readUInt16(data, at: offset + 10)
            let crc = try readUInt32(data, at: offset + 16)
            let size = Int(try readUInt32(data, at: offset + 20))
            let nameLen = Int(try readUInt16(data, at: offset + 28))
            let extraLen = Int(try readUInt16(data, at: offset + 30))
            let commentLen = Int(try readUInt16(data, at: offset + 32))
            let localOffset = Int(try readUInt32(data, at: offset + 42))
            guard offset + 46 + nameLen <= data.count else { throw ZipError.malformedArchive }
            let name = String(decoding: data[(offset + 46)..<(offset + 46 + nameLen)], as: UTF8.self)

            guard !name.contains("..") && !name.hasPrefix("/") else {
                throw ZipError.unsafeEntryName(name)
            }
            guard method == 0 else { throw ZipError.unsupportedCompression(name) }

            // local header：跳过其可变长 name/extra 取数据
            guard try readUInt32(data, at: localOffset) == 0x04034b50 else { throw ZipError.malformedArchive }
            let localNameLen = Int(try readUInt16(data, at: localOffset + 26))
            let localExtraLen = Int(try readUInt16(data, at: localOffset + 28))
            let dataStart = localOffset + 30 + localNameLen + localExtraLen
            guard dataStart >= 0, size <= data.count - dataStart else { throw ZipError.malformedArchive }
            let payload = Data(data[dataStart..<(dataStart + size)])
            guard crc32(payload) == crc else { throw ZipError.crcMismatch(name) }

            let dest = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try payload.write(to: dest)

            offset += 46 + nameLen + extraLen + commentLen
        }
    }

    /// 越界一律抛 malformedArchive（坏包），不做部分读取。
    private static func readUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { throw ZipError.malformedArchive }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    /// 越界一律抛 malformedArchive（坏包），不做部分读取。
    private static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw ZipError.malformedArchive }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: MemoryLayout<T>.size))
    }
}
