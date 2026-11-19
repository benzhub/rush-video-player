import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import VideoPlayerCore

/// 攔截 URLSession 請求，依序回傳預先設定的回應
final class MockNotion: URLProtocol, @unchecked Sendable {
    struct Recorded {
        var method: String
        var path: String
        var contentType: String?
        var body: Data
        var json: JSONValue? { try? JSONValue.parse(body) }
    }

    nonisolated(unsafe) static var handler: (Recorded) -> (Int, JSONValue) = { _ in (500, nil) }
    nonisolated(unsafe) static var requests: [Recorded] = []

    static func session(_ handler: @escaping (Recorded) -> (Int, JSONValue)) -> URLSession {
        self.handler = handler
        requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockNotion.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // URLProtocol 收到的請求本文會變成 stream
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let recorded = Recorded(
            method: request.httpMethod ?? "GET",
            path: request.url!.path.replacingOccurrences(of: "/v1/", with: ""),
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            body: body)
        Self.requests.append(recorded)
        let (status, json) = Self.handler(recorded)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? json.encoded()) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized)
struct NotionUploadTests {
    static let pageID = "11111111-2222-3333-4444-555555555555"
    static let parentID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    static let newPageID = "99999999-8888-7777-6666-555555555555"

    /// 一般流程的 Notion：上傳成功、父層是一般頁面；`archived` 的頁面附加時回 400
    static func notion(archived: Set<String> = []) -> URLSession {
        MockNotion.session { r in
            switch (r.method, r.path) {
            case ("POST", "file_uploads"):
                return (200, ["id": "upload-1", "status": "pending"])
            case ("POST", "file_uploads/upload-1/send"):
                return (200, ["id": "upload-1", "status": "uploaded"])
            case ("GET", "databases/\(parentID)"):
                return (404, ["message": "Could not find database"])
            case ("POST", "pages"):
                return (200, ["id": .string(newPageID), "url": .string("https://www.notion.so/New-\(newPageID.replacingOccurrences(of: "-", with: ""))")])
            case ("PATCH", let path) where path.hasPrefix("blocks/"):
                let id = path.split(separator: "/")[1]
                if archived.contains(String(id)) {
                    return (400, ["message": "Can't edit block that is archived. You must unarchive the block before editing."])
                }
                return (200, ["results": []])
            default:
                return (500, ["message": .string("unexpected \(r.method) \(r.path)")])
            }
        }
    }

    @Test func uploadsFileAsMultipart() async throws {
        let client = NotionClient(token: "secret_test", session: Self.notion())
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])
        let id = try await client.uploadFile(png, filename: "frame.png", contentType: "image/png")
        #expect(id == "upload-1")

        let requests = MockNotion.requests
        #expect(requests.map(\.path) == ["file_uploads", "file_uploads/upload-1/send"])
        #expect(requests[0].json?["filename"] == "frame.png")
        #expect(requests[0].json?["content_type"] == "image/png")

        let send = requests[1]
        let boundary = try #require(send.contentType?.components(separatedBy: "boundary=").last)
        #expect(send.contentType?.hasPrefix("multipart/form-data") == true)
        let body = send.body
        #expect(body.range(of: Data("name=\"file\"; filename=\"frame.png\"".utf8)) != nil)
        #expect(body.range(of: Data("Content-Type: image/png\r\n\r\n".utf8) + png + Data("\r\n--\(boundary)--".utf8)) != nil)
    }

    @Test func rejectsOversizedUpload() async {
        let client = NotionClient(token: "secret_test", session: Self.notion())
        await #expect(throws: NotionError.self) {
            try await client.uploadFile(Data(count: NotionClient.maxUploadSize + 1), filename: "big.png", contentType: "image/png")
        }
        #expect(MockNotion.requests.isEmpty)
    }

    @Test func appendsImageToExistingPage() async throws {
        let client = NotionClient(token: "secret_test", session: Self.notion())
        let result = try await client.addImage(
            Data([1, 2, 3]), filename: "a.png", contentType: "image/png", caption: "[1:23] 終止條件",
            page: "https://www.notion.so/Notes-\(Self.pageID.replacingOccurrences(of: "-", with: ""))",
            parent: Self.parentID, newPageTitle: "影片", sourceInfo: nil)
        #expect(result.created == false)
        #expect(!MockNotion.requests.contains { $0.path == "pages" })

        let patch = try #require(MockNotion.requests.last)
        #expect(patch.method == "PATCH")
        #expect(patch.path == "blocks/\(Self.pageID)/children")
        let image = try #require(patch.json?["children"]?.arrayValue?.first)
        #expect(image["type"] == "image")
        #expect(image["image"]?["type"] == "file_upload")
        #expect(image["image"]?["file_upload"]?["id"] == "upload-1")
        #expect(image["image"]?["caption"]?.arrayValue?.first?["text"]?["content"] == "[1:23] 終止條件")
    }

    @Test(arguments: [true, false])
    func createsPageWhenMissingOrArchived(hasArchivedPage: Bool) async throws {
        let client = NotionClient(token: "secret_test", session: Self.notion(archived: [Self.pageID]))
        let result = try await client.addImage(
            Data([1, 2, 3]), filename: "a.png", contentType: "image/png", caption: "[0:05]",
            page: hasArchivedPage ? Self.pageID : nil,
            parent: Self.parentID, newPageTitle: "第 1 集", sourceInfo: "影片：第 1 集")
        #expect(result.created)
        #expect(NotionID.parse(result.pageURL) == Self.newPageID)

        let create = try #require(MockNotion.requests.first { $0.path == "pages" })
        #expect(create.json?["parent"]?["page_id"] == .string(Self.parentID))
        #expect(create.json?["properties"]?["title"]?["title"]?.arrayValue?.first?["text"]?["content"] == "第 1 集")
        #expect(create.json?["children"]?.arrayValue?.first?["type"] == "callout")
        // 圖片附加到新頁面
        #expect(MockNotion.requests.last?.path == "blocks/\(Self.newPageID)/children")
    }

    @Test func reportsUploadFailure() async {
        let session = MockNotion.session { _ in (401, ["message": "API token is invalid."]) }
        let client = NotionClient(token: "secret_bad", session: session)
        do {
            _ = try await client.uploadFile(Data([1]), filename: "a.png", contentType: "image/png")
            Issue.record("應該要丟出錯誤")
        } catch {
            #expect(error.localizedDescription.contains("API token is invalid."))
            #expect(error.localizedDescription.contains("401"))
        }
    }
}

