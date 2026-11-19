import AppKit
import SwiftUI

/// MoltenVK 會把 drawableSize 暫時設成 1x1 造成閃爍，忽略這種設定
/// https://github.com/mpv-player/mpv/pull/13651
final class MetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

/// mpv 畫面輸出的 NSView
final class VideoNSView: NSView {
    let metalLayer = MetalLayer()
    /// 畫面大小改變並停下來後呼叫（拖拉視窗時不會每一格都呼叫）
    var onResize: ((CGSize) -> Void)?
    private var resizeWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.framebufferOnly = true
        wantsLayer = true
        layer = metalLayer
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size != metalLayer.drawableSize else { return }
        metalLayer.drawableSize = size

        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onResize?(size) }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // 讓 SwiftUI 的手勢（雙擊全螢幕、拖放）能收到事件
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct VideoSurface: NSViewRepresentable {
    let view: VideoNSView

    func makeNSView(context: Context) -> VideoNSView { view }
    func updateNSView(_ nsView: VideoNSView, context: Context) {}
}
