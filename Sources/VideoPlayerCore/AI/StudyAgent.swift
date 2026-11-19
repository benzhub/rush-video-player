import Foundation

/// Agent 可以呼叫的工具；`run` 由 App 提供（例如跳轉播放時間）
public struct AgentTool: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema（input_schema）
    public let schema: JSONValue
    public let run: @Sendable (JSONValue) async throws -> String

    public init(name: String, description: String, schema: JSONValue, run: @escaping @Sendable (JSONValue) async throws -> String) {
        self.name = name
        self.description = description
        self.schema = schema
        self.run = run
    }

    var definition: JSONValue {
        [
            "name": .string(name),
            "description": .string(description),
            "input_schema": schema,
            // 串流時工具輸入逐步送出；伺服器不驗證，由 validate(_:) 自行檢查
            "eager_input_streaming": true,
        ]
    }

    /// 檢查必要欄位存在且型別正確
    func validate(_ input: JSONValue) -> String? {
        guard let object = input.objectValue else { return "輸入必須是 JSON 物件" }
        let properties = schema["properties"]?.objectValue ?? [:]
        for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[key] == nil {
            return "缺少必要欄位 \(key)"
        }
        for (key, value) in object {
            switch (properties[key]?["type"]?.stringValue, value) {
            case ("number", .number), ("string", .string), (nil, _), ("object", .object), ("array", .array): continue
            case ("number", _), ("string", _), ("object", _), ("array", _): return "欄位 \(key) 型別錯誤"
            default: continue
            }
        }
        return nil
    }
}

/// AI 回覆與 AI 面板使用的語言
public enum AILanguage: String, CaseIterable, Codable, Sendable {
    case traditionalChinese = "zh-Hant"
    case english = "en"

    public var displayName: String {
        switch self {
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        }
    }

    /// 依語言挑選文字
    public func pick(_ chinese: String, _ english: String) -> String {
        self == .english ? english : chinese
    }
}

/// 影片的學習情境：Agent 的 system prompt 由此產生
public struct StudyContext: Sendable {
    public var title: String
    public var duration: Double
    public var transcript: Transcript
    public var bookmarks: [Bookmark]
    public var language: AILanguage

    public init(title: String, duration: Double, transcript: Transcript, bookmarks: [Bookmark],
                language: AILanguage = .traditionalChinese) {
        self.title = title
        self.duration = duration
        self.transcript = transcript
        self.bookmarks = bookmarks
        self.language = language
    }

    var transcriptNote: String {
        switch transcript.source {
        case .file: language.pick("以下是完整逐字稿（來自字幕檔）。", "Below is the full transcript (from a subtitle file).")
        case .accumulated: language.pick(
            "以下逐字稿只包含使用者已經播放過的片段（來自影片內嵌字幕），之後的內容還不知道。",
            "The transcript below only covers the parts the user has already played (from embedded subtitles); later content is not known yet.")
        }
    }

    var bookmarksText: String {
        bookmarks.isEmpty ? language.pick("（沒有書籤）", "(no bookmarks)") : bookmarks.sorted { $0.time < $1.time }.map { b in
            var line = "[\(TimeFormat.clock(b.time))]"
            if let s = b.subtitle, !s.isEmpty { line += language.pick(" 字幕：「\(s)」", " Subtitle: \"\(s)\"") }
            if !b.note.isEmpty { line += language.pick(" 筆記：\(b.note)", " Note: \(b.note)") }
            return line
        }.joined(separator: "\n")
    }
}

