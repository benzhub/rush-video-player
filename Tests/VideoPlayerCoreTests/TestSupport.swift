import Foundation

/// 在暫存資料夾建立假檔案，測試結束後刪除
final class TempDir {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("vp-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ path: String, _ contents: String = "", encoding: String.Encoding = .utf8) -> URL {
        let f = url.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! contents.data(using: encoding)!.write(to: f)
        return f.standardizedFileURL
    }
}
