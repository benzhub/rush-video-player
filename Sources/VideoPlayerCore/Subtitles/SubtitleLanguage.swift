import Foundation

public enum SubtitleLanguage: String, CaseIterable, Codable, Sendable {
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"
    /// 中文但無法判斷繁簡
    case chinese = "zh"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case unknown = "und"

    public var displayName: String {
        switch self {
        case .traditionalChinese: "繁體中文"
        case .simplifiedChinese: "簡體中文"
        case .chinese: "中文"
        case .english: "英文"
        case .japanese: "日文"
        case .korean: "韓文"
        case .unknown: "未知"
        }
    }

    /// 可以在設定中排序的語言
    public static let configurable: [SubtitleLanguage] = [
        .traditionalChinese, .simplifiedChinese, .english, .japanese, .korean,
    ]

    public static let defaultPriority: [SubtitleLanguage] = [
        .traditionalChinese, .simplifiedChinese, .english,
    ]

    /// 依標記判斷語言，可以是檔名中的語言標記，也可以是 mpv 回報的 `lang`（例如 `chi`、`zh-TW`、`eng`）
    public static func fromTags(_ raw: String) -> SubtitleLanguage {
        let s = raw.lowercased().precomposedStringWithCanonicalMapping
        // 先比對多字元組合（含連字號，不能拆 token）
        for (pattern, lang) in compoundPatterns where s.contains(pattern) {
            return lang
        }
        let tokens = s.split(whereSeparator: { " ._-[]()&+,，、".contains($0) }).map(String.init)
        var found: [SubtitleLanguage] = []
        for token in tokens {
            if let lang = tokenMap[token] { found.append(lang) }
            // 中文標記常黏在一起：「繁英雙語」「简中」
            else if token.contains("繁") { found.append(.traditionalChinese) }
            else if token.contains("简") || token.contains("簡") { found.append(.simplifiedChinese) }
        }
        // 雙語字幕（例如 chs&eng）以中文為主
        let order: [SubtitleLanguage] = [.traditionalChinese, .simplifiedChinese, .chinese, .japanese, .korean, .english]
        return order.first(where: found.contains) ?? .unknown
    }

    private static let compoundPatterns: [(String, SubtitleLanguage)] = [
        ("zh-tw", .traditionalChinese), ("zh_tw", .traditionalChinese), ("zh-hk", .traditionalChinese),
        ("zh-hant", .traditionalChinese), ("zh-mo", .traditionalChinese),
        ("zh-cn", .simplifiedChinese), ("zh_cn", .simplifiedChinese), ("zh-hans", .simplifiedChinese),
        ("zh-sg", .simplifiedChinese),
    ]

    private static let tokenMap: [String: SubtitleLanguage] = [
        "cht": .traditionalChinese, "tc": .traditionalChinese, "big5": .traditionalChinese,
        "zht": .traditionalChinese, "tw": .traditionalChinese, "hk": .traditionalChinese,
        "trad": .traditionalChinese, "traditional": .traditionalChinese, "hant": .traditionalChinese,
        "chs": .simplifiedChinese, "sc": .simplifiedChinese, "gb": .simplifiedChinese, "gbk": .simplifiedChinese,
        "zhs": .simplifiedChinese, "cn": .simplifiedChinese, "simp": .simplifiedChinese,
        "simplified": .simplifiedChinese, "hans": .simplifiedChinese,
        "zh": .chinese, "chi": .chinese, "zho": .chinese, "chinese": .chinese, "中文": .chinese, "中字": .chinese,
        "en": .english, "eng": .english, "english": .english, "英文": .english, "英": .english,
        "ja": .japanese, "jp": .japanese, "jpn": .japanese, "japanese": .japanese, "日文": .japanese,
        "ko": .korean, "kor": .korean, "korean": .korean, "韓文": .korean, "韩文": .korean,
    ]
}

extension Array where Element == SubtitleLanguage {
    /// 越小越優先。無法判斷繁簡的中文排在兩者之間最優先者的後面一點。
    public func rank(of lang: SubtitleLanguage) -> Double {
        if let i = firstIndex(of: lang) { return Double(i) }
        if lang == .chinese {
            let zh = [SubtitleLanguage.traditionalChinese, .simplifiedChinese].compactMap { firstIndex(of: $0) }
            if let best = zh.min() { return Double(best) + 0.5 }
        }
        return Double(count) + (lang == .unknown ? 1 : 0)
    }

    public var storageString: String { map(\.rawValue).joined(separator: ",") }

    public init(storageString: String) {
        let parsed = storageString.split(separator: ",").compactMap { SubtitleLanguage(rawValue: String($0)) }
        self = parsed.isEmpty ? SubtitleLanguage.defaultPriority : parsed
    }
}
