import AppKit
import VideoPlayerCore

/// 擷取當下的影格與時間、字幕
struct CapturedFrame: Identifiable {
    let id = UUID()
    let image: CGImage
    let video: URL
    let videoTitle: String
    let duration: Double
    let time: Double
    let subtitle: String?

    /// 圖片說明：`[mm:ss] 當下字幕`
    var caption: String {
        let clock = "[\(TimeFormat.clock(time))]"
        guard let subtitle, !subtitle.isEmpty else { return clock }
        return "\(clock) \(subtitle.replacingOccurrences(of: "\n", with: " "))"
    }
}

/// 截圖到 Notion：直接上傳，或先用紅筆標註再上傳。
/// 影像只在記憶體中處理（mpv `screenshot-raw` → PNG/JPEG → Notion File Upload API），不寫入任何檔案。
@MainActor
final class NotionScreenshots: ObservableObject {
    /// 正在標註的影格（顯示標註視窗）
    @Published var annotating: CapturedFrame?
    @Published private(set) var status: String?
    @Published private(set) var lastPageURL: String?

    private let player: PlayerModel
    /// 上傳依序進行：同一部影片連續截圖時，後面的會用到第一張建立的頁面
    private var queue: Task<Void, Never>?
    /// 標註前是否正在播放，結束標註後恢復
    private var resumeAfterAnnotation = false

    init(player: PlayerModel) {
        self.player = player
    }

    var canCapture: Bool { player.currentURL != nil && AppSettings.hasNotion }

    func capture(annotate: Bool) {
        guard player.currentURL != nil, annotating == nil else { return }
        guard AppSettings.hasNotion else {
            show("⚠️ 請先到「設定 → Notion」填入 Token 和筆記存放頁面")
            return
        }
        guard let frame = grab() else {
            show("⚠️ 無法擷取目前畫面")
            return
        }
        if annotate {
            resumeAfterAnnotation = !player.paused
            player.mpv.setFlag("pause", true)
            annotating = frame
        } else {
            upload(frame, image: frame.image)
        }
    }

    /// 標註視窗按「上傳」：把筆跡合成到原解析度圖片
    func finishAnnotation(strokes: [[CGPoint]], lineWidth: CGFloat) {
        guard let frame = annotating else { return }
        annotating = nil
        if let image = FrameImage.annotate(frame.image, strokes: strokes, lineWidth: lineWidth) {
            upload(frame, image: image)
        } else {
            show("⚠️ 無法合成標註")
        }
    }

    /// 標註視窗關閉（上傳或取消）後恢復播放
    func annotationClosed() {
        annotating = nil
        if resumeAfterAnnotation { player.mpv.setFlag("pause", false) }
        resumeAfterAnnotation = false
    }

    private func grab() -> CapturedFrame? {
        guard let video = player.currentURL, let image = player.mpv.screenshotRaw() else { return nil }
        let time = player.timePos
        return CapturedFrame(
            image: image, video: video, videoTitle: player.title, duration: player.duration, time: time,
            subtitle: player.subtitleText ?? player.transcript.text(at: time))
    }

    private func upload(_ frame: CapturedFrame, image: CGImage) {
        show("📤 正在上傳截圖 \(TimeFormat.clock(frame.time))…", osd: false)
        let previous = queue
        let player = self.player
        queue = Task {
            await previous?.value
            do {
                guard let encoded = await Task.detached(operation: { FrameImage.encode(image) }).value else {
                    throw NotionError.http(status: 413, message: "截圖編碼後超過 20 MB")
                }
                let result = try await NotionClient(token: AppSettings.notionToken).addImage(
                    encoded.data,
                    filename: "screenshot-\(Int(frame.time)).\(encoded.fileExtension)",
                    contentType: encoded.contentType,
                    caption: frame.caption,
                    page: player.record(for: frame.video).notionPageURL,
                    parent: AppSettings.notionParent,
                    newPageTitle: frame.videoTitle,
                    sourceInfo: AIAssistant.sourceInfo(title: frame.videoTitle, duration: frame.duration))
                player.setNotionPage(result.pageURL, for: frame.video, hasNotes: false)
                lastPageURL = result.pageURL
                show("✅ 截圖 \(TimeFormat.clock(frame.time)) 已上傳到 Notion")
            } catch {
                show("⚠️ 截圖上傳失敗：\(error.localizedDescription)", duration: 5000)
            }
        }
    }

    private func show(_ text: String, osd: Bool = true, duration: Int = 2500) {
        status = text
        if osd { player.mpv.showText(text, duration: duration) }
    }
}
