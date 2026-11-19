import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 截圖的影像處理：全部在記憶體中完成，不寫入任何檔案
public enum FrameImage {
    /// mpv `screenshot-raw` 的像素資料 → CGImage。
    /// `bgr0`／`bgra`：每像素 4 bytes，依序 B G R X；`rgba`：依序 R G B A。
    public static func image(pixels: Data, width: Int, height: Int, stride: Int, format: String) -> CGImage? {
        guard width > 0, height > 0, stride >= width * 4, pixels.count >= stride * height else { return nil }
        let bitmapInfo: CGBitmapInfo
        switch format {
        case "bgr0": bitmapInfo = [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]
        case "bgra": bitmapInfo = [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)]
        case "rgba": bitmapInfo = [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)]
        default: return nil
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public struct Encoded: Sendable {
        public var data: Data
        public var contentType: String
        public var fileExtension: String
    }

    /// 編碼成 PNG；超過 `limit` 時改用 JPEG，並逐步降低品質
    public static func encode(_ image: CGImage, limit: Int = 20 * 1024 * 1024) -> Encoded? {
        if let png = encode(image, type: .png, quality: nil), png.count <= limit {
            return Encoded(data: png, contentType: "image/png", fileExtension: "png")
        }
        for quality in [0.9, 0.75, 0.6, 0.4] {
            if let jpeg = encode(image, type: .jpeg, quality: quality), jpeg.count <= limit {
                return Encoded(data: jpeg, contentType: "image/jpeg", fileExtension: "jpg")
            }
        }
        return nil
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// 紅筆筆跡的預設粗細：依圖片大小調整，1080p 約 8 px
    public static func penWidth(for image: CGImage) -> CGFloat {
        max(4, CGFloat(max(image.width, image.height)) / 240)
    }

    /// 把筆跡畫到原解析度的圖片上。`strokes` 是圖片像素座標（左上角為原點）。
    public static func annotate(_ image: CGImage, strokes: [[CGPoint]], lineWidth: CGFloat) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // 轉成左上角原點，和畫面上的座標一致
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setStrokeColor(CGColor(srgbRed: 1, green: 0.15, blue: 0.1, alpha: 1))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.15, blue: 0.1, alpha: 1))
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            guard let first = stroke.first else { continue }
            if stroke.count == 1 {
                // 單點：畫一個圓點
                context.fillEllipse(in: CGRect(x: first.x - lineWidth / 2, y: first.y - lineWidth / 2, width: lineWidth, height: lineWidth))
                continue
            }
            context.beginPath()
            context.addLines(between: stroke)
            context.strokePath()
        }
        return context.makeImage()
    }
}
