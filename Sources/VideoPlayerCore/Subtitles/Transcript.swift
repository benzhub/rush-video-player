import Foundation

/// 影片逐字稿：來自外部字幕檔，或播放時從內嵌字幕累積
public struct Transcript: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case file(URL)
        /// 只包含已經播放過的片段
        case accumulated
    }

    public private(set) var cues: [SubtitleCue]
    public var source: Source

    public init(cues: [SubtitleCue] = [], source: Source = .accumulated) {
        self.cues = cues.sorted { $0.start < $1.start }
        self.source = source
    }

    public var isEmpty: Bool { cues.isEmpty }

    /// 加入播放時看到的字幕行；同一句連續出現時只延長結束時間
    public mutating func append(text: String, at time: Double) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, time.isFinite else { return }
        if let i = cues.lastIndex(where: { $0.start <= time }), cues[i].text == clean, time - cues[i].end < 10 {
            cues[i].end = max(cues[i].end, time)
            return
        }
        if cues.contains(where: { $0.text == clean && abs($0.start - time) < 1 }) { return }
        let cue = SubtitleCue(start: time, end: time, text: clean)
        let index = cues.firstIndex(where: { $0.start > time }) ?? cues.endIndex
        cues.insert(cue, at: index)
    }

    public func cues(from start: Double, to end: Double) -> [SubtitleCue] {
        cues.filter { $0.end >= start && $0.start <= end }
    }

    public func text(at time: Double) -> String? {
        cues.last(where: { $0.start <= time && time <= $0.end + 0.5 })?.text
    }

    /// 給 AI 讀的格式：每行 `[m:ss] 文字`，多行字幕合併成一行
    public func formatted(from start: Double = 0, to end: Double = .infinity) -> String {
        cues(from: start, to: end)
            .map { "[\(TimeFormat.clock($0.start))] \($0.text.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n")
    }
}