public enum StudyPrompts {
    static func baseInstructions(_ language: AILanguage) -> String {
        switch language {
        case .traditionalChinese: """
            你是內建在影片播放器裡的學習助手。使用者正在看一部影片（課程、演講、教學或影集），想用你加速理解與整理內容。

            - 一律使用繁體中文（台灣用語）回答，專有名詞可以附上原文。
            - 回答要根據逐字稿；逐字稿沒有提到的內容，請明確說是你的補充，不要假裝影片有講。
            - 提到影片內容時附上時間戳，格式為 [m:ss] 或 [h:mm:ss]，方便使用者跳轉。
            - 使用 Markdown：標題、條列、粗體。不要用表格（側邊欄很窄）。
            """
        case .english: """
            You are a study assistant built into a video player. The user is watching a video (a course, talk, tutorial or show) and wants your help to understand and organize its content faster.

            - Always answer in English, even if the transcript or the user's message is in another language.
            - Base your answers on the transcript; if something is not in the transcript, say clearly that it is your own addition instead of pretending the video said it.
            - When you refer to the video, include timestamps in the form [m:ss] or [h:mm:ss] so the user can jump there.
            - Use Markdown: headings, bullet lists, bold. Do not use tables (the sidebar is narrow).
            """
        }
    }

    static func toolInstructions(_ language: AILanguage) -> String {
        switch language {
        case .traditionalChinese: """
            - 使用者想回到某段內容時，用 seek_to 工具直接跳過去。
            - 只有在使用者要求時，才用 save_note_to_notion 存到 Notion。
            """
        case .english: """
            - When the user wants to go back to some part of the video, use the seek_to tool to jump there.
            - Only use save_note_to_notion when the user asks to save to Notion.
            """
        }
    }

    /// CLI 來源沒有 App 工具，跳轉改用文字指令，由 App 解析執行
    static func directiveInstructions(_ language: AILanguage) -> String {
        switch language {
        case .traditionalChinese: """
            - 你沒有任何工具，也不要讀寫檔案或執行指令，只根據下面的逐字稿回答。
            - 使用者想回到、重看或找到某段內容時，在回覆最後單獨一行輸出 <seek>秒數</seek>（例如 <seek>95</seek>），播放器會自動跳過去。
            - 使用者要存到 Notion 時，請他按面板上的「存到 Notion」按鈕。
            """
        case .english: """
            - You have no tools. Do not read or write files or run commands; answer only from the transcript below.
            - When the user wants to go back to, rewatch or find some part of the video, output <seek>seconds</seek> on its own line at the end of your reply (e.g. <seek>95</seek>) and the player will jump there.
            - When the user wants to save to Notion, ask them to press the "Save to Notion" button in the panel.
            """
        }
    }

    public static func instructions(withTools: Bool, language: AILanguage = .traditionalChinese) -> String {
        baseInstructions(language) + (withTools ? toolInstructions(language) : directiveInstructions(language))
    }

    public static func summary(_ language: AILanguage) -> String {
        switch language {
        case .traditionalChinese: """
            請幫我摘要這部影片：
            1. 一段話的整體摘要
            2. 依時間順序的章節重點（每節附開始時間戳）
            3. 重要名詞解釋
            """
        case .english: """
            Please summarize this video:
            1. A one-paragraph overall summary
            2. Key points by section in chronological order (each with its start timestamp)
            3. Explanations of important terms
            """
        }
    }

    public static func notes(_ language: AILanguage) -> String {
        switch language {
        case .traditionalChinese: """
            請把這部影片整理成一份可以長期保存的學習筆記（Markdown）。結構如下：
            # 標題（用影片主題，不要用檔名）
            ## 摘要
            ## 重點筆記（依章節，附時間戳）
            ## 關鍵名詞
            ## 我的書籤（如果有書籤，說明每個書籤時間點在講什麼、為什麼重要）
            ## 複習問題（3–5 題，附簡短答案）
            只輸出筆記本身，不要加開場白或結語。
            """
        case .english: """
            Please turn this video into study notes worth keeping (Markdown), in English, with this structure:
            # Title (the topic of the video, not the file name)
            ## Summary
            ## Key Notes (by section, with timestamps)
            ## Key Terms
            ## My Bookmarks (if there are bookmarks, explain what each bookmarked moment covers and why it matters)
            ## Review Questions (3–5, with short answers)
            Output only the notes themselves, with no introduction or closing remarks.
            """
        }
    }

