import Foundation

public struct Bookmark: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var time: Double
    /// 加書籤當下畫面上的字幕
    public var subtitle: String?
    public var note: String
    public var createdAt: Date

    public init(id: UUID = UUID(), time: Double, subtitle: String?, note: String = "", createdAt: Date = Date()) {
        self.id = id
        self.time = time
        self.subtitle = subtitle
        self.note = note
        self.createdAt = createdAt
    }
}

public enum SubtitleChoice: Codable, Equatable, Sendable {
    case off
    case external(path: String)
    case embedded(id: Int)
}

public struct MediaRecord: Codable, Equatable, Sendable {
    public var position: Double = 0
    public var duration: Double = 0
    public var watched = false
    public var subtitle: SubtitleChoice?
    public var subtitleDelay: Double = 0
    public var bookmarks: [Bookmark] = []
    /// 這部影片的 Notion 頁面（學習筆記、截圖都放在這裡）
    public var notionPageURL: String?
    /// 頁面上是否已經有學習筆記；只有截圖時為 false。舊資料沒有這個欄位，有頁面就代表有筆記。
    public var notionHasNotes: Bool?
    public var updatedAt = Date()

    public init() {}

    public var hasNotionNotes: Bool { notionHasNotes ?? (notionPageURL != nil) }

    /// 0...1，未知長度時為 0
    public var progress: Double {
        duration > 0 ? min(max(position / duration, 0), 1) : 0
    }

    /// 重新打開時要跳到的位置；太靠近開頭或已接近結尾就從頭播
    public var resumePosition: Double? {
        guard !watched, position > 5, duration <= 0 || position < duration * PlaybackStore.watchedThreshold else {
            return nil
        }
        return position
    }
}

/// 每部影片的播放進度、字幕選擇、書籤，存成一個 JSON 檔
@MainActor
public final class PlaybackStore {
    public nonisolated static let watchedThreshold = 0.95

    public let fileURL: URL
    private var records: [String: MediaRecord]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.iso.decode([String: MediaRecord].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RushVideoPlayer/playback.json")
    }

    public static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    public func record(for url: URL) -> MediaRecord {
        records[Self.key(for: url)] ?? MediaRecord()
    }

    public func update(_ url: URL, _ change: (inout MediaRecord) -> Void) {
        var record = record(for: url)
        change(&record)
        record.updatedAt = Date()
        records[Self.key(for: url)] = record
    }

    /// 更新播放位置；超過 95% 自動標記已看完
    public func updatePosition(_ url: URL, position: Double, duration: Double) {
        update(url) { r in
            r.position = position
            if duration > 0 { r.duration = duration }
            if duration > 0, position >= duration * Self.watchedThreshold { r.watched = true }
        }
    }

    public func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.iso.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("PlaybackStore save failed: \(error)")
        }
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
