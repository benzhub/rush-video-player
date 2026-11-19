import SwiftUI
import VideoPlayerCore

struct ControlBar: View {
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var ui: UIState
    @ViewState private var scrubbing: Double?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(TimeFormat.clock(scrubbing ?? player.timePos)).monospacedDigit()
                Slider(
                    value: Binding(
                        get: { scrubbing ?? player.timePos },
                        set: { scrubbing = $0 }),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        if !editing, let target = scrubbing {
                            player.seek(to: target)
                            scrubbing = nil
                        }
                    })
                    .controlSize(.small)
                Text(TimeFormat.clock(player.duration)).monospacedDigit()
            }
            .font(.caption)

            HStack(spacing: 16) {
                iconButton("backward.end.fill", "上一集 (P)", enabled: player.hasPrevious) { player.playPrevious() }
                iconButton("gobackward.5", "倒轉 5 秒 (←)") { player.seek(by: -5) }
                iconButton(player.paused ? "play.fill" : "pause.fill", "播放／暫停 (空白鍵)", size: 22) { player.togglePause() }
                iconButton("goforward.5", "快轉 5 秒 (→)") { player.seek(by: 5) }
                iconButton("forward.end.fill", "下一集 (N)", enabled: player.hasNext) { player.playNext() }

                HStack(spacing: 6) {
                    iconButton(player.muted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", "靜音 (M)") {
                        player.toggleMute()
                    }
                    Slider(value: Binding(get: { player.volume }, set: { player.setVolume($0) }), in: 0...150)
                        .frame(width: 90).controlSize(.mini)
                }

                Spacer()

                if let text = playlistPosition { Text(text).font(.caption).foregroundStyle(.secondary) }
                SubtitleMenu()
                speedMenu
                iconButton("bookmark", "加書籤 (B)", enabled: player.currentURL != nil) { player.addBookmark() }
                iconButton("list.bullet", "播放清單 (⌘L)", active: ui.showPlaylist) { ui.showPlaylist.toggle() }
                iconButton("sparkles", "AI 學習助手 (⌘J)", active: ui.showAI) { ui.showAI.toggle() }
                iconButton("arrow.up.left.and.arrow.down.right", "全螢幕 (F)") { NSApp.keyWindow?.toggleFullScreen(nil) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false))
        .disabled(player.currentURL == nil)
    }

    private var playlistPosition: String? {
        guard let i = player.currentIndex, player.playlist.count > 1 else { return nil }
        return "\(i + 1) / \(player.playlist.count)"
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3], id: \.self) { s in
                Button {
                    player.setSpeed(s)
                } label: {
                    if abs(player.speed - s) < 0.01 { Label("\(s.formatted())x", systemImage: "checkmark") }
                    else { Text("\(s.formatted())x") }
                }
            }
        } label: {
            Text("\(player.speed.formatted(.number.precision(.fractionLength(0...2))))x")
                .font(.caption.monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("播放速度 (⌘[ / ⌘])")
    }

    private func iconButton(_ symbol: String, _ help: String, size: CGFloat = 15, enabled: Bool = true,
                            active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : .white)
                .frame(minWidth: 22, minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }
}

struct SubtitleMenu: View {
    @EnvironmentObject var player: PlayerModel

    var body: some View {
        Menu {
            Button {
                player.selectSubtitle(nil)
            } label: {
                if !player.subtitleTracks.contains(where: \.selected) { Label("關閉字幕", systemImage: "checkmark") }
                else { Text("關閉字幕") }
            }
            Divider()
            ForEach(player.subtitleTracks) { track in
                Button {
                    player.selectSubtitle(track)
                } label: {
                    if track.selected { Label(track.displayName, systemImage: "checkmark") }
                    else { Text(track.displayName) }
                }
            }
            Divider()
            Button("載入字幕檔…") { player.showSubtitleOpenPanel() }
            Button("字幕提早 0.1 秒 ([)") { player.changeSubDelay(by: -0.1) }
            Button("字幕延後 0.1 秒 (])") { player.changeSubDelay(by: 0.1) }
            Button("重設字幕延遲 (\\)") { player.changeSubDelay(by: 0) }
            if player.audioTracks.count > 1 {
                Divider()
                Text("音軌")
                ForEach(player.audioTracks) { track in
                    Button {
                        player.selectAudio(track)
                    } label: {
                        if track.selected { Label(track.displayName, systemImage: "checkmark") }
                        else { Text(track.displayName) }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("字幕與音軌")
    }
}
