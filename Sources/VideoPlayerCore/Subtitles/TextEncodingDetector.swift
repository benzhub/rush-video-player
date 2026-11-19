import Foundation

/// 偵測字幕檔編碼：UTF-8 / UTF-16（BOM）/ Big5 / GB18030。
/// 中文字幕亂碼大多是 Big5 / GBK 被當成 UTF-8 讀，這裡用常用字頻率挑出最合理的解碼結果。
public enum TextEncodingDetector {
    public static let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)))
    public static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    public static func decode(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(data: data.dropFirst(3), encoding: .utf8) {
            return (s, .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) {
            return (s, .utf16)
        }
        if let s = String(data: data, encoding: .utf8) {
            return (s, .utf8)
        }
        let candidates: [(String, String.Encoding)] = [big5, gb18030].compactMap { enc in
            String(data: data, encoding: enc).map { ($0, enc) }
        }
        if let best = candidates.max(by: { score($0.0) < score($1.0) }) {
            return best
        }
        return String(data: data, encoding: .isoLatin1).map { ($0, .isoLatin1) }
    }

    public static func decode(contentsOf url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)?.text
    }

    /// 常用字在所有 CJK 字元中的比例；解碼錯誤時會出現大量罕用字，比例會很低
    static func score(_ text: String) -> Double {
        var cjk = 0, common = 0
        for scalar in text.unicodeScalars where (0x4E00...0x9FFF).contains(scalar.value) {
            cjk += 1
            if commonChars.contains(scalar) { common += 1 }
        }
        return cjk == 0 ? 0 : Double(common) / Double(cjk)
    }

    private static let commonChars = Set(
        ("的一是不了人我在有他這个們中來上大為和國到以說時要就出會可也你對生能而子那得於著下自之年過發後作裡用道行所然家種事成方多經麼去法學如都同現當沒動面起看定天分還進好小部其些主樣理心她本前開但因只從想實日"
         + "这个们来为国说时会对发后过里么学经现当没动还进开从实样")
            .unicodeScalars)
}

/// 從文字內容判斷是繁體、簡體還是英文
public enum ChineseScriptSniffer {
    private static let traditionalOnly = Set("這個們來為國說時會對發後過裡麼學經現當沒動還進開從實樣點聽無與見話問題讓認識覺");
    private static let simplifiedOnly = Set("这个们来为国说时会对发后过里么学经现当没动还进开从实样点听无与见话问题让认识觉");

    public static func sniff(_ text: String) -> SubtitleLanguage {
        var trad = 0, simp = 0, cjk = 0, kana = 0, hangul = 0, latin = 0
        for ch in text {
            if traditionalOnly.contains(ch) { trad += 1 }
            if simplifiedOnly.contains(ch) { simp += 1 }
            guard let v = ch.unicodeScalars.first?.value else { continue }
            switch v {
            case 0x4E00...0x9FFF: cjk += 1
            case 0x3040...0x30FF: kana += 1
            case 0xAC00...0xD7AF: hangul += 1
            default: if ch.isASCII && ch.isLetter { latin += 1 }
            }
        }
        if kana >= 20 { return .japanese }
        if hangul >= 20 { return .korean }
        if cjk >= 20 {
            if trad > simp { return .traditionalChinese }
            if simp > trad { return .simplifiedChinese }
            return .chinese
        }
        return latin > 200 ? .english : .unknown
    }
}
