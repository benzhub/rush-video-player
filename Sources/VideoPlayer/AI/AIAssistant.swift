import AppKit
import Combine
import VideoPlayerCore

struct ChatItem: Identifiable, Equatable {
    enum Role { case user, assistant, status }
    let id = UUID()
    var role: Role
    var text: String
}

/// AI 學習助手：摘要、學習筆記、問答，並可存到 Notion
@MainActor
final class AIAssistant: ObservableObject {
    @Published private(set) var items: [ChatItem] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastNotionURL: String?
    @Published var input = ""

    private let player: PlayerModel
    private var session: StudySession?
    /// 目前對話使用的來源與語言；設定改變後下一則訊息會開新對話
    private var sessionProvider: AIProviderKind?
    private var sessionLanguage: AILanguage?
    private var task: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(player: PlayerModel) {
        self.player = player
        player.fileChanged.sink { [weak self] _ in self?.reset() }.store(in: &cancellables)
        player.finishedEpisode.sink { [weak self] url in self?.autoSaveNotes(for: url) }.store(in: &cancellables)
    }

    var provider: AIProviderKind { AppSettings.aiProvider }
    var isConfigured: Bool { AppSettings.isAvailable(provider) }
    var hasNotion: Bool { AppSettings.hasNotion }

    /// 最後一則 AI 回覆，用來存到 Notion
    var lastAnswer: String? {
        items.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text
    }

    func reset() {
        task?.cancel()
        task = nil
        session = nil
        sessionProvider = nil
        sessionLanguage = nil
        items = []
        isRunning = false
        lastNotionURL = nil
    }

    func stop() {
        task?.cancel()
    }

    var language: AILanguage { AppSettings.aiLanguage }

    func summarize() { send(StudyPrompts.summary(language), display: language.pick("📝 摘要這部影片", "📝 Summarize this video")) }
    func makeNotes() { send(StudyPrompts.notes(language), display: language.pick("📒 整理學習筆記", "📒 Make study notes")) }

