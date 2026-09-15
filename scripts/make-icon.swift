// 生成 App 图标（iconset），由 scripts/build_app.sh 调用。
// 用法: swift scripts/make_icon.swift <output.iconset 目录>

import AppKit
import Foundation

let canvas: CGFloat = 1024

func makeImage(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawIcon(u: CGFloat(pixels) / canvas)
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawIcon(u: CGFloat) {
    func s(_ value: CGFloat) -> CGFloat { value * u }
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: s(x), y: s(y)) }
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: s(x), y: s(y), width: s(w), height: s(h))
    }

    // 外底板（macOS 图标规范：内容留出约 10% 边距）
    let plate = rect(62, 62, 900, 900)
    let platePath = roundedRect(plate, radius: s(205))

    let shadow = NSShadow()
    shadow.shadowColor = color(0x1B1E3C, 0.35)
    shadow.shadowBlurRadius = s(26)
    shadow.shadowOffset = NSSize(width: 0, height: s(-10))
    shadow.set()
    let gradient = NSGradient(starting: color(0x5C7CFA), ending: color(0x8B5CF6))
    gradient?.draw(in: platePath, angle: -60)
    NSGraphicsContext.current?.saveGraphicsState()
    NSShadow().set()
    NSGraphicsContext.current?.restoreGraphicsState()

    // 高光
    NSGraphicsContext.saveGraphicsState()
    platePath.addClip()
    NSGradient(starting: color(0xFFFFFF, 0.22), ending: color(0xFFFFFF, 0.0))?
        .draw(in: rect(62, 520, 900, 442), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // ---- 左侧：PDF 文档 ----
    let sheet = rect(214, 268, 320, 430)
    let sheetPath = roundedRect(sheet, radius: s(26))
    NSGraphicsContext.saveGraphicsState()
    let sheetShadow = NSShadow()
    sheetShadow.shadowColor = color(0x0B1030, 0.30)
    sheetShadow.shadowBlurRadius = s(22)
    sheetShadow.shadowOffset = NSSize(width: 0, height: s(-8))
    sheetShadow.set()
    NSColor.white.setFill()
    sheetPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 右上角折角
    let foldSize: CGFloat = 96
    let fold = NSBezierPath()
    fold.move(to: pt(534 - foldSize, 698))
    fold.line(to: pt(534, 698 + foldSize))
    fold.line(to: pt(534, 698))
    fold.close()
    color(0xD8DEF7).setFill()
    fold.fill()

    // 文档里的文字线条
    color(0xC3CBE4).setFill()
    for index in 0..<4 {
        let y: CGFloat = 606 - CGFloat(index) * 52
        roundedRect(rect(254, y, index == 3 ? 130 : 240, 26), radius: s(13)).fill()
    }

    // PDF 徽标
    let badge = rect(254, 306, 150, 72)
    color(0xE23B3B).setFill()
    roundedRect(badge, radius: s(16)).fill()
    let label = "PDF" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s(44), weight: .heavy),
        .foregroundColor: NSColor.white
    ]
    let labelSize = label.size(withAttributes: attributes)
    label.draw(
        at: pt(254 + (150 - labelSize.width) / 2, 306 + (72 - labelSize.height) / 2),
        withAttributes: attributes
    )

    // ---- 右侧：图片卡片 ----
    let card = rect(470, 196, 374, 350)
    let cardPath = roundedRect(card, radius: s(30))
    NSGraphicsContext.saveGraphicsState()
    let cardShadow = NSShadow()
    cardShadow.shadowColor = color(0x0B1030, 0.32)
    cardShadow.shadowBlurRadius = s(24)
    cardShadow.shadowOffset = NSSize(width: 0, height: s(-10))
    cardShadow.set()
    NSColor.white.setFill()
    cardPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    let inner = rect(494, 220, 326, 302)
    roundedRect(inner, radius: s(18)).addClip()

    // 天空
    NSGradient(starting: color(0x8FD3FF), ending: color(0xD9F0FF))?
        .draw(in: inner, angle: -90)

    // 太阳
    color(0xFFD166).setFill()
    NSBezierPath(ovalIn: rect(736, 424, 62, 62)).fill()

    // 山
    let back = NSBezierPath()
    back.move(to: pt(494, 220))
    back.line(to: pt(620, 384))
    back.line(to: pt(742, 220))
    back.close()
    color(0x4C9A6B).setFill()
    back.fill()

    let front = NSBezierPath()
    front.move(to: pt(648, 220))
    front.line(to: pt(776, 402))
    front.line(to: pt(820, 330))
    front.line(to: pt(820, 220))
    front.close()
    color(0x35785A).setFill()
    front.fill()

    NSGraphicsContext.restoreGraphicsState()

    // ---- 中间箭头 ----
    let arrow = NSBezierPath()
    arrow.move(to: pt(556, 470))
    arrow.line(to: pt(606, 520))
    arrow.line(to: pt(556, 570))
    arrow.line(to: pt(556, 534))
    arrow.line(to: pt(502, 534))
    arrow.line(to: pt(502, 506))
    arrow.line(to: pt(556, 506))
    arrow.close()

    NSGraphicsContext.saveGraphicsState()
    let arrowShadow = NSShadow()
    arrowShadow.shadowColor = color(0x0B1030, 0.35)
    arrowShadow.shadowBlurRadius = s(14)
    arrowShadow.shadowOffset = NSSize(width: 0, height: s(-4))
    arrowShadow.set()
    NSColor.white.setFill()
    arrow.fill()
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - 主流程

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("用法: swift make_icon.swift <输出目录>\n".data(using: .utf8)!)
    exit(1)
}

let outputURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for variant in variants {
    guard let data = makeImage(pixels: variant.pixels) else {
        FileHandle.standardError.write("渲染 \(variant.name) 失败\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: outputURL.appendingPathComponent(variant.name))
}

print("已生成 \(variants.count) 个图标尺寸 → \(outputURL.path)")
