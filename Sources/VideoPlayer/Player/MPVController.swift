import AppKit
import Libmpv

/// mpv 回報的屬性值
enum MPVValue {
    case double(Double)
    case flag(Bool)
    case string(String)
    case int(Int64)
    case none

    var double: Double? { if case .double(let v) = self { v } else { nil } }
    var flag: Bool? { if case .flag(let v) = self { v } else { nil } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
}

struct MPVTrack: Identifiable, Equatable {
    let id: Int
    let type: String
    let title: String?
    let lang: String?
    let externalFilename: String?
    let codec: String?
    var selected: Bool

    var isExternal: Bool { externalFilename != nil }

    var displayName: String {
        var parts: [String] = []
        if let title, !title.isEmpty { parts.append(title) }
        if let lang, !lang.isEmpty { parts.append(lang) }
        if parts.isEmpty, let externalFilename { parts.append((externalFilename as NSString).lastPathComponent) }
        if parts.isEmpty { parts.append("軌道 \(id)") }
        if isExternal { parts.append("外部") }
        return parts.joined(separator: " · ")
    }
}

@MainActor
protocol MPVControllerDelegate: AnyObject {
    func mpvPropertyChanged(_ name: String, _ value: MPVValue)
    func mpvFileLoaded()
    func mpvEndFile(reason: mpv_end_file_reason)
}

/// 包裝 libmpv：用 CAMetalLayer（gpu-next + MoltenVK）輸出畫面，VideoToolbox 硬體解碼
@MainActor
final class MPVController {
    private(set) var handle: OpaquePointer?
    weak var delegate: MPVControllerDelegate?

    static let observed: [(String, mpv_format)] = [
        ("time-pos", MPV_FORMAT_DOUBLE),
        ("duration", MPV_FORMAT_DOUBLE),
        ("pause", MPV_FORMAT_FLAG),
        ("volume", MPV_FORMAT_DOUBLE),
        ("mute", MPV_FORMAT_FLAG),
        ("speed", MPV_FORMAT_DOUBLE),
        ("sub-delay", MPV_FORMAT_DOUBLE),
        ("sub-scale", MPV_FORMAT_DOUBLE),
        ("eof-reached", MPV_FORMAT_FLAG),
        ("track-list/count", MPV_FORMAT_INT64),
        ("sid", MPV_FORMAT_STRING),
        ("sub-text", MPV_FORMAT_STRING),
        ("paused-for-cache", MPV_FORMAT_FLAG),
    ]

    init(layer: CAMetalLayer) {
        guard let mpv = mpv_create() else { fatalError("無法建立 mpv") }
        handle = mpv

        // wid 是 CAMetalLayer 物件的指標
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        check(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid))
        let options: [(String, String)] = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"),
            // 播完停在最後一格並設定 eof-reached，由 App 決定是否接下一集
            ("keep-open", "yes"),
            // 字幕由 SubtitleFinder 自己找，避免和 mpv 內建比對重複載入
            ("sub-auto", "no"),
            ("sub-font", "PingFang TC"),
            ("sub-font-size", "46"),
            ("osd-font", "PingFang TC"),
            ("osd-font-size", "36"),
            ("osd-duration", "1200"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("input-media-keys", "yes"),
            ("ytdl", "no"),
            ("volume-max", "150"),
            ("audio-client-name", "Rush Video Player"),
            ("screenshot-directory", "~~desktop/"),
        ]
        for (name, value) in options {
            check(mpv_set_option_string(mpv, name, value))
        }
        check(mpv_initialize(mpv))

        for (name, format) in Self.observed {
            mpv_observe_property(mpv, 0, name, format)
        }
        mpv_set_wakeup_callback(mpv, { ctx in
            guard let ctx else { return }
            let controller = Unmanaged<MPVController>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { controller.drainEvents() } }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func shutdown() {
        guard let mpv = handle else { return }
        mpv_set_wakeup_callback(mpv, nil, nil)
        handle = nil
        mpv_terminate_destroy(mpv)
    }

    // MARK: - Commands

    func loadFile(_ url: URL, start: Double?) {
        var args = [url.path, "replace", "-1"]
        if let start, start > 0 { args.append("start=\(start)") }
        command("loadfile", args)
    }

    @discardableResult
    func command(_ name: String, _ args: [String] = []) -> Bool {
        guard let mpv = handle else { return false }
        let strings = ([name] + args).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var cargs: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) } + [nil]
        return check(mpv_command(mpv, &cargs))
    }

    func showText(_ text: String, duration: Int = 1200) {
        command("show-text", [text, String(duration)])
    }

    func setDouble(_ name: String, _ value: Double) {
        guard let mpv = handle else { return }
        var v = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &v)
    }

    func setFlag(_ name: String, _ value: Bool) {
        guard let mpv = handle else { return }
        var v: Int32 = value ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &v)
    }

    func setString(_ name: String, _ value: String) {
        guard let mpv = handle else { return }
        mpv_set_property_string(mpv, name, value)
    }

    func getString(_ name: String) -> String? {
        guard let mpv = handle, let cstr = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(cstr) }
        return String(cString: cstr)
    }

    func getInt(_ name: String) -> Int? {
        guard let mpv = handle else { return nil }
        var v: Int64 = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_INT64, &v) >= 0 ? Int(v) : nil
    }

    func getDouble(_ name: String) -> Double? {
        guard let mpv = handle else { return nil }
        var v: Double = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &v) >= 0 ? v : nil
    }

    func tracks() -> [MPVTrack] {
        let count = getInt("track-list/count") ?? 0
        return (0..<count).compactMap { i in
            let p = "track-list/\(i)/"
            guard let id = getInt(p + "id"), let type = getString(p + "type") else { return nil }
            return MPVTrack(
                id: id, type: type,
                title: getString(p + "title"), lang: getString(p + "lang"),
                externalFilename: getString(p + "external-filename"),
                codec: getString(p + "codec"),
                selected: getString(p + "selected") == "yes")
        }
    }

    // MARK: - Events

    private func drainEvents() {
        while let mpv = handle, let event = mpv_wait_event(mpv, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
            switch event.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let prop = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee else { break }
                delegate?.mpvPropertyChanged(String(cString: prop.name), Self.value(of: prop))
            case MPV_EVENT_FILE_LOADED:
                delegate?.mpvFileLoaded()
            case MPV_EVENT_END_FILE:
                if let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
                    delegate?.mpvEndFile(reason: end.reason)
                }
            case MPV_EVENT_SHUTDOWN:
                shutdown()
            default:
                break
            }
        }
    }

    private static func value(of prop: mpv_event_property) -> MPVValue {
        guard let data = prop.data else { return .none }
        switch prop.format {
        case MPV_FORMAT_DOUBLE: return .double(data.assumingMemoryBound(to: Double.self).pointee)
        case MPV_FORMAT_FLAG: return .flag(data.assumingMemoryBound(to: Int32.self).pointee != 0)
        case MPV_FORMAT_INT64: return .int(data.assumingMemoryBound(to: Int64.self).pointee)
        case MPV_FORMAT_STRING:
            guard let cstr = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return .none }
            return .string(String(cString: cstr))
        default: return .none
        }
    }

    @discardableResult
    private func check(_ status: Int32) -> Bool {
        if status < 0 { NSLog("mpv error: \(String(cString: mpv_error_string(status)))") }
        return status >= 0
    }
}
