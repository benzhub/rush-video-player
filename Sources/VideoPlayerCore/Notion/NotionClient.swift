import Foundation

public enum NotionError: LocalizedError, Sendable {
    case missingToken
    case missingParent
    case invalidParent(String)
    case http(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: "尚未設定 Notion Token，請到「設定 → Notion」填入。"
        case .missingParent: "尚未設定 Notion 筆記要存放的頁面或資料庫。"
        case .invalidParent(let s): "無法從「\(s)」解析出 Notion 頁面 ID。"
        case .http(let status, let message): "Notion API 錯誤（\(status)）：\(message)"
        }
    }
}

public enum NotionID {
    /// 接受 32 碼 ID、含連字號的 UUID，或 Notion 網址（`https://www.notion.so/My-Page-0123abcd...`）
    public static func parse(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = URL(string: trimmed)?.path ?? trimmed
        let candidates = path.replacingOccurrences(of: "-", with: "")
            .matches(of: /[0-9a-fA-F]{32}/).map { String($0.output).lowercased() }
        // 網址最後一段的 ID 才是頁面本身（前面可能是 workspace 路徑）
        guard let raw = candidates.last else { return nil }
        let chars = Array(raw)
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }.joined(separator: "-")
    }
}

/// Notion API：把學習筆記建立成頁面（可放在一般頁面下，或放進資料庫）
public struct NotionClient: Sendable {
    static let base = URL(string: "https://api.notion.com/v1/")!
    static let version = "2022-06-28"
    /// 每次請求最多 100 個 children
    static let batchSize = 100

    public var token: String
    public var session: URLSession

    public init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    /// 建立頁面並回傳網址。`parent` 可以是頁面或資料庫的 ID / 網址。
    @discardableResult
    public func createPage(parent: String, title: String, markdown: String, sourceInfo: String? = nil) async throws -> String {
        guard !token.isEmpty else { throw NotionError.missingToken }
        guard !parent.trimmingCharacters(in: .whitespaces).isEmpty else { throw NotionError.missingParent }
        guard let parentID = NotionID.parse(parent) else { throw NotionError.invalidParent(parent) }

        var blocks = MarkdownToNotion.blocks(from: markdown)
        // 頁面標題已經是第一個 H1，內文不重複
        if case .string("heading_1")? = blocks.first?["type"] { blocks.removeFirst() }
        if let sourceInfo {
            var callout = MarkdownToNotion.block("callout", MarkdownToNotion.richText(sourceInfo))
            callout["callout"]?["icon"] = ["type": "emoji", "emoji": "🎬"]
            blocks.insert(callout, at: 0)
        }

        let titleText: JSONValue = [["type": "text", "text": ["content": .string(String(title.prefix(200)))]]]
        var body: JSONValue
        if let titleProperty = try await databaseTitleProperty(parentID) {
            body = ["parent": ["database_id": .string(parentID)],
                    "properties": [.init(titleProperty): ["title": titleText]]]
        } else {
            body = ["parent": ["page_id": .string(parentID)],
                    "properties": ["title": ["title": titleText]]]
        }
        body["icon"] = ["type": "emoji", "emoji": "📒"]
        body["children"] = .array(Array(blocks.prefix(Self.batchSize)))

        let page = try await request("pages", method: "POST", body: body)
        guard let pageID = page["id"]?.stringValue else { throw NotionError.http(status: 200, message: "回應缺少頁面 ID") }

        var remaining = blocks.dropFirst(Self.batchSize)
        while !remaining.isEmpty {
            let batch = Array(remaining.prefix(Self.batchSize))
            remaining = remaining.dropFirst(Self.batchSize)
            _ = try await request("blocks/\(pageID)/children", method: "PATCH", body: ["children": .array(batch)])
        }
        return page["url"]?.stringValue ?? "https://www.notion.so/\(pageID.replacingOccurrences(of: "-", with: ""))"
    }

    /// 測試 Token 與父頁面是否可存取
    public func verify(parent: String) async throws -> String {
        guard let parentID = NotionID.parse(parent) else { throw NotionError.invalidParent(parent) }
        if try await databaseTitleProperty(parentID) != nil { return "資料庫" }
        _ = try await request("pages/\(parentID)", method: "GET", body: nil)
        return "頁面"
    }

    /// 如果 ID 是資料庫，回傳它的標題欄位名稱；是一般頁面則回傳 nil
    private func databaseTitleProperty(_ id: String) async throws -> String? {
        do {
            let db = try await request("databases/\(id)", method: "GET", body: nil)
            let properties = db["properties"]?.objectValue ?? [:]
            return properties.first(where: { $0.value["type"]?.stringValue == "title" })?.key ?? "Name"
        } catch NotionError.http(let status, _) where status == 404 || status == 400 {
            return nil
        }
    }

    private func request(_ path: String, method: String, body: JSONValue?) async throws -> JSONValue {
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.version, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try body.encoded() }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONValue.parse(data)) ?? .null
        guard (200..<300).contains(status) else {
            throw NotionError.http(status: status, message: json["message"]?.stringValue ?? String(data: data, encoding: .utf8) ?? "")
        }
        return json
    }
}
