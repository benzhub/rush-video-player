import Foundation
import Testing
@testable import VideoPlayerCore

/// 對真實 Notion API 的整合測試，需要環境變數才會執行：
///   NOTION_TOKEN=… NOTION_TEST_PARENTS="<頁面網址> <資料庫網址>" swift test --filter NotionIntegration
/// 每次執行都會在指定位置建立一頁「[測試]」筆記。
enum NotionTestEnv {
    static let token = ProcessInfo.processInfo.environment["NOTION_TOKEN"]
    static let parents = (ProcessInfo.processInfo.environment["NOTION_TEST_PARENTS"] ?? "")
        .split(separator: " ").map(String.init)
    static let enabled = token != nil && !parents.isEmpty
}

@Suite(.enabled(if: NotionTestEnv.enabled))
struct NotionIntegrationTests {
    static let token = NotionTestEnv.token

    static let markdown: String = {
        var md = """
        # [測試] 遞迴與動態規劃
        ## 摘要
        這是 **Rush Video Player** 的 Notion 整合測試，包含 *斜體*、`行內程式碼` 與 [連結](https://github.com/benzhub/rush-video-player)。

        ## 重點筆記
        - [0:01] 遞迴就是函式呼叫自己
        - [0:07] 每個遞迴都需要終止條件
        1. 找出子問題
        2. 寫出狀態轉移
        - [x] 已完成的待辦
        - [ ] 未完成的待辦
        > 引用：沒有終止條件會堆疊溢位
        ---
        ```swift
        func fib(_ n: Int) -> Int { n < 2 ? n : fib(n - 1) + fib(n - 2) }
        ```
        ## 分批寫入測試
        """
        // 超過單次 100 個 blocks 的上限
        md += (1...120).map { "\n- 第 \($0) 行" }.joined()
        return md
    }()

    @Test(arguments: NotionTestEnv.parents)
    func createsPageWithAllBlocks(parent: String) async throws {
        let client = NotionClient(token: Self.token!)
        let kind = try await client.verify(parent: parent)
        let url = try await client.createPage(
            parent: parent,
            title: MarkdownToNotion.title(from: Self.markdown)!,
            markdown: Self.markdown,
            sourceInfo: "整合測試（\(kind)）")
        print("建立：\(kind) → \(url)")

        // 讀回所有 children，確認分批寫入後數量正確
        let pageID = try #require(NotionID.parse(url))
        var count = 0
        var cursor: String?
        repeat {
            var components = URLComponents(string: "https://api.notion.com/v1/blocks/\(pageID)/children")!
            components.queryItems = [URLQueryItem(name: "page_size", value: "100")] + (cursor.map { [URLQueryItem(name: "start_cursor", value: $0)] } ?? [])
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(Self.token!)", forHTTPHeaderField: "Authorization")
            request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONValue.parse(data)
            count += json["results"]?.arrayValue?.count ?? 0
            cursor = json["has_more"] == true ? json["next_cursor"]?.stringValue : nil
        } while cursor != nil

        // 標題 H1 不重複放進內文，另外多一個 callout
        let expected = MarkdownToNotion.blocks(from: Self.markdown).count - 1 + 1
        #expect(count == expected)
    }

    @Test func reportsInvalidToken() async {
        let client = NotionClient(token: "secret_invalid")
        await #expect(throws: NotionError.self) {
            try await client.verify(parent: NotionTestEnv.parents[0])
        }
    }
}
