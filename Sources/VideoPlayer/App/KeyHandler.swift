import AppKit

/// 沒有修飾鍵的單鍵快捷鍵（空白鍵、方向鍵…）。輸入框在編輯時不攔截。
@MainActor
enum KeyHandler {
    static func handle(_ event: NSEvent) -> Bool {
        // 只處理播放器視窗（設定視窗等不攔截）
        guard let window = event.window, window === PlayerModel.shared.videoView.window else { return false }
        if window.firstResponder is NSText { return false }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty else { return false }

        let player = PlayerModel.shared
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49: player.togglePause()                                   // 空白鍵
        case 123: player.seek(by: shift ? -60 : -5)                     // ←
        case 124: player.seek(by: shift ? 60 : 5)                       // →
        case 126: player.changeVolume(by: 5)                            // ↑
        case 125: player.changeVolume(by: -5)                           // ↓
        case 53:                                                         // Esc
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } else { return false }
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": window.toggleFullScreen(nil)
            case "n": player.playNext()
            case "p": player.playPrevious()
            case "m": player.toggleMute()
            case "b": player.addBookmark()
            case "[": player.changeSubDelay(by: -0.1)
            case "]": player.changeSubDelay(by: 0.1)
            case "\\": player.changeSubDelay(by: 0)
            case ",": player.seek(by: -1)
            case ".": player.seek(by: 1)
            default: return false
            }
        }
        return true
    }
}

/// 子母畫面：把主視窗縮成右下角置頂的小視窗，可在所有桌面空間顯示
@MainActor
enum FloatingWindow {
    private static var savedFrame: NSRect?

    static var isFloating: Bool { savedFrame != nil }

    static func toggle() {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else { return }
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }

        if let frame = savedFrame {
            window.level = .normal
            window.collectionBehavior.remove(.canJoinAllSpaces)
            window.setFrame(frame, display: true, animate: true)
            savedFrame = nil
        } else {
            savedFrame = window.frame
            AppDelegate.ui.showAI = false
            AppDelegate.ui.showPlaylist = false
            let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            let size = NSSize(width: 480, height: 270)
            let frame = NSRect(x: screen.maxX - size.width - 20, y: screen.minY + 20, width: size.width, height: size.height)
            window.level = .floating
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.setFrame(frame, display: true, animate: true)
        }
    }
}
