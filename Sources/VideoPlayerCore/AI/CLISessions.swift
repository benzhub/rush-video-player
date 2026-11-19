import Foundation

public enum CLIError: LocalizedError, Sendable {
    case notInstalled(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let name): "找不到 \(name) 指令，請先安裝並登入（終端機執行 \(name) 確認可以使用）。"
        case .failed(let message): message
        }
    }
}

/// 執行 CLI 子行程，逐行讀取 stdout；Task 被取消時終止子行程
enum CLIRunner {
    static func run(
        executable: URL,
        arguments: [String],
        stdin: String,
        workingDirectory: URL,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = ShellEnvironment.environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        return try await withTaskCancellationHandler {
            try process.run()
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()

            // stderr 在背景讀完，避免緩衝區塞滿卡住子行程
            let stderrTask = Task.detached { String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" }
            for try await line in output.fileHandleForReading.bytes.lines {
                onLine(line)
            }
            process.waitUntilExit()
            let stderr = await stderrTask.value
            try Task.checkCancellation()
            return (process.terminationStatus, stderr)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// 每段對話一個獨立的暫存資料夾，避免 CLI 讀到任何專案設定或檔案
    static func makeWorkingDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rvp-ai-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func lastLines(_ text: String, count: Int = 3) -> String {
        text.split(separator: "\n").suffix(count).joined(separator: "\n")
    }
}

/// Claude Code CLI（`claude -p`），使用使用者的 Claude 訂閱登入
@MainActor
public final class ClaudeCLISession: StudySession {
    public let supportsTools = false
    private let systemPrompt: String
    private let model: String
    private let workingDirectory = CLIRunner.makeWorkingDirectory()
    private var sessionID: String?

    public init(context: StudyContext, model: String = "") {
        systemPrompt = StudyPrompts.plainSystemPrompt(for: context)
        self.model = model
    }

    public func send(_ text: String, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> String {
        guard let executable = ShellEnvironment.which("claude") else { throw CLIError.notInstalled("claude") }
        var args = [
            "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            // 不給 CLI 任何內建工具，也不載入 MCP、使用者設定與專案設定
            "--tools", "", "--strict-mcp-config", "--setting-sources", "",
        ]
        if !model.isEmpty { args += ["--model", model] }
        if let sessionID {
            args += ["--resume", sessionID]
        } else {
            let file = workingDirectory.appendingPathComponent("system-prompt.md")
            try systemPrompt.write(to: file, atomically: true, encoding: .utf8)
            args += ["--system-prompt-file", file.path]
        }

        let parser = ClaudeStreamParser()
        let (status, stderr) = try await CLIRunner.run(
            executable: executable, arguments: args, stdin: text, workingDirectory: workingDirectory
        ) { line in
            if let delta = parser.consume(line) { onEvent(.text(delta)) }
        }
        let result = parser.result
        if let id = result.sessionID { sessionID = id }
        if let error = result.error { throw CLIError.failed("Claude CLI：\(error)") }
        guard status == 0 else { throw CLIError.failed("Claude CLI 結束代碼 \(status)：\(CLIRunner.lastLines(stderr))") }
        return result.text
    }
}

/// 解析 `claude -p --output-format stream-json --include-partial-messages` 的輸出
final class ClaudeStreamParser: @unchecked Sendable {
    struct Result {
        var sessionID: String?
        var text = ""
        var error: String?
    }

    private let lock = NSLock()
    private var state = Result()
    private var streamedText = ""

    var result: Result {
        lock.withLock {
            var r = state
            if r.text.isEmpty { r.text = streamedText }
            return r
        }
    }

    /// 回傳這一行新增的文字
    func consume(_ line: String) -> String? {
        guard let event = try? JSONValue.parse(Data(line.utf8)) else { return nil }
        return lock.withLock {
            if let id = event["session_id"]?.stringValue { state.sessionID = id }
            switch event["type"]?.stringValue {
            case "stream_event":
                let inner = event["event"]
                guard inner?["type"]?.stringValue == "content_block_delta",
                      inner?["delta"]?["type"]?.stringValue == "text_delta",
                      let text = inner?["delta"]?["text"]?.stringValue else { return nil }
                streamedText += text
                return text
            case "result":
                if event["is_error"] == true || event["subtype"]?.stringValue?.hasPrefix("error") == true {
                    state.error = event["result"]?.stringValue ?? event["subtype"]?.stringValue ?? "未知錯誤"
                } else if let text = event["result"]?.stringValue {
                    state.text = text
                }
                return nil
            default:
                return nil
            }
        }
    }
}

/// Codex CLI（`codex exec`），使用使用者的 ChatGPT 訂閱登入
@MainActor
public final class CodexCLISession: StudySession {
    public let supportsTools = false
    private let systemPrompt: String
    private let model: String
    private let workingDirectory = CLIRunner.makeWorkingDirectory()
    private var threadID: String?

    public init(context: StudyContext, model: String = "") {
        systemPrompt = StudyPrompts.plainSystemPrompt(for: context)
        self.model = model
    }

    public func send(_ text: String, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> String {
        guard let executable = ShellEnvironment.which("codex") else { throw CLIError.notInstalled("codex") }
        var args = ["exec"]
        let prompt: String
        if let threadID {
            args += ["resume", threadID, "--json", "--skip-git-repo-check"]
            prompt = text
        } else {
            // Codex 沒有 system prompt 參數，第一則訊息帶上說明與逐字稿
            args += ["--json", "--skip-git-repo-check", "--sandbox", "read-only"]
            prompt = "<instructions>\n\(systemPrompt)\n</instructions>\n\n\(text)"
        }
        if !model.isEmpty { args += ["-m", model] }
        args.append("-")

        let parser = CodexEventParser()
        let (status, stderr) = try await CLIRunner.run(
            executable: executable, arguments: args, stdin: prompt, workingDirectory: workingDirectory
        ) { line in
            if let message = parser.consume(line) { onEvent(.text(message)) }
        }
        let result = parser.result
        if let id = result.threadID { threadID = id }
        // Codex 遇到暫時性錯誤會自動重試，只有完全沒有回覆時才算失敗
        if let error = result.error, result.text.isEmpty { throw CLIError.failed("Codex CLI：\(error)") }
        guard status == 0 else { throw CLIError.failed("Codex CLI 結束代碼 \(status)：\(CLIRunner.lastLines(stderr))") }
        return result.text
    }
}

/// 解析 `codex exec --json` 的 JSONL 事件
final class CodexEventParser: @unchecked Sendable {
    struct Result {
        var threadID: String?
        var text = ""
        var error: String?
    }

    private let lock = NSLock()
    private var state = Result()

    var result: Result { lock.withLock { state } }

    /// 回傳新完成的回覆文字（Codex 不逐字串流，一次給整段）
    func consume(_ line: String) -> String? {
        guard let event = try? JSONValue.parse(Data(line.utf8)) else { return nil }
        return lock.withLock {
            switch event["type"]?.stringValue {
            case "thread.started":
                state.threadID = event["thread_id"]?.stringValue
            case "item.completed":
                guard event["item"]?["type"]?.stringValue == "agent_message",
                      let text = event["item"]?["text"]?.stringValue else { return nil }
                let piece = state.text.isEmpty ? text : "\n\n" + text
                state.text += piece
                return piece
            case "turn.failed":
                state.error = event["error"]?["message"]?.stringValue ?? "回合失敗"
            case "error":
                state.error = event["message"]?.stringValue ?? "未知錯誤"
            default:
                break
            }
            return nil
        }
    }
}
