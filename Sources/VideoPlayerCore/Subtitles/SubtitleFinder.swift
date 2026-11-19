import Foundation

public struct SubtitleCandidate: Equatable, Sendable {
    public enum Match: Int, Comparable, Sendable {
        /// 同名（含語言標記）
        case sameName = 0
        /// 同名，放在 Subs/ 這類子資料夾
        case subfolder = 1
        /// 集數相同（S01E02）
        case episode = 2
        /// 資料夾內只有一部影片，任何字幕都算
        case loneVideo = 3

        public static func < (a: Match, b: Match) -> Bool { a.rawValue < b.rawValue }
    }

    public let url: URL
    public let language: SubtitleLanguage
    public let match: Match

    public init(url: URL, language: SubtitleLanguage, match: Match) {
        self.url = url
        self.language = language
        self.match = match
    }
}

/// 在影片旁邊找出對應的字幕檔，並依語言偏好排序
public struct SubtitleFinder: Sendable {
    public static let subfolderNames: Set<String> = ["subs", "sub", "subtitles", "subtitle", "字幕"]

    public var priority: [SubtitleLanguage]

    public init(priority: [SubtitleLanguage] = SubtitleLanguage.defaultPriority) {
        self.priority = priority
    }

    /// 回傳排序好的字幕候選：第一個就是最適合的
    public func find(for video: URL) -> [SubtitleCandidate] {
        let dir = video.deletingLastPathComponent()
        let stem = Self.normalize(video.deletingPathExtension().lastPathComponent)
        let siblings = Self.contents(of: dir)
        let videoCount = siblings.filter(MediaTypes.isVideo).count
        let episode = Self.episodeTag(stem)

        var results: [SubtitleCandidate] = []
        func consider(_ url: URL, inSubfolder: Bool, forceMatch: Bool = false) {
            guard MediaTypes.isSubtitle(url) else { return }
            let subStem = Self.normalize(url.deletingPathExtension().lastPathComponent)
            let match: SubtitleCandidate.Match
            let tags: String
            if let rest = Self.remainder(of: subStem, after: stem) {
                match = inSubfolder ? .subfolder : .sameName
                tags = rest
            } else if forceMatch {
                match = .subfolder
                tags = subStem
            } else if let episode, Self.episodeTag(subStem) == episode {
                match = .episode
                tags = subStem
            } else if videoCount == 1 {
                match = .loneVideo
                tags = subStem
            } else {
                return
            }
            results.append(SubtitleCandidate(url: url, language: language(of: url, tags: tags), match: match))
        }

        for url in siblings {
            if Self.isDirectory(url) {
                guard Self.subfolderNames.contains(url.lastPathComponent.lowercased()) else { continue }
                for inner in Self.contents(of: url) {
                    if Self.isDirectory(inner) {
                        // Subs/<影片名>/2_English.srt 這種結構
                        let forThisVideo = Self.normalize(inner.lastPathComponent) == stem
                        guard forThisVideo || videoCount == 1 else { continue }
                        Self.contents(of: inner).forEach { consider($0, inSubfolder: true, forceMatch: true) }
                    } else {
                        consider(inner, inSubfolder: true)
                    }
                }
            } else {
                consider(url, inSubfolder: false)
            }
        }
        return sort(results)
    }

    public func sort(_ candidates: [SubtitleCandidate]) -> [SubtitleCandidate] {
        candidates.sorted { a, b in
            let ra = priority.rank(of: a.language), rb = priority.rank(of: b.language)
            if ra != rb { return ra < rb }
            if a.match != b.match { return a.match < b.match }
            // 同語言時偏好 ASS（保留樣式），再依檔名排序讓結果穩定
            let aa = a.url.pathExtension.lowercased() == "ass", ba = b.url.pathExtension.lowercased() == "ass"
            if aa != ba { return aa }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
    }

    private func language(of url: URL, tags: String) -> SubtitleLanguage {
        let fromName = SubtitleLanguage.fromTags(tags)
        guard fromName == .unknown || fromName == .chinese,
              MediaTypes.textSubtitleExtensions.contains(url.pathExtension.lowercased()),
              let handle = try? FileHandle(forReadingFrom: url) else { return fromName }
        defer { try? handle.close() }
        let sample = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        guard let text = TextEncodingDetector.decode(sample)?.text else { return fromName }
        let sniffed = ChineseScriptSniffer.sniff(text)
        return sniffed == .unknown ? fromName : sniffed
    }

    // MARK: - Helpers

    static func normalize(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// `stem` 完全相同回傳空字串；`stem` 後接分隔符號時回傳剩下的語言標記
    static func remainder(of subStem: String, after stem: String) -> String? {
        if subStem == stem { return "" }
        guard subStem.hasPrefix(stem) else { return nil }
        let rest = subStem.dropFirst(stem.count)
        guard let first = rest.first, ".-_ [(".contains(first) else { return nil }
        return String(rest)
    }

    /// `S01E02` → `1x2`
    static func episodeTag(_ s: String) -> String? {
        guard let m = s.firstMatch(of: /s(\d{1,2})[ ._-]?e(\d{1,3})/.ignoresCase()),
              let season = Int(m.1), let ep = Int(m.2) else { return nil }
        return "\(season)x\(ep)"
    }

    static func contents(of dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}
