import AppKit
import Combine
import Libmpv
import VideoPlayerCore

/// 播放器狀態：播放清單、字幕自動載入、進度記憶、書籤
@MainActor
final class PlayerModel: ObservableObject, MPVControllerDelegate {
    static let shared = PlayerModel()

    let videoView = VideoNSView()
    let mpv: MPVController
    let store = PlaybackStore(fileURL: PlaybackStore.defaultURL)

    // 播放清單
    @Published private(set) var playlist: [URL] = []
    @Published private(set) var currentIndex: Int?

    // 播放狀態
    @Published private(set) var timePos: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var paused = true
    @Published private(set) var volume: Double = 100
    @Published private(set) var muted = false
    @Published private(set) var speed: Double = 1
    @Published private(set) var subDelay: Double = 0
    @Published private(set) var buffering = false
    @Published private(set) var tracks: [MPVTrack] = []
    @Published private(set) var subtitleText: String?

    // 學習相關
    @Published private(set) var transcript = Transcript()
    @Published private(set) var bookmarks: [Bookmark] = []

    /// 使用者取消了這一集結尾的「下一集」倒數
    @Published var nextCancelled = false
    /// 播放清單項目變動時遞增，讓清單重新讀取進度
    @Published private(set) var recordsVersion = 0

    /// 一集看完時通知（AI 自動筆記用）
    let finishedEpisode = PassthroughSubject<URL, Never>()
    /// 換集時通知（AI 對話重置用）
    let fileChanged = PassthroughSubject<URL, Never>()

    private var lastProgressWrite = Date.distantPast
    private var lastDiskSave = Date.distantPast
    private var finishedCurrent = false
    private var lastSubtitleID: Int?

    /// `RVP_DEBUG=1` 時把重要狀態輸出到 stderr，方便除錯
    private static let debug = ProcessInfo.processInfo.environment["RVP_DEBUG"] != nil

    private func log(_ message: @autoclosure () -> String) {
        if Self.debug { FileHandle.standardError.write(Data("[RVP] \(message())\n".utf8)) }
    }

    private init() {
        mpv = MPVController(layer: videoView.metalLayer)
        mpv.delegate = self
        videoView.onResize = { [weak self] size in self?.mpv.matchOutputSize(size) }
    }

    var currentURL: URL? { currentIndex.flatMap { playlist.indices.contains($0) ? playlist[$0] : nil } }
    var hasNext: Bool { currentIndex.map { $0 + 1 < playlist.count } ?? false }
    var hasPrevious: Bool { (currentIndex ?? 0) > 0 }
    var title: String { currentURL?.deletingPathExtension().lastPathComponent ?? "Rush Video Player" }
    var subtitleTracks: [MPVTrack] { tracks.filter { $0.type == "sub" } }
    var audioTracks: [MPVTrack] { tracks.filter { $0.type == "audio" } }

    /// 結尾倒數秒數；沒有下一集或使用者取消時為 nil
    var nextCountdown: Int? {
        guard AppSettings.autoplayNext, hasNext, !nextCancelled, duration > 30 else { return nil }
        let remaining = duration - timePos
        let limit = Double(AppSettings.countdownSeconds)
        return remaining <= limit && remaining >= 0 ? Int(remaining.rounded(.up)) : nil
    }

    // MARK: - 開檔與播放清單

