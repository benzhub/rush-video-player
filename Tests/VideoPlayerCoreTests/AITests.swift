import Foundation
import Testing
@testable import VideoPlayerCore

struct StreamAssemblerTests {
    private func events(_ lines: [String]) throws -> (ClaudeResponse, String) {
        var assembler = StreamAssembler()
        var text = ""
        for line in lines {
            if let delta = try assembler.apply(try JSONValue.parse(Data(line.utf8))) { text += delta }
        }
        return (assembler.finish(), text)
    }

    @Test func assemblesTextThinkingAndToolUse() throws {
        let (response, text) = try events([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"跳到 "}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"1:00"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"t1","name":"seek_to","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"seco"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"nds\": 60}"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ])
        #expect(text == "跳到 1:00")
        #expect(response.stopReason == "tool_use")
        #expect(response.content[0]["signature"] == "sig")
        #expect(response.toolUses.first?["input"]?["seconds"] == 60)
        #expect(response.invalidToolInputs.isEmpty)
    }

    @Test func flagsTruncatedToolInput() throws {
        let (response, _) = try events([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t9","name":"seek_to","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"seconds\": "}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#,
        ])
        #expect(response.invalidToolInputs == ["t9"])
        #expect(response.content[0]["input"] == [:])
    }

    @Test func throwsOnErrorEvent() {
        var assembler = StreamAssembler()
        #expect(throws: ClaudeError.self) {
            try assembler.apply(try JSONValue.parse(Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8)))
        }
    }
}

struct AgentToolTests {
    let tool = AgentTool(
        name: "seek_to", description: "",
        schema: ["type": "object", "properties": ["seconds": ["type": "number"]], "required": ["seconds"]],
        run: { _ in "" })

    @Test func validatesInput() {
        #expect(tool.validate(["seconds": 10]) == nil)
        #expect(tool.validate([:]) != nil)
        #expect(tool.validate(["seconds": "10"]) != nil)
        #expect(tool.validate("x") != nil)
    }
}

struct NotionTests {
    @Test func parsesIDsAndURLs() {
        let id = "0123456789abcdef0123456789abcdef"
        let expected = "01234567-89ab-cdef-0123-456789abcdef"
        #expect(NotionID.parse(id) == expected)
        #expect(NotionID.parse(expected) == expected)
        #expect(NotionID.parse("https://www.notion.so/myteam/My-Notes-\(id)?v=fedcba9876543210fedcba9876543210") == expected)
        #expect(NotionID.parse("not an id") == nil)
    }

    @Test func convertsMarkdownBlocks() {
        let md = """
        # 標題
        ## 摘要
        第一行
        第二行

        - 重點 **粗體** 與 `code`
        1. 第一步
        - [x] 完成
        > 引言
        ---
        ```swift
        let x = 1
        ```
        """
        let blocks = MarkdownToNotion.blocks(from: md)
        #expect(blocks.compactMap { $0["type"]?.stringValue } == [
            "heading_1", "heading_2", "paragraph", "bulleted_list_item", "numbered_list_item", "to_do", "quote", "divider", "code",
        ])
        #expect(blocks[2]["paragraph"]?["rich_text"]?.arrayValue?.first?["text"]?["content"] == "第一行\n第二行")
        let bullet = blocks[3]["bulleted_list_item"]?["rich_text"]?.arrayValue ?? []
        #expect(bullet.map { $0["text"]?["content"]?.stringValue ?? "" } == ["重點 ", "粗體", " 與 ", "code"])
        #expect(bullet[1]["annotations"]?["bold"] == true)
        #expect(bullet[3]["annotations"]?["code"] == true)
        #expect(blocks[5]["to_do"]?["checked"] == true)
        #expect(blocks[8]["code"]?["language"] == "swift")
        #expect(MarkdownToNotion.title(from: md) == "標題")
    }

    @Test func linksAndSnakeCase() {
        let rich = MarkdownToNotion.richText("看 [文件](https://example.com) 的 snake_case_name")
        #expect(rich.count == 3)
        #expect(rich[1]["text"]?["link"]?["url"] == "https://example.com")
        #expect(rich[2]["text"]?["content"] == " 的 snake_case_name")
    }

    @Test func splitsLongText() {
        let long = String(repeating: "字", count: 4500)
        let rich = MarkdownToNotion.richText(long)
        #expect(rich.count == 3)
        #expect(rich.allSatisfy { ($0["text"]?["content"]?.stringValue?.count ?? 0) <= 2000 })
    }
}