    func submitInput() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        send(text, display: text)
    }

    private func send(_ prompt: String, display: String) {
        guard !isRunning, player.currentURL != nil else { return }
        let provider = self.provider
        let language = self.language
        guard AppSettings.isAvailable(provider) else {
            items.append(ChatItem(role: .status, text: "⚠️ \(Self.setupHint(for: provider))"))
            return
        }
        if sessionProvider != provider || sessionLanguage != language {
            if session != nil {
                items.append(ChatItem(role: .status, text: sessionProvider != provider
                    ? language.pick("已切換到 \(provider.shortName)，開始新對話", "Switched to \(provider.shortName); starting a new conversation")
                    : language.pick("已切換回覆語言，開始新對話", "Reply language changed; starting a new conversation")))
            }
            session = AppSettings.makeSession(context: context(), tools: tools())
            sessionProvider = provider
            sessionLanguage = language
        }
        guard let session else { return }

        // 目前播放時間附在訊息裡（不修改 system prompt，對話歷史只往後加）
        let message = StudyPrompts.playbackPosition(player.timePos, language: language) + "\n\(prompt)"
        items.append(ChatItem(role: .user, text: display))
        let reply = ChatItem(role: .assistant, text: "")
        items.append(reply)
        isRunning = true

        // 串流事件經由 AsyncStream 依序送回主執行緒
        let (events, continuation) = AsyncStream<AIEvent>.makeStream()
        task = Task { [weak self] in
            let consumer = Task { @MainActor [weak self] in
                for await event in events { self?.apply(event, to: reply.id) }
            }
            do {
                let text = try await session.send(message) { continuation.yield($0) }
                continuation.finish()
                await consumer.value
                if !session.supportsTools { self?.applySeekDirective(in: text, replyID: reply.id) }
            } catch is CancellationError {
                self?.items.append(ChatItem(role: .status, text: language.pick("已停止", "Stopped")))
            } catch let error as URLError where error.code == .cancelled {
                self?.items.append(ChatItem(role: .status, text: language.pick("已停止", "Stopped")))
            } catch {
                self?.items.append(ChatItem(role: .status, text: "⚠️ \(error.localizedDescription)"))
            }
            continuation.finish()
            await consumer.value
            self?.isRunning = false
        }
    }

    /// CLI 來源用 `<seek>秒數</seek>` 要求跳轉：去掉指令並執行
    private func applySeekDirective(in text: String, replyID: UUID) {
        let (cleaned, seconds) = SeekDirective.extract(text)
        if let index = items.firstIndex(where: { $0.id == replyID }) { items[index].text = cleaned }
        if let seconds {
            player.seek(to: seconds)
            items.append(ChatItem(role: .status, text: language.pick("⏩ 跳到 ", "⏩ Jumped to ") + TimeFormat.clock(seconds)))
        }
    }

    static func setupHint(for provider: AIProviderKind) -> String {
        let l = AppSettings.aiLanguage
        return switch provider {
        case .claudeCLI: l.pick(
            "找不到 claude 指令。請安裝 Claude Code 並在終端機執行 claude 登入，或到「設定 → AI」換一個來源。",
            "The claude command was not found. Install Claude Code and run claude in Terminal to sign in, or pick another source in Settings → AI.")
        case .codexCLI: l.pick(
            "找不到 codex 指令。請安裝 Codex CLI 並在終端機執行 codex 登入，或到「設定 → AI」換一個來源。",
            "The codex command was not found. Install Codex CLI and run codex in Terminal to sign in, or pick another source in Settings → AI.")
        case .anthropicAPI: l.pick(ClaudeError.missingAPIKey.localizedDescription,
                                   "No Anthropic API key yet. Enter one in Settings → AI.")
        case .openAIAPI: l.pick(OpenAIError.missingAPIKey.localizedDescription,
                                "No OpenAI API key yet. Enter one in Settings → AI.")
        }
    }

    private func apply(_ event: AIEvent, to replyID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == replyID }) else { return }
        switch event {
        case .text(let delta):
            items[index].text += delta
        case .toolCall(let name, let input):
            // 工具呼叫顯示在回覆上方
            items.insert(ChatItem(role: .status, text: Self.describe(tool: name, input: input)), at: index)
        }
    }

    private static func describe(tool: String, input: JSONValue) -> String {
        let l = AppSettings.aiLanguage
        return switch tool {
        case "seek_to": l.pick("⏩ 跳到 ", "⏩ Jumped to ") + TimeFormat.clock(input["seconds"]?.doubleValue ?? 0)
        case "get_transcript": l.pick("🔎 查詢逐字稿 ", "🔎 Reading transcript ")
            + "\(TimeFormat.clock(input["start_seconds"]?.doubleValue ?? 0))–\(TimeFormat.clock(input["end_seconds"]?.doubleValue ?? 0))"
        case "get_bookmarks": l.pick("🔖 讀取書籤", "🔖 Reading bookmarks")
        case "save_note_to_notion": l.pick("📤 存到 Notion：", "📤 Saving to Notion: ") + (input["title"]?.stringValue ?? "")
        default: "🔧 \(tool)"
        }
    }

    // MARK: - Agent

    private func context() -> StudyContext {
        StudyContext(title: player.title, duration: player.duration, transcript: player.transcript, bookmarks: player.bookmarks,
                     language: language)
    }

    private func tools() -> [AgentTool] {
        let player = self.player
        return [
            AgentTool(
                name: "get_transcript",
                description: "取得指定時間範圍內的最新逐字稿。逐字稿是播放時累積的話，這裡可能比 system prompt 裡的更完整。",
                schema: [
                    "type": "object",
                    "properties": [
                        "start_seconds": ["type": "number", "description": "開始時間（秒）"],
                        "end_seconds": ["type": "number", "description": "結束時間（秒）"],
                    ],
                    "required": ["start_seconds", "end_seconds"],
                ],
                run: { input in
                    let start = input["start_seconds"]?.doubleValue ?? 0
                    let end = input["end_seconds"]?.doubleValue ?? 0
                    let text = await MainActor.run { player.transcript.formatted(from: start, to: end) }
                    return text.isEmpty ? "這個時間範圍沒有逐字稿。" : text
                }),
            AgentTool(
                name: "seek_to",
                description: "把影片跳到指定時間。使用者想回到、重看或找到某段內容時使用。",
                schema: [
                    "type": "object",
                    "properties": ["seconds": ["type": "number", "description": "要跳到的時間（秒）"]],
                    "required": ["seconds"],
                ],
                run: { input in
                    let seconds = input["seconds"]?.doubleValue ?? 0
                    await MainActor.run { player.seek(to: seconds) }
                    return "已跳到 \(TimeFormat.clock(seconds))"
                }),
            AgentTool(
                name: "get_bookmarks",
                description: "取得使用者在這部影片加的時間點書籤（使用者覺得重要的地方）。",
                schema: ["type": "object", "properties": [:]],
                run: { _ in
                    let marks = await MainActor.run { player.bookmarks }
                    guard !marks.isEmpty else { return "沒有書籤。" }
                    return marks.map { b in
                        "[\(TimeFormat.clock(b.time))] \(b.subtitle ?? "")\(b.note.isEmpty ? "" : "（筆記：\(b.note)）")"
                    }.joined(separator: "\n")
                }),
            AgentTool(
                name: "save_note_to_notion",
                description: "把整理好的 Markdown 筆記存成一個新的 Notion 頁面。只有使用者要求存到 Notion 時才使用。",
                schema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "頁面標題"],
                        "markdown": ["type": "string", "description": "筆記內容（Markdown）"],
                    ],
                    "required": ["title", "markdown"],
                ],
                run: { [weak self] input in
                    guard let self else { return "助手已關閉" }
                    let url = try await self.saveToNotion(
                        title: input["title"]?.stringValue ?? "",
                        markdown: input["markdown"]?.stringValue ?? "")
                    return "已建立 Notion 頁面：\(url)"
                }),
        ]
    }

    // MARK: - Notion

    /// 把最後一則 AI 回覆存到 Notion
    func saveLastAnswerToNotion() {
        guard let markdown = lastAnswer, !isRunning else { return }
        isRunning = true
        items.append(ChatItem(role: .status, text: language.pick("📤 正在存到 Notion…", "📤 Saving to Notion…")))
        Task {
            do {
                let url = try await saveToNotion(title: MarkdownToNotion.title(from: markdown) ?? player.title, markdown: markdown)
                items.append(ChatItem(role: .status, text: language.pick("✅ 已存到 Notion", "✅ Saved to Notion")))
                lastNotionURL = url
            } catch {
                items.append(ChatItem(role: .status, text: "⚠️ \(error.localizedDescription)"))
            }
            isRunning = false
        }
    }

    private func saveToNotion(title: String, markdown: String) async throws -> String {
        let video = player.currentURL
        let client = NotionClient(token: AppSettings.notionToken)
        let url = try await client.createPage(
            parent: AppSettings.notionParent,
            title: title.isEmpty ? player.title : title,
            markdown: markdown,
            sourceInfo: Self.sourceInfo(title: player.title, duration: player.duration))
        if let video { player.setNotionPage(url, for: video, hasNotes: true) }
        lastNotionURL = url
        return url
    }

    static func sourceInfo(title: String, duration: Double) -> String {
        let date = Date().formatted(date: .abbreviated, time: .shortened)
        return AppSettings.aiLanguage.pick(
            "影片：\(title)（\(TimeFormat.clock(duration))）· 由 Rush Video Player 於 \(date) 產生",
            "Video: \(title) (\(TimeFormat.clock(duration))) · Generated by Rush Video Player on \(date)")
    }

    /// 一集看完時自動產生筆記並存到 Notion（設定中開啟時）。
    /// 已經有截圖頁面時，筆記附加在同一頁後面。
    private func autoSaveNotes(for video: URL) {
        let record = player.record(for: video)
        guard AppSettings.autoNotion, isConfigured, hasNotion, !player.transcript.isEmpty, !record.hasNotionNotes else { return }
        let context = self.context()
        let title = player.title
        let duration = player.duration
        let player = self.player
        Task {
            do {
                // 用一段全新的對話產生筆記，不影響面板上的對話
                let markdown = try await AppSettings.makeSession(context: context, tools: []).send(StudyPrompts.notes(context.language)) { _ in }
                let client = NotionClient(token: AppSettings.notionToken)
                let info = Self.sourceInfo(title: title, duration: duration)
                let blocks = NotionClient.noteBlocks(markdown: markdown, sourceInfo: info, dropTitle: false)
                let url: String
                if let page = record.notionPageURL, try await client.appendIfPresent(blocks, to: page) {
                    url = page
                } else {
                    url = try await client.createPage(
                        parent: AppSettings.notionParent,
                        title: MarkdownToNotion.title(from: markdown) ?? title,
                        markdown: markdown,
                        sourceInfo: info)
                }
                player.setNotionPage(url, for: video, hasNotes: true)
                player.mpv.showText(context.language.pick("📒 「\(title)」的學習筆記已存到 Notion", "📒 Study notes for \"\(title)\" saved to Notion"), duration: 4000)
            } catch {
                player.mpv.showText(context.language.pick("⚠️ 自動筆記失敗：", "⚠️ Auto notes failed: ") + error.localizedDescription, duration: 5000)
            }
        }
    }
}
