import Foundation

public enum OpenAIError: LocalizedError, Sendable {
    case missingAPIKey
    case http(status: Int, message: String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "尚未設定 OpenAI API Key，請到「設定 → AI」填入。"
        case .http(let status, let message): "OpenAI API 錯誤（\(status)）：\(message)"
        case .failed(let message): "OpenAI 回應失敗：\(message)"
        }
    }
}

/// OpenAI Responses API 的串流客戶端
public struct OpenAIClient: Sendable {
    public static let defaultModel = "gpt-6.2-astra"
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    public var apiKey: String
    public var model: String
    public var session: URLSession

    public init(apiKey: String, model: String = defaultModel, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model.isEmpty ? Self.defaultModel : model
        self.session = session
    }

    public struct Response: Sendable {
        /// 所有輸出項目（message / reasoning / function_call…），原樣加回下一輪的 input
        public var output: [JSONValue]
        public var status: String?

        public var text: String {
            output.filter { $0["type"]?.stringValue == "message" }
                .flatMap { $0["content"]?.arrayValue ?? [] }
                .filter { $0["type"]?.stringValue == "output_text" }
                .compactMap { $0["text"]?.stringValue }
                .joined()
        }

        public var functionCalls: [JSONValue] {
            output.filter { $0["type"]?.stringValue == "function_call" }
        }
    }

    public func stream(
        instructions: String,
        input: [JSONValue],
        tools: [JSONValue] = [],
        onText: @Sendable (String) -> Void = { _ in }
    ) async throws -> Response {
        guard !apiKey.isEmpty else { throw OpenAIError.missingAPIKey }
        var body: JSONValue = [
            "model": .string(model),
            "instructions": .string(instructions),
            "input": .array(input),
            "stream": true,
        ]
        if !tools.isEmpty { body["tools"] = .array(tools) }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try body.encoded()

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let message = (try? JSONValue.parse(data))?["error"]?["message"]?.stringValue
                ?? String(data: data, encoding: .utf8) ?? ""
            throw OpenAIError.http(status: status, message: message)
        }

        var assembler = OpenAIStreamAssembler()
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let event = try? JSONValue.parse(Data(payload.utf8)) else { continue }
            if let delta = try assembler.apply(event) { onText(delta) }
        }
        return assembler.finish()
    }
}

/// 把 Responses API 的串流事件組回完整的輸出項目
struct OpenAIStreamAssembler {
    private var items: [Int: JSONValue] = [:]
    private var completed: [JSONValue]?
    private var status: String?

    mutating func apply(_ event: JSONValue) throws -> String? {
        switch event["type"]?.stringValue {
        case "response.output_text.delta":
            return event["delta"]?.stringValue
        case "response.output_item.done":
            if let index = event["output_index"]?.doubleValue.map(Int.init), let item = event["item"] {
                items[index] = item
            }
        case "response.completed", "response.incomplete":
            completed = event["response"]?["output"]?.arrayValue
            status = event["response"]?["status"]?.stringValue
        case "response.failed":
            throw OpenAIError.failed(event["response"]?["error"]?["message"]?.stringValue ?? "未知錯誤")
        case "error":
            throw OpenAIError.failed(event["message"]?.stringValue ?? event["error"]?["message"]?.stringValue ?? "未知錯誤")
        default:
            break
        }
        return nil
    }

    func finish() -> OpenAIClient.Response {
        OpenAIClient.Response(output: completed ?? items.keys.sorted().compactMap { items[$0] }, status: status)
    }
}

/// OpenAI 版學習助手：Responses API + function calling 的手動工具迴圈
@MainActor
public final class OpenAIAgent: StudySession {
    public let supportsTools = true
    public private(set) var input: [JSONValue] = []
    private let client: OpenAIClient
    private let instructions: String
    private let tools: [AgentTool]
    private let maxTurns = 12

    public init(client: OpenAIClient, context: StudyContext, tools: [AgentTool]) {
        self.client = client
        // instructions（含逐字稿）在整段對話中固定不變，OpenAI 會自動快取相同的前綴
        self.instructions = StudyPrompts.instructions(withTools: true, language: context.language) + "\n" + StudyPrompts.material(for: context)
        self.tools = tools
    }

    public func send(_ text: String, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> String {
        input.append(["role": "user", "content": .string(text)])
        let definitions: [JSONValue] = tools.map {
            ["type": "function", "name": .string($0.name), "description": .string($0.description), "parameters": $0.schema]
        }
        var finalText = ""

        for _ in 0..<maxTurns {
            let response = try await client.stream(instructions: instructions, input: input, tools: definitions) { delta in
                onEvent(.text(delta))
            }
            input += response.output
            finalText = response.text
            let calls = response.functionCalls
            guard !calls.isEmpty else {
                if response.status == "incomplete" { return finalText + "\n\n⚠️ 回應太長被截斷了。" }
                return finalText
            }

            for call in calls {
                let name = call["name"]?.stringValue ?? ""
                let arguments = call["arguments"]?.stringValue ?? "{}"
                let parsed = try? JSONValue.parse(Data(arguments.utf8))
                onEvent(.toolCall(name: name, input: parsed ?? [:]))
                let output = await run(name: name, input: parsed)
                input.append([
                    "type": "function_call_output",
                    "call_id": call["call_id"] ?? .null,
                    "output": .string(output),
                ])
            }
            onEvent(.text("\n\n"))
        }
        return finalText
    }

    private func run(name: String, input: JSONValue?) async -> String {
        guard let tool = tools.first(where: { $0.name == name }) else { return "錯誤：未知的工具 \(name)" }
        guard let input else { return "錯誤：INVALID_JSON，工具參數不是完整的 JSON，請重新呼叫。" }
        if let problem = tool.validate(input) { return "錯誤：輸入不符合格式：\(problem)" }
        do {
            return try await tool.run(input)
        } catch {
            return "錯誤：\(error.localizedDescription)"
        }
    }
}
