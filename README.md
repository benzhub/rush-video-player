# Rush Video Player

一個好用的 macOS 影片播放器，專門解決兩個痛點，並內建 AI 學習助手：

- **字幕自動載入**：打開影片，同資料夾的字幕自動找到、自動選語言，Big5／GBK 編碼也不會亂碼
- **播放清單 + 自動連播**：打開任一集，同資料夾的影片自動排成清單（EP2 排在 EP10 前面），看完自動播下一集
- **AI 學習助手**：根據字幕整理摘要、學習筆記、回答問題，還能跳到影片指定段落；筆記可以自動存到 Notion

播放核心使用 [libmpv](https://mpv.io)（透過 [MPVKit](https://github.com/mpvkit/MPVKit)），支援 MKV / MP4 / AVI / WebM 等幾乎所有格式，並使用 VideoToolbox 硬體解碼。

## 安裝

需要 macOS 14 以上和 Swift 6（安裝 Xcode 或 Command Line Tools：`xcode-select --install`）。

```bash
./scripts/bundle.sh            # 產生 build/Rush Video Player.app
./scripts/bundle.sh --install  # 同時安裝到 /Applications
```

第一次建置時會下載 libmpv / FFmpeg 的預先編譯檔（數百 MB），需要一些時間。

開發時：

```bash
swift run VideoPlayer /path/to/video.mkv   # 直接執行
swift test                                 # 單元測試（只有 Command Line Tools 時改用 ./scripts/test.sh）
```

金鑰可以放在 `.env.local`（參考 `.env.example`，此檔不會被提交），開發時載入成環境變數：

```bash
set -a; . ./.env.local; set +a
swift run VideoPlayer                      # App 會讀取 ANTHROPIC_API_KEY / NOTION_TOKEN
swift test --filter NotionIntegration      # 對真實 Notion 建立測試頁面（需要 NOTION_TEST_PARENTS）
RVP_CLI_TESTS=claude,codex swift test --filter CLISessionIntegration   # 實際呼叫本機 claude / codex
```

## 字幕自動載入規則

打開 `影片.mkv` 時會尋找：

| 位置 | 例子 |
|---|---|
| 同名字幕 | `影片.srt`、`影片.ass` |
| 同名＋語言標記 | `影片.zh-TW.srt`、`影片.chs.ass`、`影片.繁體.srt`、`影片.en.srt` |
| 子資料夾 | `Subs/`、`Subtitles/`、`字幕/`，包含 `Subs/影片/2_English.srt` 結構 |
| 同集數 | 影片 `[Group] Show - S01E02.mkv` ↔ 字幕 `Show.S01E02.srt` |
| 資料夾只有一部影片 | 該資料夾內的任何字幕 |
| 內嵌字幕 | MKV 內的字幕軌 |

所有字幕都會載入，並依「設定 → 字幕」的語言優先順序（預設 繁中 > 簡中 > 英文）自動選一個。沒有語言標記時，會從內容判斷繁體或簡體。手動切換過的字幕會被記住。

## 快捷鍵

| 鍵 | 功能 |
|---|---|
| 空白鍵 | 播放／暫停 |
| ← / → | 倒轉／快轉 5 秒（加 ⇧：60 秒） |
| , / . | 倒轉／快轉 1 秒 |
| ↑ / ↓ | 音量 |
| N / P | 下一集／上一集 |
| F 或雙擊畫面 | 全螢幕 |
| M | 靜音 |
| B | 在目前時間加書籤（自動附上當下字幕） |
| [ / ] / \ | 字幕提早／延後 0.1 秒／重設 |
| ⌘= / ⌘- | 字幕放大／縮小 |
| ⌘[ / ⌘] / ⌘0 | 播放速度減慢／加快／正常 |
| ⌘L | 播放清單與書籤 |
| ⌘J | AI 學習助手 |
| ⌥⌘P | 子母畫面（右下角置頂小視窗） |
| ⇧⌘S | 截圖到 Notion |
| ⌥⇧⌘S | 截圖並用紅筆標註後上傳到 Notion |
| ⌘O / ⇧⌘O | 開啟／加入播放清單 |

拖曳影片或資料夾到視窗即可開啟；拖曳字幕檔即可載入字幕。

## AI 學習助手

可以選擇四種 AI 來源（「設定 → AI」）：

| 來源 | 需要 | 說明 |
|---|---|---|
| **Claude CLI** | 已安裝並登入 [Claude Code](https://claude.com/claude-code)（`claude`） | 使用 Claude 訂閱，不需要 API Key；逐字串流 |
| **Anthropic API Key** | [API Key](https://console.anthropic.com/) 或環境變數 `ANTHROPIC_API_KEY` | 完整工具：AI 可以自己跳轉影片、查逐字稿、存 Notion |
| **OpenAI API Key** | API Key 或環境變數 `OPENAI_API_KEY` | 完整工具，使用 Responses API |
| **Codex CLI** | 已安裝並登入 Codex CLI（`codex`） | 使用 ChatGPT 訂閱，不需要 API Key；回覆整段出現 |

沒有特別選擇時，會依上表順序自動使用第一個可用的來源。API Key 存在 macOS 鑰匙圈。CLI 來源在暫存資料夾中執行，並關閉所有內建工具，只根據逐字稿回答；需要跳轉影片時，AI 會輸出跳轉指令，由播放器執行。

「設定 → AI → 回覆語言」可以選繁體中文或 English。選 English 時，摘要、學習筆記、問答、存到 Notion 的內容，以及 AI 面板的介面都會改成英文；適合看英文課程時使用。

使用方式：播放有字幕的影片，按 ⌘J 開啟助手，按「摘要」或「學習筆記」，或直接問問題，例如：
- 這集在講什麼？
- 帶我回到講 XXX 的地方（播放器會直接跳轉）
- 解釋一下剛剛那段
- 整理成筆記並存到 Notion

回覆中的時間戳（例如 `[1:23]`）可以點擊跳轉。逐字稿來自外部字幕檔；如果只有內嵌字幕，會在播放時逐步累積。

### 存到 Notion

1. 到 [Notion Integrations](https://www.notion.so/profile/integrations) 建立 Internal Integration，複製 Token
2. 在要存放筆記的頁面（或資料庫）右上角「⋯ → 連線」加入這個 Integration
3. 「設定 → Notion」貼上 Token 和頁面網址，按「測試連線」
4. 可以開啟「看完一集時自動產生學習筆記並存到 Notion」

### 截圖到 Notion

AI 助手面板上的「截圖」按鈕（或 ⇧⌘S）會把目前畫面（含字幕）上傳到 Notion；按旁邊的選單（或 ⌥⇧⌘S）可以先暫停、用紅筆標註，再上傳。

- 每部影片對應一個 Notion 頁面：截圖和學習筆記都放在同一頁，沒有頁面時會在設定的位置新建
- 每張截圖附上時間戳和當下字幕作為說明
- 截圖只在記憶體中處理，不會在桌面或暫存資料夾留下任何檔案

## 專案結構

```
Sources/
  VideoPlayerCore/     # 純邏輯，可單元測試
    Subtitles/         # 字幕搜尋、語言判斷、編碼偵測、字幕解析、逐字稿
    Playlist/          # 資料夾掃描、自然排序
    Persistence/       # 播放進度／書籤（JSON）、Keychain
    AI/                # Claude API 串流客戶端、學習助手 Agent
    Notion/            # Notion API、Markdown → Notion blocks
  VideoPlayer/         # SwiftUI App
    Player/            # libmpv 包裝、播放狀態
    AI/                # AI 助手狀態與工具
    Notion/            # 截圖上傳到 Notion
    UI/                # 畫面
    App/               # App 進入點、選單、快捷鍵、設定
Tests/                 # swift-testing 單元測試
scripts/               # 打包、測試、圖示產生
```

播放進度與書籤存在 `~/Library/Application Support/RushVideoPlayer/playback.json`。

## 授權

播放核心 libmpv / FFmpeg 為 LGPL 授權（使用 MPVKit 的 LGPL 版本）。
