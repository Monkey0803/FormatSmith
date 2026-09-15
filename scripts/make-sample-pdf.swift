// 生成一个确定性的多页 PDF，用于冒烟测试与手工验证。
//
// 用法: swift scripts/make-sample-pdf.swift <输出路径> [页数]

import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("usage: make-sample-pdf.swift <output.pdf> [pages]\n".data(using: .utf8)!)
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let pages = arguments.count >= 3 ? (Int(arguments[2]) ?? 3) : 3
let size = CGSize(width: 400, height: 300)
var mediaBox = CGRect(origin: .zero, size: size)

try? FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

guard let context = CGContext(outputURL as CFURL, mediaBox: &mediaBox, nil) else {
    FileHandle.standardError.write("could not create the PDF context\n".data(using: .utf8)!)
    exit(1)
}

for index in 1...max(pages, 1) {
    context.beginPDFPage(nil)

    // 白底
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(mediaBox)

    // 红块：x 30…130, y 170…270
    context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 30, y: 170, width: 100, height: 100))

    // 蓝圆：圆心 (300, 220)，半径 45
    context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
    context.fillEllipse(in: CGRect(x: 255, y: 175, width: 90, height: 90))

    // 页码文字
    let label = "PAGE \(index) / \(pages)"
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 28, weight: .bold),
        .foregroundColor: NSColor.black,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
    context.textPosition = CGPoint(x: 40, y: 100)
    CTLineDraw(line, context)

    context.endPDFPage()
}
context.closePDF()

print(outputURL.path)
