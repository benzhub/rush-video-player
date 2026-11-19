import CoreGraphics
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

        // 標題 H1 不重複放進內文，另外多一個 callout
        let expected = MarkdownToNotion.blocks(from: Self.markdown).count - 1 + 1
        #expect(try await Self.children(of: url).count == expected)
    }

    /// 讀回頁面所有 children（處理分頁）
    static func children(of page: String) async throws -> [JSONValue] {
        let pageID = try #require(NotionID.parse(page))
        var blocks: [JSONValue] = []
        var cursor: String?
        repeat {
            var components = URLComponents(string: "https://api.notion.com/v1/blocks/\(pageID)/children")!
            components.queryItems = [URLQueryItem(name: "page_size", value: "100")] + (cursor.map { [URLQueryItem(name: "start_cursor", value: $0)] } ?? [])
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
            request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONValue.parse(data)
            blocks += json["results"]?.arrayValue ?? []
            cursor = json["has_more"] == true ? json["next_cursor"]?.stringValue : nil
        } while cursor != nil
        return blocks
    }

    /// 本機常見的圖片存放位置裡的圖片檔
    static func localImages() -> Set<String> {
        let dirs = [FileManager.default.temporaryDirectory,
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")]
        var found: Set<String> = []
        for dir in dirs {
            let items = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            found.formUnion(items.filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }.map(\.path))
        }
        return found
    }

    /// 1280×720 的漸層圖，加上紅筆標註
    static func screenshot() throws -> FrameImage.Encoded {
        let width = 1280, height = 720
        var pixels = Data(count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8(x * 255 / width); pixels[i + 1] = UInt8(y * 255 / height); pixels[i + 2] = 80
            }
        }
        let frame = try #require(FrameImage.image(pixels: pixels, width: width, height: height, stride: width * 4, format: "bgr0"))
        let stroke = [CGPoint(x: 200, y: 200), CGPoint(x: 640, y: 500), CGPoint(x: 1080, y: 200)]
        let annotated = try #require(FrameImage.annotate(frame, strokes: [stroke], lineWidth: FrameImage.penWidth(for: frame)))
        return try #require(FrameImage.encode(annotated))
    }

    @Test(arguments: NotionTestEnv.parents)
    func uploadsScreenshotsToOnePage(parent: String) async throws {
        let before = Self.localImages()
        let client = NotionClient(token: Self.token!)
        let image = try Self.screenshot()

        let first = try await client.addImage(
            image.data, filename: "screenshot-83.png", contentType: image.contentType, caption: "[1:23] 遞迴需要終止條件",
            page: nil, parent: parent, newPageTitle: "[測試] 截圖上傳", sourceInfo: "整合測試：截圖上傳")
        #expect(first.created)
        let second = try await client.addImage(
            image.data, filename: "screenshot-125.png", contentType: image.contentType, caption: "[2:05]",
            page: first.pageURL, parent: parent, newPageTitle: "[測試] 截圖上傳", sourceInfo: nil)
        #expect(!second.created)
        #expect(second.pageURL == first.pageURL)
        print("截圖頁面：\(first.pageURL)")

        let blocks = try await Self.children(of: first.pageURL)
        #expect(blocks.map { $0["type"]?.stringValue ?? "" } == ["callout", "image", "image"])
        let captions = blocks.dropFirst().map { $0["image"]?["caption"]?.arrayValue?.first?["plain_text"]?.stringValue }
        #expect(captions == ["[1:23] 遞迴需要終止條件", "[2:05]"])
        #expect(blocks[1]["image"]?["type"] == "file")

        #expect(Self.localImages().subtracting(before).isEmpty)
    }

    @Test func reportsInvalidToken() async {
        let client = NotionClient(token: "secret_invalid")
        await #expect(throws: NotionError.self) {
            try await client.verify(parent: NotionTestEnv.parents[0])
        }
    }
}
