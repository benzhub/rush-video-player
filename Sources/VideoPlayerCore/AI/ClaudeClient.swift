import Foundation

public enum ClaudeError: LocalizedError, Sendable {
    case missingAPIKey
    case http(status: Int, message: String)
    case stream(String)
    case refusal(String?)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "尚未設定 Anthropic API Key，請到「設定 → AI」填入。"
        case .http(let status, let message): "Claude API 錯誤（\(status)）：\(message)"
        case .stream(let message): "串流中斷：\(message)"
        case .refusal(let explanation): "Claude 拒絕了這個請求" + (explanation.map { "：\($0)" } ?? "。")
        }
    }
}

/// 一次 Messages API 回應的完整結果
public struct ClaudeResponse: Sendable {
    /// 原始內容區塊（text / thinking / tool_use…），原封不動加回對話歷史
    public var content: [JSONValue]
    public var stopReason: String?
    public var stopDetails: JSONValue?
    /// 輸入 JSON 不完整或無法解析的 tool_use id
    public var invalidToolInputs: Set<String> = []

    public var text: String {
        content.filter { $0["type"]?.stringValue == "text" }.compactMap { $0["text"]?.stringValue }.joined()
    }

    public var toolUses: [JSONValue] {
        content.filter { $0["type"]?.stringValue == "tool_use" }
    }
}

/// Claude Messages API 的最小串流客戶端（Swift 沒有官方 SDK，直接走 HTTP + SSE）
public struct ClaudeClient: Sendable {
    public static let defaultModel = "claude-opus-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"
    /// 伺服器端 fallback：請求被安全分類器拒絕時，自動改用建議的備援模型重跑
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    public var apiKey: String
    public var model: String
    public var effort: String
    public var session: URLSession

    public init(apiKey: String, model: String = defaultModel, effort: String = "medium", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.session = session
    }

    /// 送出請求並串流回應。`onText` 會收到逐步產生的文字。
    public func stream(
        system: [JSONValue],
        messages: [JSONValue],
        tools: [JSONValue] = [],
        maxTokens: Int = 64000,
        onText: @Sendable (String) -> Void = { _ in }
    ) async throws -> ClaudeResponse {
        guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }
        var body: JSONValue = [
            "model": .string(model),
            "max_tokens": .number(Double(maxTokens)),
            "stream": true,
            "fallbacks": "default",
            "output_config": ["effort": .string(effort)],
            "system": .array(system),
            "messages": .array(messages),
        ]
        if !tools.isEmpty { body["tools"] = .array(tools) }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try body.encoded()

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let message = (try? JSONValue.parse(data))?["error"]?["message"]?.stringValue
                ?? String(data: data, encoding: .utf8) ?? ""
            throw ClaudeError.http(status: status, message: message)
        }

        var assembler = StreamAssembler()
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let event = try? JSONValue.parse(Data(payload.utf8)) else { continue }
            if let delta = try assembler.apply(event) { onText(delta) }
        }
        let result = assembler.finish()
        if result.stopReason == "refusal" {
            throw ClaudeError.refusal(result.stopDetails?["explanation"]?.stringValue)
        }
        return result
    }
}

/// 把 SSE 事件組回完整的內容區塊。
/// 未知的區塊類型照原樣保留，thinking 區塊（含 signature）也必須完整回傳給 API。
struct StreamAssembler {
    private var blocks: [Int: JSONValue] = [:]
    private var partialJSON: [Int: String] = [:]
    private var invalidToolInputs: Set<String> = []
    private var stopReason: String?
    private var stopDetails: JSONValue?

    /// 回傳這個事件新增的可顯示文字
    mutating func apply(_ event: JSONValue) throws -> String? {
        switch event["type"]?.stringValue {
        case "content_block_start":
            guard let index = event["index"]?.doubleValue.map(Int.init), let block = event["content_block"] else { return nil }
            blocks[index] = block
        case "content_block_delta":
            guard let index = event["index"]?.doubleValue.map(Int.init), var block = blocks[index],
                  let delta = event["delta"] else { return nil }
            defer { blocks[index] = block }
            switch delta["type"]?.stringValue {
            case "text_delta":
                let text = delta["text"]?.stringValue ?? ""
                block["text"] = .string((block["text"]?.stringValue ?? "") + text)
                return text
            case "thinking_delta":
                block["thinking"] = .string((block["thinking"]?.stringValue ?? "") + (delta["thinking"]?.stringValue ?? ""))
            case "signature_delta":
                block["signature"] = delta["signature"]
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"]?.stringValue ?? ""
            default:
                break
            }
        case "content_block_stop":
            guard let index = event["index"]?.doubleValue.map(Int.init), let json = partialJSON.removeValue(forKey: index) else {
                return nil
            }
            // 開啟 eager_input_streaming 後伺服器不再驗證工具輸入，解析失敗時標記成無效，由呼叫端回報錯誤
            if json.isEmpty {
                blocks[index]?["input"] = [:]
            } else if let input = try? JSONValue.parse(Data(json.utf8)) {
                blocks[index]?["input"] = input
            } else {
                blocks[index]?["input"] = [:]
                if let id = blocks[index]?["id"]?.stringValue { invalidToolInputs.insert(id) }
            }
        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.stringValue { stopReason = reason }
            if let details = event["delta"]?["stop_details"], details != .null { stopDetails = details }
        case "error":
            throw ClaudeError.stream(event["error"]?["message"]?.stringValue ?? "未知錯誤")
        default:
            break
        }
        return nil
    }

    func finish() -> ClaudeResponse {
        ClaudeResponse(
            content: blocks.keys.sorted().compactMap { blocks[$0] },
            stopReason: stopReason,
            stopDetails: stopDetails,
            invalidToolInputs: invalidToolInputs)
    }
}
