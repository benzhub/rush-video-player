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
        // 32 碼或 UUID 格式，前後不能緊接其他十六進位字元（標題 slug 結尾可能是數字，例如 `第01集-<id>`）
        let candidates = path.matches(of: /(?:^|[^0-9a-fA-F])([0-9a-fA-F]{32}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?![0-9a-fA-F])/)
            .map { String($0.output.1).replacingOccurrences(of: "-", with: "").lowercased() }
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

        // 頁面標題已經是第一個 H1，內文不重複
        let blocks = Self.noteBlocks(markdown: markdown, sourceInfo: sourceInfo, dropTitle: true)

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

        try await append(Array(blocks.dropFirst(Self.batchSize)), toBlock: pageID)
        return page["url"]?.stringValue ?? "https://www.notion.so/\(pageID.replacingOccurrences(of: "-", with: ""))"
    }

    /// 筆記內容的 blocks，最前面加上影片來源的 callout
    public static func noteBlocks(markdown: String, sourceInfo: String?, dropTitle: Bool) -> [JSONValue] {
        var blocks = MarkdownToNotion.blocks(from: markdown)
        if dropTitle, case .string("heading_1")? = blocks.first?["type"] { blocks.removeFirst() }
        if let sourceInfo {
            var callout = MarkdownToNotion.block("callout", MarkdownToNotion.richText(sourceInfo))
            callout["callout"]?["icon"] = ["type": "emoji", "emoji": "🎬"]
            blocks.insert(callout, at: 0)
        }
        return blocks
    }

    /// 在既有頁面（ID 或網址）最後面加上 blocks，超過 100 個時分批
    public func append(_ blocks: [JSONValue], to page: String) async throws {
        guard !token.isEmpty else { throw NotionError.missingToken }
        guard let pageID = NotionID.parse(page) else { throw NotionError.invalidParent(page) }
        try await append(blocks, toBlock: pageID)
    }

    /// 同 `append`，但頁面已被刪除或無法存取時回傳 false（呼叫端改建新頁面）
    public func appendIfPresent(_ blocks: [JSONValue], to page: String) async throws -> Bool {
        do {
            try await append(blocks, to: page)
            return true
        } catch where Self.isMissingPage(error) {
            return false
        }
    }

    private func append(_ blocks: [JSONValue], toBlock id: String) async throws {
        var remaining = blocks[...]
        while !remaining.isEmpty {
            let batch = Array(remaining.prefix(Self.batchSize))
            remaining = remaining.dropFirst(Self.batchSize)
            _ = try await request("blocks/\(id)/children", method: "PATCH", body: ["children": .array(batch)])
        }
    }

    /// Notion 單一檔案上傳的上限
    public static let maxUploadSize = 20 * 1024 * 1024

    /// 用 File Upload API 上傳記憶體中的檔案，回傳 file upload ID（之後以 `imageBlock` 引用）
    public func uploadFile(_ data: Data, filename: String, contentType: String) async throws -> String {
        guard !token.isEmpty else { throw NotionError.missingToken }
        guard data.count <= Self.maxUploadSize else {
            throw NotionError.http(status: 413, message: "檔案超過 20 MB")
        }
        let created = try await request("file_uploads", method: "POST",
                                        body: ["filename": .string(filename), "content_type": .string(contentType)])
        guard let id = created["id"]?.stringValue else { throw NotionError.http(status: 200, message: "回應缺少 file upload ID") }

        // multipart/form-data：只有一個 file 欄位
        let boundary = "RushVideoPlayer-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var send = makeRequest("file_uploads/\(id)/send", method: "POST")
        send.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        send.httpBody = body
        let sent = try await perform(send)
        if let status = sent["status"]?.stringValue, status != "uploaded" {
            throw NotionError.http(status: 200, message: "檔案上傳狀態：\(status)")
        }
        return id
    }

    /// 引用已上傳檔案的圖片 block
    public static func imageBlock(fileUploadID: String, caption: String) -> JSONValue {
        ["object": "block", "type": "image",
         "image": ["type": "file_upload",
                   "file_upload": ["id": .string(fileUploadID)],
                   "caption": .array(MarkdownToNotion.richText(caption))]]
    }

    /// 上傳圖片並附加到影片的 Notion 頁面。`page` 為 nil 或已被刪除時，在 `parent` 下新建一頁。
    /// 回傳實際使用的頁面網址，以及是否新建。
    public func addImage(_ data: Data, filename: String, contentType: String, caption: String,
                         page: String?, parent: String, newPageTitle: String,
                         sourceInfo: String?) async throws -> (pageURL: String, created: Bool) {
        let fileID = try await uploadFile(data, filename: filename, contentType: contentType)
        let block = Self.imageBlock(fileUploadID: fileID, caption: caption)
        if let page, try await appendIfPresent([block], to: page) {
            return (page, false)
        }
        let url = try await createPage(parent: parent, title: newPageTitle, markdown: "", sourceInfo: sourceInfo)
        try await append([block], to: url)
        return (url, true)
    }

    /// 頁面已被刪除（移到垃圾桶）或無法存取
    static func isMissingPage(_ error: Error) -> Bool {
        guard case NotionError.http(let status, let message) = error else { return false }
        return status == 404 || (status == 400 && message.localizedCaseInsensitiveContains("archived"))
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
        var request = makeRequest(path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try body.encoded() }
        return try await perform(request)
    }

    private func makeRequest(_ path: String, method: String) -> URLRequest {
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.version, forHTTPHeaderField: "Notion-Version")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> JSONValue {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONValue.parse(data)) ?? .null
        guard (200..<300).contains(status) else {
            throw NotionError.http(status: status, message: json["message"]?.stringValue ?? String(data: data, encoding: .utf8) ?? "")
        }
        return json
    }
}
