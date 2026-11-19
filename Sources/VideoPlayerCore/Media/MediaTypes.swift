import Foundation

public enum MediaTypes {
    public static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "wmv", "flv", "webm", "ts", "m2ts", "mts",
        "mpg", "mpeg", "vob", "ogv", "3gp", "rmvb", "rm", "divx", "f4v", "asf",
    ]

    public static let subtitleExtensions: Set<String> = [
        "srt", "ass", "ssa", "vtt", "sub", "idx", "smi", "sup",
    ]

    /// 可以解析成逐字稿的文字字幕格式
    public static let textSubtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]

    public static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isSubtitle(_ url: URL) -> Bool {
        subtitleExtensions.contains(url.pathExtension.lowercased())
    }
}

public enum TimeFormat {
    /// 秒數 → `m:ss` 或 `h:mm:ss`
    public static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