    /// 開啟檔案或資料夾。單一影片會自動把同資料夾的其他影片排成播放清單。
    func open(_ urls: [URL]) {
        let subtitles = urls.filter(MediaTypes.isSubtitle)
        let videos = PlaylistBuilder.expand(urls)

        if videos.isEmpty {
            subtitles.forEach(addExternalSubtitle)
            return
        }
        if videos.count == 1, let video = videos.first {
            let siblings = PlaylistBuilder.siblings(of: video)
            playlist = siblings
            play(at: siblings.firstIndex(of: video) ?? 0)
        } else {
            playlist = videos
            play(at: 0)
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(videos[0])
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "選擇影片或資料夾"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    func play(at index: Int) {
        guard playlist.indices.contains(index) else { return }
        saveProgress(force: true)
        currentIndex = index
        let url = playlist[index]
        let record = store.record(for: url)
        let start = AppSettings.resumePlayback ? record.resumePosition : nil

        timePos = start ?? 0
        duration = record.duration
        tracks = []
        subtitleText = nil
        transcript = Transcript()
        bookmarks = record.bookmarks
        nextCancelled = false
        finishedCurrent = false

        log("play \(index + 1)/\(playlist.count) \(url.lastPathComponent) start=\(start ?? 0) playlist=\(playlist.map(\.lastPathComponent))")
        mpv.loadFile(url, start: start)
        mpv.setFlag("pause", false)
        mpv.setDouble("sub-delay", record.subtitleDelay)
        if let start { mpv.showText("從 \(TimeFormat.clock(start)) 繼續播放", duration: 2500) }
        fileChanged.send(url)
    }

    func playNext() { if let i = currentIndex, hasNext { play(at: i + 1) } }
    func playPrevious() { if let i = currentIndex, hasPrevious { play(at: i - 1) } }

    func movePlaylistItems(from source: IndexSet, to destination: Int) {
        let current = currentURL
        playlist.move(fromOffsets: source, toOffset: destination)
        currentIndex = current.flatMap { playlist.firstIndex(of: $0) }
    }

    func removeFromPlaylist(_ url: URL) {
        guard url != currentURL, let i = playlist.firstIndex(of: url) else { return }
        let current = currentURL
        playlist.remove(at: i)
        currentIndex = current.flatMap { playlist.firstIndex(of: $0) }
    }

    func appendToPlaylist(_ urls: [URL]) {
        let new = PlaylistBuilder.expand(urls).filter { !playlist.contains($0) }
        if playlist.isEmpty { open(urls) } else { playlist += new }
    }

    func record(for url: URL) -> MediaRecord { store.record(for: url) }

    // MARK: - 播放控制

    func togglePause() {
        guard currentURL != nil else { showOpenPanel(); return }
        if paused, duration > 0, timePos >= duration - 0.5 {
            // 已在結尾：從頭重播
            seek(to: 0)
        }
        mpv.setFlag("pause", !paused)
    }

    func seek(to seconds: Double) {
        mpv.command("seek", [String(max(0, seconds)), "absolute+exact"])
    }

    func seek(by delta: Double) {
        mpv.command("seek", [String(delta), "relative+exact"])
    }

    func setVolume(_ v: Double) { mpv.setDouble("volume", min(max(v, 0), 150)) }
    func changeVolume(by delta: Double) {
        setVolume(volume + delta)
        mpv.showText("音量 \(Int(min(max(volume + delta, 0), 150)))%")
    }
    func toggleMute() { mpv.setFlag("mute", !muted) }

    func setSpeed(_ s: Double) {
        let clamped = min(max(s, 0.25), 4)
        mpv.setDouble("speed", clamped)
        mpv.showText(String(format: "速度 %.2gx", clamped))
    }

    func changeSpeed(by delta: Double) { setSpeed(((speed + delta) * 100).rounded() / 100) }

    func changeSubDelay(by delta: Double) {
        let value = delta == 0 ? 0 : ((subDelay + delta) * 10).rounded() / 10
        mpv.setDouble("sub-delay", value)
        mpv.showText(String(format: "字幕延遲 %+.1f 秒", value))
        if let url = currentURL { store.update(url) { $0.subtitleDelay = value } }
    }

    func changeSubScale(by delta: Double) {
        let current = mpv.getDouble("sub-scale") ?? 1
        let value = min(max(current + delta, 0.3), 3)
        mpv.setDouble("sub-scale", value)
        mpv.showText("字幕大小 \(Int(value * 100))%")
    }

    // MARK: - 字幕

    /// 選擇字幕軌（nil = 關閉），並記住這部影片的選擇
    func selectSubtitle(_ track: MPVTrack?) {
        if let track {
            mpv.setString("sid", String(track.id))
        } else {
            mpv.setString("sid", "no")
        }
        if let url = currentURL {
            store.update(url) { r in
                if let track {
                    r.subtitle = track.externalFilename.map { .external(path: $0) } ?? .embedded(id: track.id)
                } else {
                    r.subtitle = .off
                }
            }
        }
    }

    /// 開／關字幕：關閉時記住原本的軌，再開時選回它（找不到就選第一條）
    func toggleSubtitles() {
        if let current = subtitleTracks.first(where: \.selected) {
            lastSubtitleID = current.id
            selectSubtitle(nil)
            mpv.showText("字幕：關閉")
        } else if let track = subtitleTracks.first(where: { $0.id == lastSubtitleID }) ?? subtitleTracks.first {
            selectSubtitle(track)
            mpv.showText("字幕：\(track.displayName)")
        } else {
            mpv.showText("沒有字幕")
        }
    }

    func selectAudio(_ track: MPVTrack) { mpv.setString("aid", String(track.id)) }

    /// 手動加入字幕（拖放或選單），並立即選用
    func addExternalSubtitle(_ url: URL) {
        guard currentURL != nil else { return }
        mpv.command("sub-add", [url.path, "select"])
        refreshTracks()
        if let track = subtitleTracks.first(where: { $0.externalFilename == url.path }) {
            selectSubtitle(track)
        }
        mpv.showText("已載入字幕：\(url.lastPathComponent)")
    }

    func showSubtitleOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.directoryURL = currentURL?.deletingLastPathComponent()
        panel.message = "選擇字幕檔"
        if panel.runModal() == .OK, let url = panel.url { addExternalSubtitle(url) }
    }

    /// 檔案載入後：找出旁邊的字幕全部加入，再依記憶或語言偏好選一個
    private func loadSubtitles(for video: URL) {
        let finder = SubtitleFinder(priority: AppSettings.subtitlePriority)
        let candidates = finder.find(for: video).prefix(12)
        for candidate in candidates {
            let title = candidate.language == .unknown ? candidate.url.lastPathComponent : candidate.language.displayName
            mpv.command("sub-add", [candidate.url.path, "auto", title, candidate.language.rawValue])
        }
        refreshTracks()

        let subs = subtitleTracks
        switch store.record(for: video).subtitle {
        case .off?:
            mpv.setString("sid", "no")
            return
        case .external(let path)?:
            if let t = subs.first(where: { $0.externalFilename == path }) { mpv.setString("sid", String(t.id)); return }
        case .embedded(let id)?:
            if subs.contains(where: { $0.id == id && !$0.isExternal }) { mpv.setString("sid", String(id)); return }
        case nil:
            break
        }

        // 沒有記憶：外部字幕和內嵌字幕一起依語言偏好排序，同語言時外部優先
        let priority = AppSettings.subtitlePriority
        let ranked = subs.sorted { a, b in
            let la = language(of: a), lb = language(of: b)
            let ra = priority.rank(of: la), rb = priority.rank(of: lb)
            if ra != rb { return ra < rb }
            if a.isExternal != b.isExternal { return a.isExternal }
            if let ia = candidates.firstIndex(where: { $0.url.path == a.externalFilename }),
               let ib = candidates.firstIndex(where: { $0.url.path == b.externalFilename }) { return ia < ib }
            return a.id < b.id
        }
        log("subtitles: \(subs.map(\.displayName)) → \(ranked.first?.displayName ?? "none")")
        if let best = ranked.first {
            mpv.setString("sid", String(best.id))
            mpv.showText("字幕：\(best.displayName)", duration: 2000)
        }
    }

    private func language(of track: MPVTrack) -> SubtitleLanguage {
        if let lang = track.lang, let known = SubtitleLanguage(rawValue: lang) { return known }
        return SubtitleLanguage.fromTags([track.lang, track.title].compactMap { $0 }.joined(separator: " "))
    }

    private func refreshTracks() {
        tracks = mpv.tracks()
    }

    /// 字幕軌改變時重建逐字稿：外部文字字幕直接解析整個檔案，其他情況播放時累積
    private func rebuildTranscript() {
        let selected = subtitleTracks.first(where: \.selected)
        if let path = selected?.externalFilename,
           MediaTypes.textSubtitleExtensions.contains((path as NSString).pathExtension.lowercased()) {
            let url = URL(fileURLWithPath: path)
            transcript = Transcript(cues: SubtitleParser.parse(contentsOf: url), source: .file(url))
            log("transcript \(url.lastPathComponent): \(transcript.cues.count) cues, first=\(transcript.cues.first?.text ?? "-")")
        } else if case .file = transcript.source {
            transcript = Transcript()
        }
    }

    // MARK: - 書籤

    func addBookmark(note: String = "") {
        guard let url = currentURL else { return }
        let bookmark = Bookmark(time: timePos, subtitle: subtitleText ?? transcript.text(at: timePos), note: note)
        bookmarks.append(bookmark)
        bookmarks.sort { $0.time < $1.time }
        store.update(url) { $0.bookmarks = bookmarks }
        store.save()
        mpv.showText("🔖 已加入書籤 \(TimeFormat.clock(timePos))")
    }

    func updateBookmark(_ bookmark: Bookmark) {
        guard let url = currentURL, let i = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        bookmarks[i] = bookmark
        store.update(url) { $0.bookmarks = bookmarks }
    }

    func deleteBookmark(_ bookmark: Bookmark) {
        guard let url = currentURL else { return }
        bookmarks.removeAll { $0.id == bookmark.id }
        store.update(url) { $0.bookmarks = bookmarks }
    }

    func setNotionPage(_ pageURL: String, for video: URL, hasNotes: Bool) {
        store.update(video) { r in
            if r.notionPageURL != pageURL { r.notionHasNotes = false }
            r.notionPageURL = pageURL
            if hasNotes { r.notionHasNotes = true }
        }
        store.save()
    }

    // MARK: - 進度記憶

    func saveProgress(force: Bool = false) {
        guard let url = currentURL, duration > 0 else { return }
        let now = Date()
        if force || now.timeIntervalSince(lastProgressWrite) > 5 {
            store.updatePosition(url, position: timePos, duration: duration)
            lastProgressWrite = now
            recordsVersion += 1
        }
        if force || now.timeIntervalSince(lastDiskSave) > 10 {
            store.save()
            lastDiskSave = now
        }
    }

    func shutdown() {
        saveProgress(force: true)
        mpv.shutdown()
    }

    // MARK: - MPVControllerDelegate

    func mpvPropertyChanged(_ name: String, _ value: MPVValue) {
        switch name {
        case "time-pos":
            if let v = value.double {
                timePos = v
                saveProgress()
            }
        case "duration": duration = value.double ?? 0
        case "pause":
            paused = value.flag ?? true
            if paused { saveProgress(force: true) }
        case "volume": volume = value.double ?? volume
        case "mute": muted = value.flag ?? false
        case "speed": speed = value.double ?? 1
        case "sub-delay": subDelay = value.double ?? 0
        case "paused-for-cache": buffering = value.flag ?? false
        case "eof-reached":
            if value.flag == true { handleEndOfFile() }
        case "track-list/count":
            refreshTracks()
        case "sid":
            refreshTracks()
            rebuildTranscript()
        case "sub-text":
            let text = value.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            subtitleText = (text?.isEmpty ?? true) ? nil : text
            if let text = subtitleText, case .accumulated = transcript.source {
                transcript.append(text: text, at: timePos)
            }
        default:
            break
        }
    }

    func mpvFileLoaded() {
        guard let url = currentURL else { return }
        loadSubtitles(for: url)
        rebuildTranscript()
    }

    func mpvEndFile(reason: mpv_end_file_reason) {
        if reason == MPV_END_FILE_REASON_ERROR, let url = currentURL {
            mpv.showText("無法播放：\(url.lastPathComponent)", duration: 3000)
        }
    }

    private func handleEndOfFile() {
        guard let url = currentURL, !finishedCurrent else { return }
        finishedCurrent = true
        store.update(url) { r in
            r.watched = true
            r.position = duration
        }
        store.save()
        recordsVersion += 1
        finishedEpisode.send(url)
        log("finished \(url.lastPathComponent), autoplay=\(AppSettings.autoplayNext) hasNext=\(hasNext)")

        if AppSettings.autoplayNext, hasNext, !nextCancelled {
            playNext()
        }
    }
}
