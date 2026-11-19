import Foundation
import VideoPlayerCore

/// UserDefaults 的鍵與預設值；畫面用 @AppStorage 綁定同一組鍵
enum SettingKey {
    static let autoplayNext = "autoplayNext"
    static let countdownSeconds = "countdownSeconds"
    static let resumePlayback = "resumePlayback"
    static let subtitlePriority = "subtitlePriority"
    static let aiModel = "aiModel"
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
            SettingKey.aiModel: ClaudeClient.defaultModel,
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
