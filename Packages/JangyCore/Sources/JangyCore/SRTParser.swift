import Foundation

/// 极简 SRT 解析（纯 Swift，不依赖 KadrCaptions）。
/// 用途单一：v3 → v4 迁移时把整片 SRT 展开成 cue 元素。
/// 宽容策略——坏块跳过而不是抛错，保证迁移不会因一行脏数据整体失败。
///
/// 与旧路径（`Kadr.Caption.load(srt:)`）保持一致：**cue 文本原样保留，不做 markup 处理**。
/// `<i>斜体</i>`、`{\an8}` 这类标签不会被剥离，会原样进 `Cue.text`——旧解析器也是这么做的，
/// 迁移后才能保持渲染结果不变。UTF-8 BOM 会被剥离（与旧路径一致）。
public enum SRTParser {

    public struct Cue: Equatable, Sendable {
        public let text: String
        public let start: TimeInterval
        public let duration: TimeInterval
    }

    /// 解析结果。宽容策略下坏块静默跳过，但**跳过多少要能被调用方看见**——
    /// 迁移时若 SRT 有大半解析不出来，用户必须能收到提示，而不是字幕静默变少。
    public struct ParseResult: Equatable, Sendable {
        public let cues: [Cue]
        /// 非空但没能产出 cue 的块数。纯空块（多空行 / 末尾换行产生的）不计入。
        public let skippedBlocks: Int
    }

    public static func parse(_ content: String) -> ParseResult {
        // 旧路径（KadrCaptions 的 SRT 加载器）会剥 UTF-8 BOM，这里保持一致：
        // 不剥的话，「BOM + 无编号行」的 SRT 会让首条 cue 的时间戳解析失败而整条丢失。
        let normalized = content
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")

        let cues = blocks.compactMap(parseBlock)
        let nonEmptyBlocks = blocks.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        return ParseResult(cues: cues, skippedBlocks: nonEmptyBlocks - cues.count)
    }

    private static func parseBlock(_ block: String) -> Cue? {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let timelineIndex = lines.firstIndex(where: { $0.contains("-->") }),
              let (start, end) = parseTimeline(lines[timelineIndex]) else { return nil }

        let text = lines[(timelineIndex + 1)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, end > start else { return nil }

        return Cue(text: text, start: start, duration: end - start)
    }

    /// "00:00:01,000 --> 00:00:02,500"，毫秒分隔符逗号与点号都接受。
    private static func parseTimeline(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let start = parseTimestamp(firstToken(of: parts[0])),
              let end = parseTimestamp(firstToken(of: parts[1])) else { return nil }
        return (start, end)
    }

    /// 时间轴两侧可能带额外内容——YouTube / ASR 工具常在时间戳后追加
    /// `X1:.. X2:.. Y1:.. Y2:..` 定位坐标。只取第一个空白分隔的 token，
    /// 否则整条 cue 会因为段数判据失败而被静默丢弃。
    private static func firstToken(of raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
    }

    private static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let text = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = text.components(separatedBy: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}
