import CoreGraphics
import FormatSmithCore
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// 测试用素材，全部在运行时生成并写进临时目录 —— 仓库里不放二进制文件。
enum FixtureFactory {

    /// 测试里用到的固定颜色，便于在输出图里按坐标验证。
    enum Palette {
        static let red = (r: 0.9, g: 0.2, b: 0.2)
        static let blue = (r: 0.1, g: 0.5, b: 0.9)
        static let white = (r: 1.0, g: 1.0, b: 1.0)
        static let black = (r: 0.0, g: 0.0, b: 0.0)
    }

    /// 生成一个临时目录，调用方负责清理。
    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormatSmithTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - PDF

    /// 生成一个确定性的 PDF。
    ///
    /// 页面布局（单位为点，原点在左下）：
    /// - 可选整页背景（`fillBackground` 为 false 时页面大部分区域保持未绘制 → 用于验证透明）
    /// - 红色方块：`x 在 30…130`，`y 在 170…270`
    /// - 蓝色圆：圆心 `(300, 220)`，半径 45
    @discardableResult
    static func makePDF(
        pages: Int = 1,
        size: CGSize = CGSize(width: 400, height: 300),
        fillBackground: Bool = true,
        rotation: Int = 0,
        named name: String = "fixture",
        in directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent("\(name).pdf")
        var mediaBox = CGRect(origin: .zero, size: size)

        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw FixtureError.cannotCreateContext
        }

        for _ in 1...max(pages, 1) {
            context.beginPDFPage(nil)

            if fillBackground {
                context.setFillColor(color(Palette.white))
                context.fill(mediaBox)
            }

            context.setFillColor(color(Palette.red))
            context.fill(CGRect(x: 30, y: 170, width: 100, height: 100))

            context.setFillColor(color(Palette.blue))
            context.fillEllipse(in: CGRect(x: 255, y: 175, width: 90, height: 90))

            context.endPDFPage()
        }
        context.closePDF()

        if rotation != 0 {
            try setRotation(rotation, on: url)
        }
        return url
    }

    /// 用 PDFKit 写入 `/Rotate`（CGPDFContext 不支持直接指定页面旋转）。
    static func setRotation(_ degrees: Int, on url: URL) throws {
        guard let document = PDFDocument(url: url) else { throw FixtureError.cannotOpenPDF }
        for index in 0..<document.pageCount {
            document.page(at: index)?.rotation = degrees
        }
        guard document.write(to: url) else { throw FixtureError.cannotWritePDF }
    }

    // MARK: - 图片

    /// 生成一张确定性的图片：白底 + 左上角红块 + 右下角蓝块。
    @discardableResult
    static func makeImage(
        width: Int = 120,
        height: Int = 80,
        format: ImageFormat = .png,
        named name: String = "fixture",
        in directory: URL
    ) throws -> URL {
        let context = try BitmapContext.make(width: width, height: height, wantsAlpha: false)
        context.fill(with: .white)

        // 左上角红块（位图坐标原点在左下，所以 y 取上半部分）
        context.setFillColor(color(Palette.red))
        context.fill(CGRect(x: 0, y: height / 2, width: width / 4, height: height / 2))

        // 右下角蓝块
        context.setFillColor(color(Palette.blue))
        context.fill(CGRect(x: width * 3 / 4, y: 0, width: width / 4, height: height / 2))

        guard let image = context.makeImage() else { throw FixtureError.cannotCreateContext }
        let url = directory.appendingPathComponent("\(name).\(format.fileExtension)")
        let data = try ImageEncoder.encode(image, format: format, quality: 1.0)
        try data.write(to: url)
        return url
    }

    /// 生成一张「部分区域未绘制」的 PNG，用于验证透明背景。
    @discardableResult
    static func makeTransparentImage(
        width: Int = 100,
        height: Int = 100,
        named name: String = "transparent",
        in directory: URL
    ) throws -> URL {
        let context = try BitmapContext.make(width: width, height: height, wantsAlpha: true)
        // 不铺底，只在中间画一块红
        context.setFillColor(color(Palette.red))
        context.fill(CGRect(x: 40, y: 40, width: 20, height: 20))
        guard let image = context.makeImage() else { throw FixtureError.cannotCreateContext }
        let url = directory.appendingPathComponent("\(name).png")
        let data = try ImageEncoder.encode(image, format: .png, quality: 1.0)
        try data.write(to: url)
        return url
    }

    // MARK: - 工具

    static func color(_ rgb: (r: Double, g: Double, b: Double), alpha: Double = 1) -> CGColor {
        CGColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha)
    }

    enum FixtureError: Error {
        case cannotCreateContext
        case cannotOpenPDF
        case cannotWritePDF
    }
}
