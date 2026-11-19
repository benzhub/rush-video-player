import SwiftUI
import VideoPlayerCore

struct AIPanel: View {
    @EnvironmentObject var assistant: AIAssistant
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var screenshots: NotionScreenshots
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !assistant.isConfigured {
                setupPrompt
            } else {
                conversation
                Divider()
                inputBar
            }
        }
        .background(.regularMaterial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("AI 學習助手", systemImage: "sparkles").font(.headline)
                Spacer()
                Button(assistant.provider.shortName) { openSettings() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("AI 來源（到設定中切換）")
                Button { assistant.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help("開始新對話")
                    .disabled(assistant.items.isEmpty)
            }
            Text(transcriptStatus).font(.caption).foregroundStyle(.secondary)
            HStack {
                HStack {
                    Button("摘要") { assistant.summarize() }
                    Button("學習筆記") { assistant.makeNotes() }
                    Button("存到 Notion") { assistant.saveLastAnswerToNotion() }
                        .disabled(assistant.lastAnswer == nil || !assistant.hasNotion)
                        .help(assistant.hasNotion ? "把最後一則回覆存成 Notion 頁面" : "請先到設定填入 Notion Token 和頁面")
                }
                .disabled(assistant.isRunning || player.currentURL == nil)
                // 截圖不受 AI 是否在回覆中影響
                screenshotButton
            }
            .controlSize(.small)
            if player.currentURL != nil, !assistant.hasNotion {
                HStack(spacing: 4) {
                    Text("截圖、存到 Notion 需要先設定 Notion Token 和筆記頁面")
                    Button("開啟設定") { openSettings() }.buttonStyle(.link)
                }
                .font(.caption).foregroundStyle(.secondary)
            } else if let status = screenshots.status {
                HStack(spacing: 6) {
                    Text(status)
                    if let url = screenshots.lastPageURL, let link = URL(string: url) {
                        Link("開啟頁面 ↗", destination: link)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    /// 分割按鈕：主按鈕直接上傳，選單選「標註後上傳」
    private var screenshotButton: some View {
        Menu {
            Button("標註後上傳…") { screenshots.capture(annotate: true) }
        } label: {
            Label("截圖", systemImage: "camera")
        } primaryAction: {
            screenshots.capture(annotate: false)
        }
        .fixedSize()
        .disabled(!screenshots.canCapture)
        .help(assistant.hasNotion ? "截圖到 Notion（⇧⌘S）；選單可先用紅筆標註" : "請先到設定填入 Notion Token 和頁面")
    }

    private var transcriptStatus: String {
        let t = player.transcript
        if player.currentURL == nil { return "開啟影片後即可使用" }
        if t.isEmpty { return "⚠️ 目前沒有逐字稿（需要字幕）。內嵌字幕會在播放時逐步累積。" }
        switch t.source {
        case .file(let url): return "逐字稿：\(url.lastPathComponent)（\(t.cues.count) 句）"
        case .accumulated: return "逐字稿：播放時累積（目前 \(t.cues.count) 句）"
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if assistant.items.isEmpty {
                        Text("試試：\n• 這集在講什麼？\n• 帶我回到講 XXX 的地方\n• 解釋一下剛剛那段\n• 整理成筆記並存到 Notion")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(assistant.items) { item in
                        ChatBubble(item: item).id(item.id)
                    }
                    if assistant.isRunning { ProgressView().controlSize(.small) }
                    if let url = assistant.lastNotionURL, let link = URL(string: url) {
                        Link("在 Notion 開啟 ↗", destination: link).font(.callout)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
                .textSelection(.enabled)
            }
            .onChange(of: assistant.items) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            // 回覆中的時間戳可以點擊跳轉
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == MarkdownText.seekScheme, let seconds = Double(url.host() ?? "") else { return .systemAction }
                player.seek(to: seconds)
                return .handled
            })
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom) {
            TextField("問問題…", text: $assistant.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .onSubmit { assistant.submitInput() }
            if assistant.isRunning {
                Button { assistant.stop() } label: { Image(systemName: "stop.circle.fill") }
                    .buttonStyle(.borderless).help("停止")
            } else {
                Button { assistant.submitInput() } label: { Image(systemName: "arrow.up.circle.fill") }
                    .buttonStyle(.borderless)
                    .disabled(assistant.input.trimmingCharacters(in: .whitespaces).isEmpty || player.currentURL == nil)
            }
        }
        .font(.title3)
        .padding(10)
    }

    private var setupPrompt: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "key").font(.largeTitle)
            Text("請先設定 AI 來源").font(.headline)
            Text(AIAssistant.setupHint(for: assistant.provider))
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
            Text("可以使用 Claude CLI、Codex CLI（沿用訂閱登入），或 Anthropic／OpenAI API Key。")
                .multilineTextAlignment(.center).font(.caption).foregroundStyle(.secondary)
            Button("開啟設定") { openSettings() }
            Spacer()
        }
        .padding(20)
    }
}

struct ChatBubble: View {
    let item: ChatItem

    var body: some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text)
                    .padding(8)
                    .background(Color.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }
        case .assistant:
            MarkdownText(item.text)
        case .status:
            Text(item.text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 簡易 Markdown 呈現：標題、條列、行內格式
struct MarkdownText: View {
    let lines: [String]

    static let seekScheme = "rvp-seek"

    init(_ text: String) {
        lines = SeekDirective.stripForDisplay(text).components(separatedBy: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
    }

    @ViewBuilder
    private func row(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            Spacer().frame(height: 2)
        } else if line.hasPrefix("### ") {
            inline(String(line.dropFirst(4))).font(.subheadline.bold())
        } else if line.hasPrefix("## ") {
            inline(String(line.dropFirst(3))).font(.headline).padding(.top, 4)
        } else if line.hasPrefix("# ") {
            inline(String(line.dropFirst(2))).font(.title3.bold()).padding(.top, 4)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                inline(String(line.dropFirst(2)))
            }
            .padding(.leading, raw.prefix(while: { $0 == " " }).count >= 2 ? 14 : 0)
        } else if line == "---" {
            Divider()
        } else {
            inline(line)
        }
    }

    private func inline(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let linked = Self.linkTimestamps(s)
        return Text((try? AttributedString(markdown: linked, options: options)) ?? AttributedString(s))
    }

    /// `[1:23]`、`[1:02:03]` → 可點擊的跳轉連結
    static func linkTimestamps(_ s: String) -> String {
        s.replacing(#/\[(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\](?!\()/#) { m in
            let h = m.1.flatMap { Double($0) } ?? 0
            let seconds = h * 3600 + (Double(m.2) ?? 0) * 60 + (Double(m.3) ?? 0)
            return "[\(m.0.dropFirst().dropLast())](\(seekScheme)://\(Int(seconds)))"
        }
    }
}