    /// 附在每則訊息前的目前播放時間
    public static func playbackPosition(_ seconds: Double, language: AILanguage) -> String {
        language.pick("（目前播放到 \(TimeFormat.clock(seconds))）", "(Currently at \(TimeFormat.clock(seconds)))")
    }

    /// 影片資訊與逐字稿
    public static func material(for context: StudyContext) -> String {
        let l = context.language
        let transcript = context.transcript.isEmpty
            ? l.pick("（目前沒有逐字稿：這部影片沒有可讀取的字幕）", "(No transcript: this video has no readable subtitles.)")
            : context.transcript.formatted()
        return """
        \(l.pick("影片：", "Video: "))\(context.title)
        \(l.pick("長度：", "Duration: "))\(TimeFormat.clock(context.duration))
        \(context.transcriptNote)
        <transcript>
        \(transcript)
        </transcript>
        """
    }

    /// 沒有工具的來源使用的完整 system prompt
    public static func plainSystemPrompt(for context: StudyContext) -> String {
        instructions(withTools: false, language: context.language) + "\n" + material(for: context)
    }

    static func system(for context: StudyContext) -> [JSONValue] {
        [
            ["type": "text", "text": .string(instructions(withTools: true, language: context.language))],
            // 逐字稿很長且在同一段對話中固定不變，放在 cache breakpoint 前，後續提問只付快取價格
            ["type": "text", "text": .string(material(for: context)), "cache_control": ["type": "ephemeral"]],
        ]
    }
}

/// 學習助手 Agent：手動 tool-use 迴圈，對話歷史只會往後加（不修改先前的回合）
@MainActor
public final class StudyAgent: StudySession {
    public let supportsTools = true
    public private(set) var messages: [JSONValue] = []
    private let client: ClaudeClient
    private let system: [JSONValue]
    private let tools: [AgentTool]
    private let maxTurns = 12

    public init(client: ClaudeClient, context: StudyContext, tools: [AgentTool]) {
        self.client = client
        self.system = StudyPrompts.system(for: context)
        self.tools = tools
    }

    /// 送出一則使用者訊息，執行到 Claude 不再呼叫工具為止，回傳最後的文字
    public func send(_ text: String, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> String {
        messages.append(["role": "user", "content": .string(text)])
        let definitions = tools.map(\.definition)
        var finalText = ""

        for _ in 0..<maxTurns {
            let response = try await client.stream(system: system, messages: messages, tools: definitions) { delta in
                onEvent(.text(delta))
            }
            messages.append(["role": "assistant", "content": .array(response.content)])
            finalText = response.text

            if response.stopReason == "max_tokens" {
                return finalText + "\n\n⚠️ 回應太長被截斷了。"
            }
            guard response.stopReason == "tool_use", !response.toolUses.isEmpty else { return finalText }

            // 同一回合的所有 tool_result 放在同一則 user 訊息
            var results: [JSONValue] = []
            for call in response.toolUses {
                let id = call["id"]?.stringValue ?? ""
                let name = call["name"]?.stringValue ?? ""
                let input = call["input"] ?? [:]
                onEvent(.toolCall(name: name, input: input))
                let (content, isError) = await run(name: name, input: input, invalid: response.invalidToolInputs.contains(id))
                var result: JSONValue = ["type": "tool_result", "tool_use_id": .string(id), "content": .string(content)]
                if isError { result["is_error"] = true }
                results.append(result)
            }
            messages.append(["role": "user", "content": .array(results)])
            onEvent(.text("\n\n"))
        }
        return finalText
    }

    private func run(name: String, input: JSONValue, invalid: Bool) async -> (String, Bool) {
        guard let tool = tools.first(where: { $0.name == name }) else { return ("未知的工具：\(name)", true) }
        if invalid { return ("INVALID_JSON：工具輸入不是完整的 JSON，請重新呼叫。", true) }
        if let problem = tool.validate(input) { return ("輸入不符合格式：\(problem)", true) }
        do {
            return (try await tool.run(input), false)
        } catch {
            return ("執行失敗：\(error.localizedDescription)", true)
        }
    }

}
