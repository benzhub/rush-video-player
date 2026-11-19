import Foundation
import Testing
@testable import VideoPlayerCore

struct SeekDirectiveTests {
    @Test func extractsLastSeekAndCleansText() {
        let (text, seconds) = SeekDirective.extract("在 [1:35] 講到終止條件。\n<seek>95</seek>")
        #expect(text == "在 [1:35] 講到終止條件。")
        #expect(seconds == 95)
        #expect(SeekDirective.extract("沒有跳轉").seconds == nil)
        #expect(SeekDirective.extract("<seek> 12.5 </seek>").seconds == 12.5)
    }

    @Test func hidesPartialTagWhileStreaming() {
        #expect(SeekDirective.stripForDisplay("好的\n<se") == "好的\n<se")
        #expect(SeekDirective.stripForDisplay("好的\n<seek>9") == "好的\n")
        #expect(SeekDirective.stripForDisplay("好的<seek>9</seek>") == "好的")
    }
}

struct CLIParserTests {
    @Test func parsesClaudeStreamJSON() {
        let parser = ClaudeStreamParser()
        let lines = [
            #"{"type":"system","subtype":"init","session_id":"abc","model":"claude-opus-5-5"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"嗨"}},"session_id":"abc"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"！"}},"session_id":"abc"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"嗨！"}]},"session_id":"abc"}"#,
            "not json",
            #"{"type":"result","subtype":"success","is_error":false,"result":"嗨！","session_id":"abc"}"#,
        ]
        let deltas = lines.compactMap(parser.consume)
        #expect(deltas == ["嗨", "！"])
        #expect(parser.result.sessionID == "abc")
        #expect(parser.result.text == "嗨！")
        #expect(parser.result.error == nil)
    }

    @Test func reportsClaudeError() {
        let parser = ClaudeStreamParser()
        _ = parser.consume(#"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in"}"#)
        #expect(parser.result.error == "Not logged in")
    }

    @Test func parsesCodexJSONL() {
        let parser = CodexEventParser()
        let lines = [
            #"{"type":"thread.started","thread_id":"t-1"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"thinking"}}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"第一段"}}"#,
            #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"第二段"}}"#,
            #"{"type":"turn.completed","usage":{}}"#,
        ]
        let messages = lines.compactMap(parser.consume)
        #expect(messages == ["第一段", "\n\n第二段"])
        #expect(parser.result.threadID == "t-1")
        #expect(parser.result.text == "第一段\n\n第二段")
    }

    @Test func reportsCodexTurnFailure() {
        let parser = CodexEventParser()
        _ = parser.consume(#"{"type":"turn.failed","error":{"message":"usage limit"}}"#)
        #expect(parser.result.error == "usage limit")
    }
}

struct OpenAIStreamTests {
    @Test func assemblesTextAndFunctionCalls() throws {
        var assembler = OpenAIStreamAssembler()
        var text = ""
        let events = [
            #"{"type":"response.created","response":{"id":"r1"}}"#,
            #"{"type":"response.output_text.delta","output_index":0,"delta":"跳到"}"#,
            #"{"type":"response.output_text.delta","output_index":0,"delta":" 1:00"}"#,
            #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"跳到 1:00"}]}}"#,
            #"{"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","call_id":"c1","name":"seek_to","arguments":"{\"seconds\":60}"}}"#,
        ]
        for line in events {
            if let delta = try assembler.apply(try JSONValue.parse(Data(line.utf8))) { text += delta }
        }
        let response = assembler.finish()
        #expect(text == "跳到 1:00")
        #expect(response.text == "跳到 1:00")
        #expect(response.functionCalls.first?["call_id"] == "c1")
    }

    @Test func prefersCompletedOutput() throws {
        var assembler = OpenAIStreamAssembler()
        _ = try assembler.apply(try JSONValue.parse(Data(
            #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","id":"rs_1"},{"type":"message","content":[{"type":"output_text","text":"OK"}]}]}}"#.utf8)))
        let response = assembler.finish()
        #expect(response.output.count == 2)
        #expect(response.text == "OK")
        #expect(response.status == "completed")
    }

    @Test func throwsOnFailure() {
        var assembler = OpenAIStreamAssembler()
        #expect(throws: OpenAIError.self) {
            try assembler.apply(try JSONValue.parse(Data(#"{"type":"response.failed","response":{"error":{"message":"bad"}}}"#.utf8)))
        }
    }
}

/// 實際呼叫本機 claude / codex 指令（會使用訂閱額度）：
///   RVP_CLI_TESTS=claude,codex swift test --filter CLISessionIntegration
enum CLITestEnv {
    static let enabled = Set((ProcessInfo.processInfo.environment["RVP_CLI_TESTS"] ?? "").split(separator: ",").map(String.init))

    static let context = StudyContext(
        title: "遞迴入門",
        duration: 25,
        transcript: Transcript(cues: [
            SubtitleCue(start: 1, end: 3, text: "歡迎來到這堂課，我們今天要學習的是遞迴。"),
            SubtitleCue(start: 4, end: 6, text: "遞迴就是函式呼叫自己。"),
            SubtitleCue(start: 7, end: 9, text: "每個遞迴都需要一個終止條件。"),
            SubtitleCue(start: 10, end: 12, text: "否則程式會無限執行下去，堆疊就會溢位。"),
        ]),
        bookmarks: [])
}

@MainActor
@Suite(.serialized)
struct CLISessionIntegrationTests {
    @Test(.enabled(if: CLITestEnv.enabled.contains("claude")))
    func claudeCLIAnswersAndSeeks() async throws {
        try await exercise(ClaudeCLISession(context: CLITestEnv.context))
    }

    @Test(.enabled(if: CLITestEnv.enabled.contains("codex")))
    func codexCLIAnswersAndSeeks() async throws {
        try await exercise(CodexCLISession(context: CLITestEnv.context))
    }

    private func exercise(_ session: StudySession) async throws {
        // 第一輪：根據逐字稿回答
        let answer = try await session.send("這部影片的主題是什麼？用一句話回答。") { _ in }
        print("回答：\(answer)")
        #expect(answer.contains("遞迴"))

        // 第二輪：多輪對話 + 跳轉指令
        let reply = try await session.send("帶我回到講終止條件的地方。") { _ in }
        print("跳轉回覆：\(reply)")
        let seconds = try #require(SeekDirective.extract(reply).seconds)
        #expect((6...10).contains(seconds))
    }
}
