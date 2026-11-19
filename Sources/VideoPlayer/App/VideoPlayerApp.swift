import AppKit
import SwiftUI
import VideoPlayerCore

@main
struct VideoPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var player = PlayerModel.shared
    @StateObject private var ui = AppDelegate.ui
    @StateObject private var assistant = AppDelegate.assistant
    @StateObject private var screenshots = AppDelegate.screenshots

    var body: some Scene {
        Window("Rush Video Player", id: "main") {
            ContentView()
                .environmentObject(player)
                .environmentObject(ui)
                .environmentObject(assistant)
                .environmentObject(screenshots)
        }
        .defaultSize(width: 1100, height: 660)
        .commands { PlayerCommands(player: player, ui: ui, screenshots: screenshots) }

        Settings {
            SettingsView()
        }
    }
}

struct PlayerCommands: Commands {
    @ObservedObject var player: PlayerModel
    @ObservedObject var ui: UIState
    @ObservedObject var screenshots: NotionScreenshots

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("開啟…") { player.showOpenPanel() }.keyboardShortcut("o")
            Button("加入播放清單…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = true
                if panel.runModal() == .OK { player.appendToPlaylist(panel.urls) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandMenu("播放") {
            Button(player.paused ? "播放" : "暫停") { player.togglePause() }
            Button("下一集") { player.playNext() }.disabled(!player.hasNext)
            Button("上一集") { player.playPrevious() }.disabled(!player.hasPrevious)
            Divider()
            Button("加快速度") { player.changeSpeed(by: 0.25) }.keyboardShortcut("]")
            Button("減慢速度") { player.changeSpeed(by: -0.25) }.keyboardShortcut("[")
            Button("正常速度") { player.setSpeed(1) }.keyboardShortcut("0")
            Divider()
            Button("加書籤") { player.addBookmark() }
            Button("截圖到 Notion") { screenshots.capture(annotate: false) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(player.currentURL == nil)
            Button("截圖並標註後上傳…") { screenshots.capture(annotate: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift, .option])
                .disabled(player.currentURL == nil)
            Divider()
            Button(FloatingWindow.isFloating ? "結束子母畫面" : "子母畫面（浮動小視窗）") { FloatingWindow.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
        }
        CommandMenu("字幕") {
            Button("開啟／關閉字幕 (S)") { player.toggleSubtitles() }
                .disabled(player.subtitleTracks.isEmpty)
            Divider()
            Toggle("關閉字幕", isOn: Binding(
                get: { !player.subtitleTracks.contains(where: \.selected) },
                set: { if $0 { player.selectSubtitle(nil) } }))
            ForEach(player.subtitleTracks) { track in
                Toggle(track.displayName, isOn: Binding(
                    get: { track.selected },
                    set: { if $0 { player.selectSubtitle(track) } }))
            }
            Divider()
            Button("載入字幕檔…") { player.showSubtitleOpenPanel() }
            Divider()
            Button("放大字幕") { player.changeSubScale(by: 0.1) }.keyboardShortcut("=")
            Button("縮小字幕") { player.changeSubScale(by: -0.1) }.keyboardShortcut("-")
        }
        CommandGroup(before: .sidebar) {
            Button(ui.showPlaylist ? "隱藏播放清單" : "顯示播放清單") { ui.showPlaylist.toggle() }.keyboardShortcut("l")
            Button(ui.showAI ? "隱藏 AI 學習助手" : "顯示 AI 學習助手") { ui.showAI.toggle() }.keyboardShortcut("j")
            Divider()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static let ui = UIState()
    @MainActor static let assistant = AIAssistant(player: PlayerModel.shared)
    @MainActor static let screenshots = NotionScreenshots(player: PlayerModel.shared)

    private var keyMonitor: Any?
    /// App 還沒準備好時收到的檔案（從 Finder 開啟）
    private var pendingURLs: [URL] = []
    private var launched = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppSettings.register()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        // 預先讀取登入 shell 的 PATH（找 claude / codex 指令用），避免第一次使用時卡住介面
        Task.detached { _ = ShellEnvironment.loginPATH }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 本地事件監聽一定在主執行緒呼叫
            nonisolated(unsafe) let event = event
            return MainActor.assumeIsolated { KeyHandler.handle(event) } ? nil : event
        }
        // 命令列參數：swift run VideoPlayer /path/to/video.mkv
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
        let urls = pendingURLs + args.filter { FileManager.default.fileExists(atPath: $0.path) }
        pendingURLs = []
        if !urls.isEmpty {
            MainActor.assumeIsolated { PlayerModel.shared.open(urls) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else { pendingURLs += urls; return }
        MainActor.assumeIsolated { PlayerModel.shared.open(urls) }
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { PlayerModel.shared.shutdown() }
    }
}
