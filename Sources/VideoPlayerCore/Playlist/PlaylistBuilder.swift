import Foundation

public enum PlaylistBuilder {
    /// Finder 的自然排序：EP2 會排在 EP10 前面，S01E03、第3集、[03] 都適用
    public static func naturalSort(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// 找出同資料夾的所有影片並排序
    public static func siblings(of video: URL) -> [URL] {
        let all = videos(in: video.deletingLastPathComponent())
        return all.contains(video.standardizedFileURL) ? all : naturalSort(all + [video.standardizedFileURL])
    }

    public static func videos(in directory: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return naturalSort(items.filter(MediaTypes.isVideo).map(\.standardizedFileURL))
    }

    /// 處理使用者丟進來的東西：資料夾展開成影片，檔案保持原順序
    public static func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                result += videos(in: url)
            } else if MediaTypes.isVideo(url) {
                result.append(url.standardizedFileURL)
            }
        }
        var seen = Set<URL>()
        return result.filter { seen.insert($0).inserted }
    }
}
