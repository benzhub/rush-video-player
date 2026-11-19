import SwiftUI
import VideoPlayerCore

/// 紅筆標註截圖：拖曳畫線，可復原、清除，上傳時合成到原解析度
struct AnnotationView: View {
    let frame: CapturedFrame
    let onUpload: ([[CGPoint]], CGFloat) -> Void
    let onCancel: () -> Void

    /// 筆跡以圖片像素座標（左上角原點）儲存
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []

    private var imageSize: CGSize { CGSize(width: frame.image.width, height: frame.image.height) }
    private var penWidth: CGFloat { FrameImage.penWidth(for: frame.image) }

    /// 依圖片比例縮放到最多 1100×680 的顯示大小
    private var displaySize: CGSize {
        let scale = min(1100 / imageSize.width, 680 / imageSize.height, 1)
        return CGSize(width: (imageSize.width * scale).rounded(), height: (imageSize.height * scale).rounded())
    }

    var body: some View {
        let shown = displaySize
        let scale = shown.width / imageSize.width
        VStack(spacing: 0) {
            ZStack {
                Image(decorative: frame.image, scale: 1).resizable()
                Canvas { context, _ in
                    for stroke in strokes + [current] where !stroke.isEmpty {
                        let points = stroke.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
                        let width = penWidth * scale
                        if points.count == 1 {
                            let p = points[0]
                            context.fill(Path(ellipseIn: CGRect(x: p.x - width / 2, y: p.y - width / 2, width: width, height: width)),
                                         with: .color(.red))
                        } else {
                            var path = Path()
                            path.addLines(points)
                            context.stroke(path, with: .color(.red),
                                           style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                        }
                    }
                }
            }
            .frame(width: shown.width, height: shown.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let p = value.location
                        current.append(CGPoint(x: min(max(p.x, 0), shown.width) / scale,
                                               y: min(max(p.y, 0), shown.height) / scale))
                    }
                    .onEnded { _ in
                        if !current.isEmpty { strokes.append(current) }
                        current = []
                    })
            .onHover { inside in
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }

            Divider()
            HStack {
                Text(frame.caption).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer()
                Button("復原") { _ = strokes.popLast() }
                    .keyboardShortcut("z")
                    .disabled(strokes.isEmpty)
                Button("清除") { strokes = [] }
                    .disabled(strokes.isEmpty)
                Button("取消", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("上傳到 Notion") { onUpload(strokes, penWidth) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: max(shown.width, 560))
    }
}
