import Foundation
import Testing
@testable import VideoPlayerCore

struct PlaylistTests {
    @Test func naturalSortHandlesEpisodeNumbers() {
        let names = ["EP10.mkv", "EP2.mkv", "EP1.mkv", "第10集.mp4", "第3集.mp4", "[03].mkv", "[12].mkv", "S01E10.mkv", "S01E03.mkv"]
        let sorted = PlaylistBuilder.naturalSort(names.map { URL(fileURLWithPath: "/tmp/\($0)") }).map(\.lastPathComponent)
        #expect(sorted.firstIndex(of: "EP2.mkv")! < sorted.firstIndex(of: "EP10.mkv")!)
        #expect(sorted.firstIndex(of: "第3集.mp4")! < sorted.firstIndex(of: "第10集.mp4")!)
        #expect(sorted.firstIndex(of: "[03].mkv")! < sorted.firstIndex(of: "[12].mkv")!)
        #expect(sorted.firstIndex(of: "S01E03.mkv")! < sorted.firstIndex(of: "S01E10.mkv")!)
    }

    @Test func siblingsOnlyIncludeVideos() {
        let dir = TempDir()
        let ep1 = dir.file("Show EP1.mkv")
        dir.file("Show EP10.mkv")
        dir.file("Show EP2.mp4")
        dir.file("Show EP1.srt")
        dir.file("notes.txt")
        #expect(PlaylistBuilder.siblings(of: ep1).map(\.lastPathComponent) == ["Show EP1.mkv", "Show EP2.mp4", "Show EP10.mkv"])
    }

    @Test func expandFoldersAndDeduplicates() {
        let dir = TempDir()
        let a = dir.file("season/a2.mkv")
        dir.file("season/a1.mkv")
        let single = dir.file("other.mp4")
        let result = PlaylistBuilder.expand([single, dir.url.appendingPathComponent("season"), a])
        #expect(result.map(\.lastPathComponent) == ["other.mp4", "a1.mkv", "a2.mkv"])
    }
}

@MainActor
struct PlaybackStoreTests {
    @Test func persistsProgressAndChoices() {
        let dir = TempDir()
        let file = dir.url.appendingPathComponent("store.json")
        let video = URL(fileURLWithPath: "/videos/a.mkv")

        let store = PlaybackStore(fileURL: file)
        store.updatePosition(video, position: 120, duration: 1000)
        store.update(video) {
            $0.subtitle = .external(path: "/videos/a.zh-TW.srt")
            $0.bookmarks.append(Bookmark(time: 60, subtitle: "重點"))
        }
        store.save()

        let reloaded = PlaybackStore(fileURL: file)
        let record = reloaded.record(for: video)
        #expect(record.position == 120)
        #expect(record.resumePosition == 120)
        #expect(record.subtitle == .external(path: "/videos/a.zh-TW.srt"))
        #expect(record.bookmarks.first?.subtitle == "重點")
        #expect(abs(record.progress - 0.12) < 0.0001)
    }

    @Test func marksWatchedNearEnd() {
        let store = PlaybackStore(fileURL: TempDir().url.appendingPathComponent("s.json"))
        let video = URL(fileURLWithPath: "/v/b.mkv")
        store.updatePosition(video, position: 960, duration: 1000)
        #expect(store.record(for: video).watched)
        #expect(store.record(for: video).resumePosition == nil)
    }

    @Test func doesNotResumeNearStart() {
        var r = MediaRecord()
        r.position = 3
        r.duration = 1000
        #expect(r.resumePosition == nil)
    }
}
