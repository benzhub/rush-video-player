import Foundation

/// 把 AI 產生的 Markdown 轉成 Notion blocks。
/// 支援：標題、段落、條列、編號、待辦、引用、程式碼、分隔線；行內粗體、斜體、行內程式碼、連結。
public enum MarkdownToNotion {
    /// Notion 每個 rich text 物件最多 2000 字元
    static let maxTextLength = 2000

    public static func blocks(from markdown: String) -> [JSONValue] {
        var blocks: [JSONValue] = []
        var paragraph: [String] = []
        var codeLines: [String]?
        var codeLanguage = "plain text"

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(block("paragraph", richText(paragraph.joined(separator: "\n"))))
            paragraph = []
        }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if var code = codeLines {
                if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    blocks.append(codeBlock(code.joined(separator: "\n"), language: codeLanguage))
                    codeLines = nil
                } else {
                    code.append(rawLine)
                    codeLines = code
                }
                continue
            }

            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushParagraph(); continue }

            if line.hasPrefix("```") {
                flushParagraph()
                let lang = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                codeLanguage = lang.isEmpty ? "plain text" : lang.lowercased()
                codeLines = []
            } else if let (level, text) = heading(line) {
                flushParagraph()
                blocks.append(block("heading_\(level)", richText(text)))
            } else if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                blocks.append(["object": "block", "type": "divider", "divider": [:]])
            } else if let (checked, text) = todo(line) {
                flushParagraph()
                var b = block("to_do", richText(text))
                b["to_do"]?["checked"] = .bool(checked)
                blocks.append(b)
            } else if let text = strip(line, prefixes: ["- ", "* ", "+ ", "• "]) {
                flushParagraph()
                blocks.append(block("bulleted_list_item", richText(text)))
            } else if let match = line.firstMatch(of: /^\d+[.)]\s+(.*)$/) {
                flushParagraph()
                blocks.append(block("numbered_list_item", richText(String(match.1))))
            } else if let text = strip(line, prefixes: ["> ", ">"]) {
                flushParagraph()
                blocks.append(block("quote", richText(text)))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        if let code = codeLines { blocks.append(codeBlock(code.joined(separator: "\n"), language: codeLanguage)) }
        return blocks
    }

    /// 第一個 `# 標題` 當作頁面標題
    public static func title(from markdown: String) -> String? {
        markdown.components(separatedBy: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("# ") }
            .map { String($0.dropFirst(2)).replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Block helpers

    static func block(_ type: String, _ text: [JSONValue]) -> JSONValue {
        ["object": "block", "type": .string(type), .init(type): ["rich_text": .array(text)]]
    }

    static func codeBlock(_ code: String, language: String) -> JSONValue {
        let supported: Set<String> = ["swift", "python", "javascript", "typescript", "java", "c", "c++", "c#", "go",
                                      "rust", "ruby", "shell", "bash", "json", "html", "css", "sql", "yaml", "markdown", "kotlin", "php"]
        return [
            "object": "block", "type": "code",
            "code": ["rich_text": .array(split(code).map { textObject($0) }),
                     "language": .string(supported.contains(language) ? language : "plain text")],
        ]
    }

    static func heading(_ line: String) -> (Int, String)? {
        guard let m = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) else { return nil }
        return (min(m.1.count, 3), String(m.2))
    }

    static func todo(_ line: String) -> (Bool, String)? {
        guard let m = line.firstMatch(of: /^[-*]\s+\[([ xX])\]\s+(.*)$/) else { return nil }
        return (m.1 != " ", String(m.2))
    }

    static func strip(_ line: String, prefixes: [String]) -> String? {
        prefixes.first(where: line.hasPrefix).map { String(line.dropFirst($0.count)) }
    }

    // MARK: - Inline formatting

    struct Annotations: Equatable {
        var bold = false, italic = false, code = false
    }

    /// 解析 `**粗體**`、`*斜體*`、`` `code` ``、`[文字](網址)`
    static func richText(_ text: String) -> [JSONValue] {
        var result: [JSONValue] = []
        var buffer = ""
        var style = Annotations()
        var i = text.startIndex

        func flush(link: String? = nil) {
            guard !buffer.isEmpty else { return }
            for chunk in split(buffer) { result.append(textObject(chunk, style: style, link: link)) }
            buffer = ""
        }

        while i < text.endIndex {
            let rest = text[i...]
            if !style.code, rest.hasPrefix("**") || rest.hasPrefix("__") {
                flush(); style.bold.toggle(); i = text.index(i, offsetBy: 2); continue
            }
            if rest.hasPrefix("`") {
                flush(); style.code.toggle(); i = text.index(after: i); continue
            }
            if !style.code, rest.hasPrefix("*") || (rest.hasPrefix("_") && isWordBoundary(text, i)),
               canToggleItalic(text, i, closing: style.italic) {
                flush(); style.italic.toggle(); i = text.index(after: i); continue
            }
            if !style.code, let m = rest.prefixMatch(of: /\[([^\]]+)\]\(([^)\s]+)\)/) {
                flush()
                buffer = String(m.1)
                flush(link: String(m.2))
                i = m.range.upperBound
                continue
            }
            buffer.append(text[i])
            i = text.index(after: i)
        }
        flush()
        return result
    }

    /// 開始斜體的符號後面不能是空白，結束的符號前面不能是空白（`2 * 3` 的 `*` 是普通字元）
    private static func canToggleItalic(_ text: String, _ i: String.Index, closing: Bool) -> Bool {
        if closing {
            return i > text.startIndex && !text[text.index(before: i)].isWhitespace
        }
        let next = text.index(after: i)
        return next < text.endIndex && !text[next].isWhitespace
    }

    /// `_` 在英文單字中間（snake_case）不當作斜體
    private static func isWordBoundary(_ text: String, _ i: String.Index) -> Bool {
        let before = i > text.startIndex ? text[text.index(before: i)] : " "
        let afterIndex = text.index(after: i)
        let after = afterIndex < text.endIndex ? text[afterIndex] : " "
        return !(before.isLetter || before.isNumber) || !(after.isLetter || after.isNumber)
    }

    static func textObject(_ content: String, style: Annotations = Annotations(), link: String? = nil) -> JSONValue {
        var text: JSONValue = ["content": .string(content)]
        if let link, link.hasPrefix("http") { text["link"] = ["url": .string(link)] }
        var object: JSONValue = ["type": "text", "text": text]
        if style != Annotations() {
            object["annotations"] = ["bold": .bool(style.bold), "italic": .bool(style.italic), "code": .bool(style.code)]
        }
        return object
    }

    static func split(_ s: String) -> [String] {
        guard s.count > maxTextLength else { return [s] }
        var chunks: [String] = []
        var current = s[...]
        while !current.isEmpty {
            let end = current.index(current.startIndex, offsetBy: maxTextLength, limitedBy: current.endIndex) ?? current.endIndex
            chunks.append(String(current[..<end]))
            current = current[end...]
        }
        return chunks
    }
}
