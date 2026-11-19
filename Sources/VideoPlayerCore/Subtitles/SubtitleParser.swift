import Foundation

public struct SubtitleCue: Equatable, Sendable, Codable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// 把 SRT / WebVTT / ASS 字幕解析成帶時間軸的文字
public enum SubtitleParser {
    public static func parse(contentsOf url: URL) -> [SubtitleCue] {
        guard let text = TextEncodingDetector.decode(contentsOf: url) else { return [] }
        return parse(text, format: url.pathExtension.lowercased())
    }

    public static func parse(_ text: String, format: String) -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        switch format {
        case "ass", "ssa": return parseASS(normalized)
        default: return parseSRTLike(normalized)
        }
    }

    /// SRT 和 WebVTT 的結構相同：一行時間軸，接著若干行文字，空行分隔
    static func parseSRTLike(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = timestamp(parts[0]),
                  let end = timestamp(parts[1].trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first.map(String.init) ?? "") else { continue }
            let body = lines[(timeIndex + 1)...].map(stripTags).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: body)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func parseASS(_ text: String) -> [SubtitleCue] {
        var format: [String] = []
        var cues: [SubtitleCue] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Format:"), format.isEmpty || !format.contains("text") {
                format = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard line.hasPrefix("Dialogue:") else { continue }
            let fields = format.isEmpty ? ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"] : format
            // Text 是最後一個欄位，本身可能含逗號
            let values = line.dropFirst(9).split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard values.count == fields.count,
                  let si = fields.firstIndex(of: "start"), let ei = fields.firstIndex(of: "end"),
                  let ti = fields.firstIndex(of: "text"),
                  let start = timestamp(values[si]), let end = timestamp(values[ei]) else { continue }
            // 跳過特效、繪圖指令
            if values[ti].contains("\\p1") { continue }
            let body = values[ti]
                .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: body)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// `00:01:02,345`、`01:02.345`、`0:01:02.34`
    static func timestamp(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = s.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let v = Double(part) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    static func stripTags(_ line: String) -> String {
        line.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
    }
}
