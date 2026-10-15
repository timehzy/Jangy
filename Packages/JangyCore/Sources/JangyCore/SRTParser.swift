import Foundation

/// 极简 SRT 解析（纯 Swift，不依赖 KadrCaptions）。
/// 用途单一：v3 → v4 迁移时把整片 SRT 展开成 cue 元素。
/// 宽容策略——坏块跳过而不是抛错，保证迁移不会因一行脏数据整体失败。
public enum SRTParser {

    public struct Cue: Equatable, Sendable {
        public let text: String
        public let start: TimeInterval
        public let duration: TimeInterval
    }

    public static func parse(_ content: String) -> [Cue] {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
            .compactMap(parseBlock)
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
              let start = parseTimestamp(parts[0]),
              let end = parseTimestamp(parts[1]) else { return nil }
        return (start, end)
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
