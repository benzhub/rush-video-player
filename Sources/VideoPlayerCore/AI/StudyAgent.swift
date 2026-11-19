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

/// 影片的學習情境：Agent 的 system prompt 由此產生
public struct StudyContext: Sendable {
    public var title: String
    public var duration: Double
    public var transcript: Transcript
    public var bookmarks: [Bookmark]

    public init(title: String, duration: Double, transcript: Transcript, bookmarks: [Bookmark]) {
        self.title = title
        self.duration = duration
        self.transcript = transcript
        self.bookmarks = bookmarks
    }

    var transcriptNote: String {
        switch transcript.source {
        case .file: "以下是完整逐字稿（來自字幕檔）。"
        case .accumulated: "以下逐字稿只包含使用者已經播放過的片段（來自影片內嵌字幕），之後的內容還不知道。"
        }
    }

    var bookmarksText: String {
        bookmarks.isEmpty ? "（沒有書籤）" : bookmarks.sorted { $0.time < $1.time }.map { b in
            var line = "[\(TimeFormat.clock(b.time))]"
            if let s = b.subtitle, !s.isEmpty { line += " 字幕：「\(s)」" }
            if !b.note.isEmpty { line += " 筆記：\(b.note)" }
            return line
        }.joined(separator: "\n")
    }
}

public enum StudyPrompts {
    static let instructions = """
    你是內建在影片播放器裡的學習助手。使用者正在看一部影片（課程、演講、教學或影集），想用你加速理解與整理內容。

    - 一律使用繁體中文（台灣用語）回答，專有名詞可以附上原文。
    - 回答要根據逐字稿；逐字稿沒有提到的內容，請明確說是你的補充，不要假裝影片有講。
    - 提到影片內容時附上時間戳，格式為 [m:ss] 或 [h:mm:ss]，方便使用者跳轉。
    - 使用 Markdown：標題、條列、粗體。不要用表格（側邊欄很窄）。
    - 使用者想回到某段內容時，用 seek_to 工具直接跳過去。
    - 只有在使用者要求時，才用 save_note_to_notion 存到 Notion。
    """

    public static let summary = """
    請幫我摘要這部影片：
    1. 一段話的整體摘要
    2. 依時間順序的章節重點（每節附開始時間戳）
    3. 重要名詞解釋
    """

    public static let notes = """
    請把這部影片整理成一份可以長期保存的學習筆記（Markdown）。結構如下：
    # 標題（用影片主題，不要用檔名）
    ## 摘要
    ## 重點筆記（依章節，附時間戳）
    ## 關鍵名詞
    ## 我的書籤（如果有書籤，說明每個書籤時間點在講什麼、為什麼重要）
    ## 複習問題（3–5 題，附簡短答案）
    只輸出筆記本身，不要加開場白或結語。
    """

    static func system(for context: StudyContext) -> [JSONValue] {
        let transcript = context.transcript.isEmpty ? "（目前沒有逐字稿：這部影片沒有可讀取的字幕）" : context.transcript.formatted()
        let material = """
        影片：\(context.title)
        長度：\(TimeFormat.clock(context.duration))
        \(context.transcriptNote)
        <transcript>
        \(transcript)
        </transcript>
        """
        return [
            ["type": "text", "text": .string(instructions)],
            // 逐字稿很長且在同一段對話中固定不變，放在 cache breakpoint 前，後續提問只付快取價格
            ["type": "text", "text": .string(material), "cache_control": ["type": "ephemeral"]],
        ]
    }
}

/// 學習助手 Agent：手動 tool-use 迴圈，對話歷史只會往後加（不修改先前的回合）
@MainActor
public final class StudyAgent {
    public enum Event: Sendable {
        case text(String)
        case toolCall(name: String, input: JSONValue)
    }

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
    public func send(_ text: String, onEvent: @escaping @Sendable (Event) -> Void) async throws -> String {
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

    /// 一次性產生學習筆記（不使用工具），供「看完自動存到 Notion」使用
    public static func generateNotes(client: ClaudeClient, context: StudyContext) async throws -> String {
        let response = try await client.stream(
            system: StudyPrompts.system(for: context),
            messages: [["role": "user", "content": .string(StudyPrompts.notes)]])
        return response.text
    }
}
