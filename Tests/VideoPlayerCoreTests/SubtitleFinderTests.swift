import Foundation
import Testing
@testable import VideoPlayerCore

struct SubtitleLanguageTests {
    @Test(arguments: [
        (".zh-TW", SubtitleLanguage.traditionalChinese), (".cht", .traditionalChinese), (".繁體", .traditionalChinese),
        (".Big5", .traditionalChinese), (".zh-Hant", .traditionalChinese), ("[繁英雙語]", .traditionalChinese),
        (".zh-CN", .simplifiedChinese), (".chs", .simplifiedChinese), (".简体", .simplifiedChinese),
        (".chs&eng", .simplifiedChinese), (".chi", .chinese), (".en", .english), (".English", .english),
        (".jpn", .japanese), ("", .unknown), (".forced", .unknown),
    ])
    func detectsLanguageFromTags(tags: String, expected: SubtitleLanguage) {
        #expect(SubtitleLanguage.fromTags(tags) == expected)
    }

    @Test func rankPlacesGenericChineseBetweenVariants() {
        let p = SubtitleLanguage.defaultPriority
        #expect(p.rank(of: .traditionalChinese) < p.rank(of: .chinese))
        #expect(p.rank(of: .chinese) < p.rank(of: .simplifiedChinese))
        #expect(p.rank(of: .english) < p.rank(of: .japanese))
        #expect(p.rank(of: .japanese) < p.rank(of: .unknown))
    }

    @Test func priorityRoundTripsThroughStorageString() {
        let p: [SubtitleLanguage] = [.english, .traditionalChinese]
        #expect([SubtitleLanguage](storageString: p.storageString) == p)
        #expect([SubtitleLanguage](storageString: "garbage") == SubtitleLanguage.defaultPriority)
    }
}

struct SubtitleFinderTests {
    @Test func findsSameNameSubtitlesRankedByLanguage() {
        let dir = TempDir()
        let video = dir.file("Movie.2024.1080p.mkv")
        dir.file("Movie.2024.1080p.Ep2.mkv")
        dir.file("Movie.2024.1080p.en.srt")
        dir.file("Movie.2024.1080p.zh-CN.srt")
        dir.file("Movie.2024.1080p.zh-TW.ass")
        dir.file("Other.srt")

        let found = SubtitleFinder().find(for: video)
        #expect(found.map(\.url.lastPathComponent) == [
            "Movie.2024.1080p.zh-TW.ass", "Movie.2024.1080p.zh-CN.srt", "Movie.2024.1080p.en.srt",
        ])
        #expect(found.allSatisfy { $0.match == .sameName })
    }

    @Test func respectsCustomPriority() {
        let dir = TempDir()
        let video = dir.file("a.mkv")
        dir.file("b.mkv")
        dir.file("a.chs.srt")
        dir.file("a.eng.srt")
        let found = SubtitleFinder(priority: [.english, .simplifiedChinese]).find(for: video)
        #expect(found.first?.language == .english)
    }

    @Test func searchesSubsFolders() {
        let dir = TempDir()
        let video = dir.file("Show.S01E01.mkv")
        dir.file("Show.S01E02.mkv")
        dir.file("Subs/Show.S01E01.cht.srt")
        dir.file("字幕/Show.S01E01.chs.srt")
        dir.file("Subtitles/Show.S01E01/2_English.srt")
        dir.file("Subs/Show.S01E02.cht.srt")

        let found = SubtitleFinder().find(for: video)
        #expect(Set(found.map(\.url.lastPathComponent)) == ["Show.S01E01.cht.srt", "Show.S01E01.chs.srt", "2_English.srt"])
        #expect(found.first?.language == .traditionalChinese)
        #expect(found.allSatisfy { $0.match == .subfolder })
    }

    @Test func matchesByEpisodeNumber() {
        let dir = TempDir()
        let video = dir.file("[Group] Show - S02E05 [1080p].mkv")
        dir.file("[Group] Show - S02E06 [1080p].mkv")
        dir.file("Show.S02E05.繁體.srt")
        dir.file("Show.S02E06.繁體.srt")
        let found = SubtitleFinder().find(for: video)
        #expect(found.map(\.url.lastPathComponent) == ["Show.S02E05.繁體.srt"])
        #expect(found.first?.match == .episode)
    }

    @Test func loneVideoAcceptsAnySubtitleAndSniffsScript() {
        let dir = TempDir()
        let video = dir.file("movie.mp4")
        dir.file("Chinese.srt", srt("這個時候我們來說一下為什麼會這樣，還有後面發生的事情。", times: 3))
        dir.file("random.srt", srt("Hello there, this is plain English dialogue for testing purposes only.", times: 10))
        let found = SubtitleFinder().find(for: video)
        #expect(found.count == 2)
        #expect(found.first?.url.lastPathComponent == "Chinese.srt")
        #expect(found.first?.language == .traditionalChinese)
        #expect(found.first?.match == .loneVideo)
    }

    @Test func ignoresPrefixWithoutSeparator() {
        #expect(SubtitleFinder.remainder(of: "movie2", after: "movie") == nil)
        #expect(SubtitleFinder.remainder(of: "movie.en", after: "movie") == ".en")
        #expect(SubtitleFinder.remainder(of: "movie", after: "movie") == "")
    }

    @Test func unicodeNormalizationMatches() {
        let dir = TempDir()
        // 「é」分別使用組合字元（NFD）與預組字元（NFC）
        let video = dir.file("Cafe\u{301}.mkv")
        dir.file("x.mkv")
        dir.file("Caf\u{E9}.en.srt")
        #expect(SubtitleFinder().find(for: video).count == 1)
    }

    private func srt(_ line: String, times: Int) -> String {
        (1...times).map { "\($0)\n00:00:0\($0 % 10),000 --> 00:00:0\($0 % 10),900\n\(line)\n" }.joined(separator: "\n")
    }
}
