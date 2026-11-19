import Foundation
import Testing
@testable import VideoPlayerCore

struct EncodingTests {
    let sample = "這是一段繁體中文字幕，我們來看看為什麼會出現亂碼的問題。"

    @Test func decodesBig5() throws {
        let data = try #require(sample.data(using: TextEncodingDetector.big5))
        let decoded = try #require(TextEncodingDetector.decode(data))
        #expect(decoded.text == sample)
    }

    @Test func decodesGB18030() throws {
        let simplified = "这是一段简体中文字幕，我们来看看为什么会出现乱码的问题。"
        let data = try #require(simplified.data(using: TextEncodingDetector.gb18030))
        #expect(TextEncodingDetector.decode(data)?.text == simplified)
    }

    @Test func decodesUTF8WithBOM() {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(sample.utf8)
        #expect(TextEncodingDetector.decode(data)?.text == sample)
    }

    @Test func sniffsScripts() {
        #expect(ChineseScriptSniffer.sniff(String(repeating: sample, count: 3)) == .traditionalChinese)
        #expect(ChineseScriptSniffer.sniff(String(repeating: "这是简体中文，我们来说为什么会这样。", count: 3)) == .simplifiedChinese)
        #expect(ChineseScriptSniffer.sniff(String(repeating: "これは日本語の字幕です。", count: 5)) == .japanese)
    }
}

struct SubtitleParserTests {
    @Test func parsesSRT() {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,500
        <i>Hello</i>
        world

        2
        00:01:02,000 --> 00:01:03,000
        第二句
        """
        let cues = SubtitleParser.parse(srt, format: "srt")
        #expect(cues == [
            SubtitleCue(start: 1, end: 2.5, text: "Hello\nworld"),
            SubtitleCue(start: 62, end: 63, text: "第二句"),
        ])
    }

    @Test func parsesVTT() {
        let vtt = "WEBVTT\n\n00:05.000 --> 00:06.000 align:start\nHi\n\n1:00:00.000 --> 1:00:01.000\nLate"
        let cues = SubtitleParser.parse(vtt, format: "vtt")
        #expect(cues.map(\.start) == [5, 3600])
        #expect(cues.map(\.text) == ["Hi", "Late"])
    }

    @Test func parsesASS() {
        let ass = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:03.50,0:00:05.00,Default,,0,0,0,,{\\an8}你好，世界\\N第二行
        Dialogue: 0,0:00:01.00,0:00:02.00,Sign,,0,0,0,,{\\p1}m 0 0 l 100 0
        """
        let cues = SubtitleParser.parse(ass, format: "ass")
        #expect(cues == [SubtitleCue(start: 3.5, end: 5, text: "你好，世界\n第二行")])
    }

    @Test func transcriptAccumulatesAndFormats() {
        var t = Transcript()
        t.append(text: "第一句", at: 1)
        t.append(text: "第一句", at: 2)
        t.append(text: "第二句", at: 65)
        t.append(text: "插在中間", at: 30)
        #expect(t.cues.map(\.text) == ["第一句", "插在中間", "第二句"])
        #expect(t.cues[0].end == 2)
        #expect(t.formatted() == "[0:01] 第一句\n[0:30] 插在中間\n[1:05] 第二句")
        #expect(t.formatted(from: 20, to: 40) == "[0:30] 插在中間")
        #expect(t.text(at: 1.5) == "第一句")
    }
}
