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
    @AppStorage(SettingKey.aiModel) private var model = ClaudeClient.defaultModel
    @AppStorage(SettingKey.aiEffort) private var effort = "medium"
    @State private var apiKey = KeychainStore.get(.anthropicAPIKey) ?? ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                SecureField("Anthropic API Key", text: $apiKey, prompt: Text("sk-ant-…"))
                    .onChange(of: apiKey) { KeychainStore.set(apiKey, for: .anthropicAPIKey) }
                Text("金鑰存在 macOS 鑰匙圈；也可以用環境變數 ANTHROPIC_API_KEY。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
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
            }
            HStack {
                Button("測試連線") { test() }.disabled(apiKey.isEmpty || testing)
                if testing { ProgressView().controlSize(.small) }
                if let testResult { Text(testResult).font(.callout) }
            }
        }
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            do {
                let response = try await AppSettings.claudeClient().stream(
                    system: [["type": "text", "text": "Reply with exactly: OK"]],
                    messages: [["role": "user", "content": "ping"]],
                    maxTokens: 2000)
                testResult = response.text.isEmpty ? "⚠️ 沒有回應" : "✅ 連線成功"
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
