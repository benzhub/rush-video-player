// 產生 App 圖示（1024x1024 PNG）：swift scripts/make-icon.swift <輸出路徑>
import AppKit

let size = 1024.0
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS 圖示網格：824x824 圓角方形置中
let inset = (size - 824) / 2
let rect = NSRect(x: inset, y: inset, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(red: 0.98, green: 0.36, blue: 0.24, alpha: 1),
    NSColor(red: 0.85, green: 0.12, blue: 0.42, alpha: 1),
])!.draw(in: shape, angle: -60)

// 播放三角形
let play = NSBezierPath()
play.move(to: NSPoint(x: 410, y: 330))
play.line(to: NSPoint(x: 410, y: 694))
play.line(to: NSPoint(x: 720, y: 512))
play.close()
NSColor.white.setFill()
play.fill()

// 代表「下一集」的直線
let bar = NSBezierPath(roundedRect: NSRect(x: 300, y: 330, width: 56, height: 364), xRadius: 28, yRadius: 28)
NSColor.white.withAlphaComponent(0.85).setFill()
bar.fill()

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
