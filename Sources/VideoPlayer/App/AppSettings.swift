import Foundation
import VideoPlayerCore

/// UserDefaults 的鍵與預設值；畫面用 @AppStorage 綁定同一組鍵
enum SettingKey {
    static let autoplayNext = "autoplayNext"
    static let countdownSeconds = "countdownSeconds"
    static let resumePlayback = "resumePlayback"
    static let subtitlePriority = "subtitlePriority"
    static let aiProvider = "aiProvider"
    static let aiModel = "aiModel"
    static let openAIModel = "openAIModel"
    static let claudeCLIModel = "claudeCLIModel"
    static let codexModel = "codexModel"
    static let aiEffort = "aiEffort"
    static let notionParent = "notionParent"
    static let autoNotion = "autoNotion"
}

enum AppSettings {
    static let defaults = UserDefaults.standard

    static func register() {
        defaults.register(defaults: [
            SettingKey.autoplayNext: true,
            SettingKey.countdownSeconds: 10,
            SettingKey.resumePlayback: true,
            SettingKey.subtitlePriority: SubtitleLanguage.defaultPriority.storageString,
            SettingKey.aiProvider: "",
            SettingKey.aiModel: ClaudeClient.defaultModel,
            SettingKey.openAIModel: OpenAIClient.defaultModel,
            SettingKey.claudeCLIModel: "",
            SettingKey.codexModel: "",
            SettingKey.aiEffort: "medium",
            SettingKey.notionParent: "",
            SettingKey.autoNotion: false,
        ])
    }

    static var autoplayNext: Bool { defaults.bool(forKey: SettingKey.autoplayNext) }
    static var countdownSeconds: Int { defaults.integer(forKey: SettingKey.countdownSeconds) }
    static var resumePlayback: Bool { defaults.bool(forKey: SettingKey.resumePlayback) }
    static var subtitlePriority: [SubtitleLanguage] {
        [SubtitleLanguage](storageString: defaults.string(forKey: SettingKey.subtitlePriority) ?? "")
    }
    static var notionParent: String { defaults.string(forKey: SettingKey.notionParent) ?? "" }
    static var autoNotion: Bool { defaults.bool(forKey: SettingKey.autoNotion) }

    /// 優先使用 Keychain，其次是環境變數
    static var anthropicAPIKey: String {
        KeychainStore.get(.anthropicAPIKey) ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    }

    static var openAIAPIKey: String {
        KeychainStore.get(.openAIAPIKey) ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    }

    /// 這個來源目前能不能用（CLI 已安裝、API Key 已填）
    static func isAvailable(_ kind: AIProviderKind) -> Bool {
        switch kind {
        case .claudeCLI, .codexCLI: ShellEnvironment.which(kind.executableName!) != nil
        case .anthropicAPI: !anthropicAPIKey.isEmpty
        case .openAIAPI: !openAIAPIKey.isEmpty
        }
    }

    /// 使用者選的來源；沒選過時依序找第一個可用的（Claude CLI → Anthropic → OpenAI → Codex）
    static var aiProvider: AIProviderKind {
        if let raw = defaults.string(forKey: SettingKey.aiProvider), let kind = AIProviderKind(rawValue: raw) {
            return kind
        }
        return AIProviderKind.allCases.first(where: isAvailable) ?? .claudeCLI
    }

    /// 依目前設定建立一段新的學習對話
    @MainActor
    static func makeSession(context: StudyContext, tools: [AgentTool]) -> StudySession {
        switch aiProvider {
        case .claudeCLI:
            ClaudeCLISession(context: context, model: defaults.string(forKey: SettingKey.claudeCLIModel) ?? "")
        case .anthropicAPI:
            StudyAgent(client: claudeClient(), context: context, tools: tools)
        case .openAIAPI:
            OpenAIAgent(
                client: OpenAIClient(apiKey: openAIAPIKey, model: defaults.string(forKey: SettingKey.openAIModel) ?? ""),
                context: context, tools: tools)
        case .codexCLI:
            CodexCLISession(context: context, model: defaults.string(forKey: SettingKey.codexModel) ?? "")
        }
    }

    static var notionToken: String {
        KeychainStore.get(.notionToken) ?? ProcessInfo.processInfo.environment["NOTION_TOKEN"] ?? ""
    }

    static func claudeClient() -> ClaudeClient {
        ClaudeClient(
            apiKey: anthropicAPIKey,
            model: defaults.string(forKey: SettingKey.aiModel) ?? ClaudeClient.defaultModel,
            effort: defaults.string(forKey: SettingKey.aiEffort) ?? "medium")
    }
}
