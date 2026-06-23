// 生成 app 图标 PNG（蓝→靛渐变圆角方 + 白色 sparkles）。
// 用法：swift tools/render_icon.swift <输出PNG路径> [边长，默认1024]
// 供 build.sh 生成 AppIcon.icns（与 app 内 makeAppIcon 视觉一致）。
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/appicon.png"
let side = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 1024) : 1024
let s = CGFloat(side)

// 先渲染白色 sparkles（sourceAtop 仅给符号上色）
func whiteSymbol(_ name: String, pointSize: CGFloat) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)) else { return nil }
    let img = NSImage(size: base.size)
    img.lockFocus()
    let r = NSRect(origin: .zero, size: base.size)
    base.draw(in: r)
    NSColor.white.set()
    r.fill(using: .sourceAtop)
    img.unlockFocus()
    return img
}

let glyph = whiteSymbol("sparkles", pointSize: s * 0.5)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    FileHandle.standardError.write("bitmap rep failed\n".data(using: .utf8)!); exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let margin = s * 0.05
let rect = NSRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.22, yRadius: s * 0.22)
if let g = NSGradient(colors: [NSColor.systemBlue, NSColor.systemIndigo]) {
    g.draw(in: path, angle: -90)
} else {
    NSColor.systemBlue.setFill(); path.fill()
}
if let glyph = glyph {
    let gw = glyph.size.width, gh = glyph.size.height
    glyph.draw(in: NSRect(x: (s - gw) / 2, y: (s - gh) / 2, width: gw, height: gh))
}

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("png encode failed\n".data(using: .utf8)!); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("icon written: \(outPath) (\(side)px)")