struct FrameImageTests {
    /// 4×2 的 bgr0 影像：左半紅、右半藍；每列多 8 bytes padding
    static func sample() -> CGImage {
        let width = 4, height = 2, stride = width * 4 + 8
        var pixels = Data(count: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * stride + x * 4
                let (b, g, r): (UInt8, UInt8, UInt8) = x < 2 ? (0, 0, 255) : (255, 0, 0)
                pixels[i] = b; pixels[i + 1] = g; pixels[i + 2] = r; pixels[i + 3] = 0
            }
        }
        return FrameImage.image(pixels: pixels, width: width, height: height, stride: stride, format: "bgr0")!
    }

    /// 讀回 RGBA 像素
    static func rgba(_ image: CGImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &out, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return out
    }

    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * image.width + x) * 4
        return Array(rgba(image)[i..<i + 3])
    }

    @Test func convertsBGR0WithStride() {
        let image = Self.sample()
        #expect(image.width == 4 && image.height == 2)
        #expect(Self.pixel(image, 0, 0) == [255, 0, 0])
        #expect(Self.pixel(image, 3, 1) == [0, 0, 255])
    }

    @Test func rejectsBadInput() {
        #expect(FrameImage.image(pixels: Data(count: 10), width: 4, height: 2, stride: 16, format: "bgr0") == nil)
        #expect(FrameImage.image(pixels: Data(count: 32), width: 4, height: 2, stride: 16, format: "yuv420p") == nil)
    }

    @Test func encodesPNGInMemory() throws {
        let encoded = try #require(FrameImage.encode(Self.sample()))
        #expect(encoded.contentType == "image/png")
        #expect(encoded.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let source = try #require(CGImageSourceCreateWithData(encoded.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(Self.pixel(decoded, 0, 0) == [255, 0, 0])
    }

    @Test func fallsBackToJPEGWhenTooLarge() throws {
        // 雜訊圖：PNG 壓不小，JPEG 會小很多
        let size = 256
        var rng = SystemRandomNumberGenerator()
        let noise = Data((0..<size * size * 4).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let image = try #require(FrameImage.image(pixels: noise, width: size, height: size, stride: size * 4, format: "bgr0"))
        let png = try #require(FrameImage.encode(image))
        let encoded = try #require(FrameImage.encode(image, limit: png.data.count - 1))
        #expect(encoded.contentType == "image/jpeg")
        #expect(encoded.fileExtension == "jpg")
        #expect(encoded.data.starts(with: [0xFF, 0xD8]))
    }

    @Test func drawsStrokesAtOriginalResolution() throws {
        let image = Self.sample()
        // 從右上角畫到右下角（左上角原點），只蓋住 x = 3 那一欄
        let annotated = try #require(FrameImage.annotate(image, strokes: [[CGPoint(x: 3.5, y: 0), CGPoint(x: 3.5, y: 2)]], lineWidth: 1))
        #expect(annotated.width == 4 && annotated.height == 2)
        let stroked = Self.pixel(annotated, 3, 0)
        #expect(stroked[0] > 200 && stroked[2] < 80)       // 紅筆
        #expect(Self.pixel(annotated, 2, 0) == [0, 0, 255]) // 旁邊仍是原本的藍色
        #expect(Self.pixel(annotated, 0, 1) == [255, 0, 0])
    }
}
