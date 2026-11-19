import Foundation

public enum AIProviderKind: String, CaseIterable, Codable, Sendable {
    case claudeCLI
    case anthropicAPI
    case openAIAPI
    case codexCLI

    public var displayName: String {
        switch self {
        case .claudeCLI: "Claude CLI（Claude 訂閱）"
        case .anthropicAPI: "Anthropic API Key"
        case .openAIAPI: "OpenAI API Key"
        case .codexCLI: "Codex CLI（ChatGPT 訂閱）"
        }
    }

    public var shortName: String {
        switch self {
        case .claudeCLI: "Claude CLI"
        case .anthropicAPI: "Claude API"
        case .openAIAPI: "OpenAI API"
        case .codexCLI: "Codex CLI"
        }
    }

    /// API 型來源支援 App 工具（跳轉、查逐字稿、存 Notion）；CLI 型改用文字指令
    public var supportsTools: Bool {
        self == .anthropicAPI || self == .openAIAPI
    }

    /// CLI 型來源的執行檔名稱
    public var executableName: String? {
        switch self {
        case .claudeCLI: "claude"
        case .codexCLI: "codex"
        default: nil
        }
    }
}

public enum AIEvent: Sendable {
    case text(String)
    case toolCall(name: String, input: JSONValue)
}

/// 一段學習助手對話。各家 AI 來源實作同一個介面，對話歷史由實作自行保存。
@MainActor
public protocol StudySession: AnyObject {
    var supportsTools: Bool { get }
    /// 送出一則訊息，串流回傳事件，結束後回傳最後的完整文字
    func send(_ text: String, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> String
}

/// 沒有工具的來源用 `<seek>秒數</seek>` 要求跳轉
public enum SeekDirective {
    nonisolated(unsafe) private static let pattern = /<seek>\s*(\d+(?:\.\d+)?)\s*<\/seek>/

    /// 回傳去掉指令的文字，以及最後一個跳轉時間
    public static func extract(_ text: String) -> (text: String, seconds: Double?) {
        let seconds = text.matches(of: pattern).last.flatMap { Double($0.1) }
        let cleaned = text.replacing(pattern, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, seconds)
    }

    /// 串流中途顯示用：連同尚未輸出完整的 `<seek…` 一起隱藏
    public static func stripForDisplay(_ text: String) -> String {
        var result = text.replacing(pattern, with: "")
        if let open = result.range(of: "<seek", options: .backwards), !result[open.lowerBound...].contains("</seek>") {
            result.removeSubrange(open.lowerBound...)
        }
        return result
    }
}

/// 從 Finder 啟動的 App 只有最基本的 PATH，CLI 需要使用者登入 shell 的環境
public enum ShellEnvironment {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedPath: String?

    public static var loginPATH: String {
        lock.lock()
        defer { lock.unlock() }
        if let cachedPath { return cachedPath }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var path = ""
        if (try? process.run()) != nil {
            path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
        }
        let fallback = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin", "/usr/bin", "/bin"]
        let combined = (path.split(separator: ":").map(String.init) + fallback)
        var seen = Set<String>()
        let result = combined.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        cachedPath = result
        return result
    }

    /// 在登入 shell 的 PATH 中尋找執行檔
    public static func which(_ name: String) -> URL? {
        for dir in loginPATH.split(separator: ":") {
            let url = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPATH
        return env
    }
}
