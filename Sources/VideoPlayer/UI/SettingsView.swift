import SwiftUI
import VideoPlayerCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("一般", systemImage: "gearshape") }
            SubtitleSettings().tabItem { Label("字幕", systemImage: "captions.bubble") }
            AISettings().tabItem { Label("AI", systemImage: "sparkles") }
            NotionSettings().tabItem { Label("Notion", systemImage: "doc.text") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

struct GeneralSettings: View {
    @AppStorage(SettingKey.autoplayNext) private var autoplayNext = true
    @AppStorage(SettingKey.countdownSeconds) private var countdown = 10
    @AppStorage(SettingKey.resumePlayback) private var resume = true

    var body: some View {
        Form {
            Toggle("播完自動播放下一集", isOn: $autoplayNext)
            Stepper("結尾前 \(countdown) 秒顯示「下一集」提示", value: $countdown, in: 3...60)
                .disabled(!autoplayNext)
            Toggle("重新打開影片時從上次的位置繼續播放", isOn: $resume)
        }
    }
}

struct SubtitleSettings: View {
    @AppStorage(SettingKey.subtitlePriority) private var stored = SubtitleLanguage.defaultPriority.storageString

    private var priority: [SubtitleLanguage] { [SubtitleLanguage](storageString: stored) }

    var body: some View {
        Form {
            Section {
                ForEach(Array(priority.enumerated()), id: \.element) { index, lang in
                    HStack {
                        Text("\(index + 1). \(lang.displayName)")
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == priority.count - 1)
                        Button { remove(lang) } label: { Image(systemName: "minus.circle") }
                            .disabled(priority.count == 1)
                    }
                    .buttonStyle(.borderless)
                }
                let missing = SubtitleLanguage.configurable.filter { !priority.contains($0) }
                if !missing.isEmpty {
                    Menu("加入語言") {
                        ForEach(missing, id: \.self) { lang in
                            Button(lang.displayName) { stored = (priority + [lang]).storageString }
                        }
                    }
                    .fixedSize()
                }
            } header: {
                Text("字幕語言優先順序")
            } footer: {
                Text("打開影片時會自動載入同資料夾（以及 Subs/、Subtitles/、字幕/ 子資料夾）的字幕，並選用排在最前面的語言。手動選過的字幕會被記住。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func move(_ index: Int, by offset: Int) {
        var list = priority
        list.swapAt(index, index + offset)
        stored = list.storageString
    }

    private func remove(_ lang: SubtitleLanguage) {
        stored = priority.filter { $0 != lang }.storageString
    }
}

struct AISettings: View {
    @AppStorage(SettingKey.aiProvider) private var storedProvider = ""
    @AppStorage(SettingKey.aiModel) private var model = ClaudeClient.defaultModel
    @AppStorage(SettingKey.aiEffort) private var effort = "medium"
    @AppStorage(SettingKey.openAIModel) private var openAIModel = OpenAIClient.defaultModel
    @AppStorage(SettingKey.claudeCLIModel) private var claudeCLIModel = ""
    @AppStorage(SettingKey.codexModel) private var codexModel = ""
    @AppStorage(SettingKey.aiLanguage) private var language = AILanguage.traditionalChinese.rawValue
    @State private var anthropicKey = KeychainStore.get(.anthropicAPIKey) ?? ""
    @State private var openAIKey = KeychainStore.get(.openAIAPIKey) ?? ""
    @State private var availability: [AIProviderKind: Bool] = [:]
    @State private var testResult: String?
    @State private var testing = false

    private var provider: Binding<AIProviderKind> {
        Binding(
            get: { AIProviderKind(rawValue: storedProvider) ?? AppSettings.aiProvider },
            set: { storedProvider = $0.rawValue; testResult = nil })
    }

    var body: some View {
        Form {
            Section {
                Picker("AI 來源", selection: provider) {
                    ForEach(AIProviderKind.allCases, id: \.self) { kind in
                        Text("\(kind.displayName)  \(status(kind))").tag(kind)
                    }
                }
                Text(description(provider.wrappedValue)).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("回覆語言 Language", selection: $language) {
                    ForEach(AILanguage.allCases, id: \.self) { Text($0.displayName).tag($0.rawValue) }
                }
                Text("摘要、學習筆記、問答、存到 Notion 的內容，以及 AI 面板的介面，都會使用這個語言。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                switch provider.wrappedValue {
                case .claudeCLI:
                    TextField("模型", text: $claudeCLIModel, prompt: Text("留空使用 Claude Code 預設，例如 opus、sonnet"))
                case .anthropicAPI:
                    SecureField("Anthropic API Key", text: $anthropicKey, prompt: Text("sk-ant-…"))
                        .onChange(of: anthropicKey) { KeychainStore.set(anthropicKey, for: .anthropicAPIKey); refresh() }
                    Picker("模型", selection: $model) {
                        Text("Claude Opus 5.5（預設）").tag("claude-opus-5-5")
                        Text("Claude Sonnet 5.5").tag("claude-sonnet-5-5")
                        Text("Claude Haiku 5.5").tag("claude-haiku-5-5")
                    }
                    Picker("思考深度", selection: $effort) {
                        Text("低（最快）").tag("low")
                        Text("中（預設）").tag("medium")
                        Text("高").tag("high")
                    }
                case .openAIAPI:
                    SecureField("OpenAI API Key", text: $openAIKey, prompt: Text("sk-…"))
                        .onChange(of: openAIKey) { KeychainStore.set(openAIKey, for: .openAIAPIKey); refresh() }
                    TextField("模型", text: $openAIModel, prompt: Text(OpenAIClient.defaultModel))
                case .codexCLI:
                    TextField("模型", text: $codexModel, prompt: Text("留空使用 Codex 設定檔的預設模型"))
                }
            }

            HStack {
                Button("測試連線") { test() }.disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                if let testResult { Text(testResult).font(.callout).lineLimit(3) }
            }
        }
        .onAppear(perform: refresh)
    }

    private func status(_ kind: AIProviderKind) -> String {
        guard let available = availability[kind] else { return "" }
        switch kind {
        case .claudeCLI, .codexCLI: return available ? "✓ 已安裝" : "✗ 未安裝"
        case .anthropicAPI, .openAIAPI: return available ? "✓ 已設定" : "未設定"
        }
    }

    private func description(_ kind: AIProviderKind) -> String {
        switch kind {
        case .claudeCLI:
            "使用本機 Claude Code（claude 指令）與你的 Claude 訂閱登入，不需要 API Key。逐字串流；跳轉影片改用文字指令，存 Notion 請按面板上的按鈕。"
        case .anthropicAPI:
            "直接呼叫 Claude API，支援完整工具：AI 可以自己跳轉影片、查逐字稿、存到 Notion。金鑰存在鑰匙圈，也可以用環境變數 ANTHROPIC_API_KEY。"
        case .openAIAPI:
            "使用 OpenAI Responses API，支援完整工具。金鑰存在鑰匙圈，也可以用環境變數 OPENAI_API_KEY。"
        case .codexCLI:
            "使用本機 Codex CLI（codex 指令）與你的 ChatGPT 訂閱登入，不需要 API Key。回覆會整段出現；跳轉影片改用文字指令。"
        }
    }

    private func refresh() {
        Task.detached {
            let result = Dictionary(uniqueKeysWithValues: AIProviderKind.allCases.map { ($0, AppSettings.isAvailable($0)) })
            await MainActor.run { availability = result }
        }
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            do {
                let context = StudyContext(title: "連線測試", duration: 0, transcript: Transcript(), bookmarks: [])
                let session = AppSettings.makeSession(context: context, tools: [])
                let reply = try await session.send("這是連線測試，請只回覆 OK。") { _ in }
                testResult = reply.isEmpty ? "⚠️ 沒有回應" : "✅ 連線成功（\(provider.wrappedValue.shortName)）"
            } catch {
                testResult = "⚠️ \(error.localizedDescription)"
            }
            testing = false
        }
    }
}

struct NotionSettings: View {
    @AppStorage(SettingKey.notionParent) private var parent = ""
    @AppStorage(SettingKey.autoNotion) private var autoNotion = false
    @State private var token = KeychainStore.get(.notionToken) ?? ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                SecureField("Integration Token", text: $token, prompt: Text("ntn_… 或 secret_…"))
                    .onChange(of: token) { KeychainStore.set(token, for: .notionToken) }
                TextField("筆記存放位置", text: $parent, prompt: Text("貼上 Notion 頁面或資料庫的網址"))
                HStack {
                    Button("測試連線") { test() }.disabled(token.isEmpty || parent.isEmpty || testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult { Text(testResult).font(.callout) }
                }
            } footer: {
                Text("1. 到 notion.so/profile/integrations 建立 Internal Integration，複製 Token\n2. 在要存放筆記的頁面或資料庫右上角「⋯ → 連線」加入這個 Integration\n3. 把該頁面的網址貼到上方")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("看完一集時，自動用 AI 產生學習筆記並存到 Notion", isOn: $autoNotion)
                Text("需要字幕（逐字稿），每部影片只會自動存一次。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            do {
                let kind = try await NotionClient(token: token).verify(parent: parent)
                testResult = "✅ 可以存取這個\(kind)"
            } catch {
                testResult = "⚠️ \(error.localizedDescription)"
            }
            testing = false
        }
    }
}
