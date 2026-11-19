import SwiftUI
import VideoPlayerCore

struct PlaylistSidebar: View {
    @EnvironmentObject var player: PlayerModel
    @ViewState private var tab = Tab.playlist

    enum Tab: String, CaseIterable {
        case playlist = "播放清單"
        case bookmarks = "書籤"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            switch tab {
            case .playlist: playlist
            case .bookmarks: BookmarkList()
            }
        }
        .background(.regularMaterial)
    }

    private var playlist: some View {
        List {
            ForEach(Array(player.playlist.enumerated()), id: \.element) { index, url in
                PlaylistRow(url: url, isCurrent: index == player.currentIndex, record: player.record(for: url))
                    .id("\(url.path)-\(player.recordsVersion)")
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { player.play(at: index) }
                    .contextMenu {
                        Button("播放") { player.play(at: index) }
                        Button("在 Finder 中顯示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("從清單移除") { player.removeFromPlaylist(url) }.disabled(index == player.currentIndex)
                    }
            }
            .onMove { player.movePlaylistItems(from: $0, to: $1) }
        }
        .listStyle(.sidebar)
        .overlay {
            if player.playlist.isEmpty {
                Text("還沒有影片").foregroundStyle(.secondary)
            }
        }
    }
}

struct PlaylistRow: View {
    let url: URL
    let isCurrent: Bool
    let record: MediaRecord

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isCurrent { Image(systemName: "play.fill").foregroundStyle(Color.accentColor) }
                else if record.watched { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                else { Image(systemName: "circle").foregroundStyle(.tertiary) }
            }
            .font(.caption)
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .lineLimit(2)
                    .fontWeight(isCurrent ? .semibold : .regular)
                if !record.watched, record.progress > 0.01 {
                    ProgressView(value: record.progress).controlSize(.mini)
                }
            }
        }
        .padding(.vertical, 2)
        .help(url.lastPathComponent)
    }
}

struct BookmarkList: View {
    @EnvironmentObject var player: PlayerModel

    var body: some View {
        List {
            ForEach(player.bookmarks) { bookmark in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button(TimeFormat.clock(bookmark.time)) { player.seek(to: bookmark.time) }
                            .buttonStyle(.link)
                            .monospacedDigit()
                        Spacer()
                        Button(role: .destructive) { player.deleteBookmark(bookmark) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    if let s = bookmark.subtitle { Text(s).font(.callout).foregroundStyle(.secondary) }
                    TextField("加上筆記…", text: Binding(
                        get: { bookmark.note },
                        set: { var b = bookmark; b.note = $0; player.updateBookmark(b) }))
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if player.bookmarks.isEmpty {
                Text("按 B 在目前時間加書籤").foregroundStyle(.secondary)
            }
        }
    }
}
