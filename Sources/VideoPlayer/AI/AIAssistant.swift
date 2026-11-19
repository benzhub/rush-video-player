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
    private var agent: StudyAgent?
    private var task: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(player: PlayerModel) {
        self.player = player
        player.fileChanged.sink { [weak self] _ in self?.reset() }.store(in: &cancellables)
        player.finishedEpisode.sink { [weak self] url in self?.autoSaveNotes(for: url) }.store(in: &cancellables)
    }

    var hasAPIKey: Bool { !AppSettings.anthropicAPIKey.isEmpty }
    var hasNotion: Bool { !AppSettings.notionToken.isEmpty && !AppSettings.notionParent.isEmpty }

    /// 最後一則 AI 回覆，用來存到 Notion
    var lastAnswer: String? {
        items.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text
    }

    func reset() {
        task?.cancel()
        task = nil
        agent = nil
        items = []
        isRunning = false
        lastNotionURL = nil
    }

    func stop() {
        task?.cancel()
    }

    func summarize() { send(StudyPrompts.summary, display: "📝 摘要這部影片") }
    func makeNotes() { send(StudyPrompts.notes, display: "📒 整理學習筆記") }

    func submitInput() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        send(text, display: text)
    }

    private func send(_ prompt: String, display: String) {
        guard !isRunning, player.currentURL != nil else { return }
        guard hasAPIKey else {
            items.append(ChatItem(role: .status, text: ClaudeError.missingAPIKey.localizedDescription))
            return
        }
        let agent = self.agent ?? makeAgent()
        self.agent = agent

        // 目前播放時間附在訊息裡（不修改 system prompt，對話歷史只往後加）
        let message = "（目前播放到 \(TimeFormat.clock(player.timePos))）\n\(prompt)"
        items.append(ChatItem(role: .user, text: display))
        let reply = ChatItem(role: .assistant, text: "")
        items.append(reply)
        isRunning = true

        // 串流事件經由 AsyncStream 依序送回主執行緒
        let (events, continuation) = AsyncStream<StudyAgent.Event>.makeStream()
        task = Task { [weak self] in
            let consumer = Task { @MainActor [weak self] in
                for await event in events { self?.apply(event, to: reply.id) }
            }
            do {
                _ = try await agent.send(message) { continuation.yield($0) }
            } catch is CancellationError {
                self?.items.append(ChatItem(role: .status, text: "已停止"))
            } catch let error as URLError where error.code == .cancelled {
                self?.items.append(ChatItem(role: .status, text: "已停止"))
            } catch {
                self?.items.append(ChatItem(role: .status, text: "⚠️ \(error.localizedDescription)"))
            }
            continuation.finish()
            await consumer.value
            self?.isRunning = false
        }
    }

    private func apply(_ event: StudyAgent.Event, to replyID: UUID) {
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
        switch tool {
        case "seek_to": "⏩ 跳到 \(TimeFormat.clock(input["seconds"]?.doubleValue ?? 0))"
        case "get_transcript": "🔎 查詢逐字稿 \(TimeFormat.clock(input["start_seconds"]?.doubleValue ?? 0))–\(TimeFormat.clock(input["end_seconds"]?.doubleValue ?? 0))"
        case "get_bookmarks": "🔖 讀取書籤"
        case "save_note_to_notion": "📤 存到 Notion：\(input["title"]?.stringValue ?? "")"
        default: "🔧 \(tool)"
        }
    }

    // MARK: - Agent

    private func context() -> StudyContext {
        StudyContext(title: player.title, duration: player.duration, transcript: player.transcript, bookmarks: player.bookmarks)
    }

    private func makeAgent() -> StudyAgent {
        StudyAgent(client: AppSettings.claudeClient(), context: context(), tools: tools())
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
        items.append(ChatItem(role: .status, text: "📤 正在存到 Notion…"))
        Task {
            do {
                let url = try await saveToNotion(title: MarkdownToNotion.title(from: markdown) ?? player.title, markdown: markdown)
                items.append(ChatItem(role: .status, text: "✅ 已存到 Notion"))
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
        if let video { player.setNotionPage(url, for: video) }
        lastNotionURL = url
        return url
    }

    private static func sourceInfo(title: String, duration: Double) -> String {
        let date = Date().formatted(date: .abbreviated, time: .shortened)
        return "影片：\(title)（\(TimeFormat.clock(duration))）· 由 Rush Video Player 於 \(date) 產生"
    }

    /// 一集看完時自動產生筆記並存到 Notion（設定中開啟時）
    private func autoSaveNotes(for video: URL) {
        guard AppSettings.autoNotion, hasAPIKey, hasNotion, !player.transcript.isEmpty,
              player.record(for: video).notionPageURL == nil else { return }
        let context = self.context()
        let title = player.title
        let duration = player.duration
        let player = self.player
        Task {
            do {
                let markdown = try await StudyAgent.generateNotes(client: AppSettings.claudeClient(), context: context)
                let url = try await NotionClient(token: AppSettings.notionToken).createPage(
                    parent: AppSettings.notionParent,
                    title: MarkdownToNotion.title(from: markdown) ?? title,
                    markdown: markdown,
                    sourceInfo: Self.sourceInfo(title: title, duration: duration))
                player.setNotionPage(url, for: video)
                player.mpv.showText("📒 「\(title)」的學習筆記已存到 Notion", duration: 4000)
            } catch {
                player.mpv.showText("⚠️ 自動筆記失敗：\(error.localizedDescription)", duration: 5000)
            }
        }
    }
}
