import SwiftUI
import UniformTypeIdentifiers
import VideoPlayerCore

final class UIState: ObservableObject {
    @Published var showPlaylist = false
    @Published var showAI = false
    @Published var controlsVisible = true
}

struct ContentView: View {
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var assistant: AIAssistant
    @EnvironmentObject var screenshots: NotionScreenshots
    @State private var hideTask: Task<Void, Never>?
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            playerArea
            if ui.showPlaylist {
                Divider()
                PlaylistSidebar().frame(width: 300)
            }
            if ui.showAI {
                Divider()
                AIPanel().frame(width: 380)
            }
        }
        .background(Color.black)
        .navigationTitle(player.title)
        .frame(minWidth: 640, minHeight: 360)
        .sheet(item: $screenshots.annotating, onDismiss: screenshots.annotationClosed) { frame in
            AnnotationView(
                frame: frame,
                onUpload: { strokes, width in screenshots.finishAnnotation(strokes: strokes, lineWidth: width) },
                onCancel: { screenshots.annotating = nil })
        }
    }

    private var playerArea: some View {
        ZStack {
            Color.black
            VideoSurface(view: player.videoView)
            if player.currentURL == nil { emptyState }
            if player.buffering { ProgressView().controlSize(.large) }
            VStack {
                if let countdown = player.nextCountdown { NextUpCard(seconds: countdown).padding(16) }
                Spacer()
                if ui.controlsVisible || player.paused || player.currentURL == nil {
                    ControlBar().transition(.opacity)
                }
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 3).padding(8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
        .onContinuousHover { phase in
            if case .active = phase { pokeControls() }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let fileURL = URL(dataRepresentation: url, relativeTo: nil) {
                        urls.append(fileURL)
                    }
                }
                handleDrop(urls)
            }
            return true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 56, weight: .light))
            Text("拖曳影片或資料夾到這裡").font(.title3)
            Button("開啟檔案… (⌘O)") { player.showOpenPanel() }
            Text("同資料夾的字幕會自動載入，影片會自動排成播放清單")
                .font(.caption).foregroundStyle(.secondary)
        }
        .foregroundStyle(.white.opacity(0.85))
    }

    /// 拖入字幕檔就載入字幕，拖入影片就開啟
    private func handleDrop(_ urls: [URL]) {
        let subtitles = urls.filter(MediaTypes.isSubtitle)
        let others = urls.filter { !MediaTypes.isSubtitle($0) }
        if !others.isEmpty { player.open(others) }
        subtitles.forEach(player.addExternalSubtitle)
    }

    /// 滑鼠移動時顯示控制列，停止 2.5 秒後隱藏（連同游標）
    private func pokeControls() {
        if !ui.controlsVisible { withAnimation(.easeOut(duration: 0.15)) { ui.controlsVisible = true } }
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, !player.paused else { return }
            withAnimation(.easeIn(duration: 0.3)) { ui.controlsVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

struct NextUpCard: View {
    @EnvironmentObject var player: PlayerModel
    let seconds: Int

    var body: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text("\(seconds) 秒後播放下一集").font(.caption).foregroundStyle(.secondary)
                if let i = player.currentIndex, player.playlist.indices.contains(i + 1) {
                    Text(player.playlist[i + 1].deletingPathExtension().lastPathComponent)
                        .font(.headline).lineLimit(2)
                }
                HStack {
                    Button("立即播放") { player.playNext() }.keyboardShortcut(.defaultAction)
                    Button("取消") { player.nextCancelled = true }
                }
            }
            .padding(14)
            .frame(maxWidth: 300, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
