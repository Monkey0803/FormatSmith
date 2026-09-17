import CoreGraphics
import Foundation

/// PDF 页面光栅化。
///
/// 一个必须记住的坑：**`CGContext.drawPDFPage` 不会应用页面自身的 `/Rotate`**。
/// 想得到「用户在预览里看到的方向」，必须自己乘变换矩阵，见 `pageTransform(rotation:box:)`。
public enum PDFRasterizer {

    // MARK: - 打开文档

    public static func open(_ url: URL) throws -> CGPDFDocument {
        guard let document = CGPDFDocument(url as CFURL) else {
            throw ConversionError.unreadablePDF()
        }
        guard !document.isEncrypted || document.isUnlocked else {
            throw ConversionError.encryptedPDF()
        }
        guard document.numberOfPages > 0 else {
            throw ConversionError.emptyPDF()
        }
        return document
    }

    public static func pageCount(of url: URL) -> Int {
        (CGPDFDocument(url as CFURL))?.numberOfPages ?? 0
    }

    /// 首页在应用旋转后的显示尺寸（PDF 点，1pt = 1/72 inch）。
    public static func pageSize(of url: URL) -> CGSize {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else {
            return .zero
        }
        return displaySize(of: page)
    }

    /// 某页在应用旋转后的显示尺寸。
    public static func displaySize(of page: CGPDFPage) -> CGSize {
        let box = effectiveBox(of: page)
        return isQuarterTurned(page) ? CGSize(width: box.height, height: box.width) : box.size
    }

    // MARK: - 变换

    /// 把页面内容映射到「已按 `/Rotate` 摆正」的输出画布。
    ///
    /// `/Rotate` 表示页面需要顺时针旋转多少度才正确显示，画布尺寸随之交换。
    /// 返回的矩阵直接把页面坐标（含 `box.origin` 偏移）变换到画布坐标：
    ///
    /// | rotation | 映射 | 画布 |
    /// |---|---|---|
    /// | 0   | (x, y) → (x-ox, y-oy)             | w × h |
    /// | 90  | (x, y) → (y-oy, w-x+ox)           | h × w |
    /// | 180 | (x, y) → (w-x+ox, h-y+oy)         | w × h |
    /// | 270 | (x, y) → (h-y+oy, x-ox)           | h × w |
    public static func pageTransform(rotation: Int, box: CGRect) -> CGAffineTransform {
        let ox = box.origin.x
        let oy = box.origin.y
        let w = box.width
        let h = box.height
        switch ((rotation % 360) + 360) % 360 {
        case 90:
            return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -oy, ty: w + ox)
        case 180:
            return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w + ox, ty: h + oy)
        case 270:
            return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h + oy, ty: -ox)
        default:
            return CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: -ox, ty: -oy)
        }
    }

    // MARK: - 渲染

    /// 预览用的缩放系数：按上限缩小，但不放大。
    ///
    /// 真实输出可能是 600 DPI 的巨图，预览没必要照原样渲染一遍。
    public static func previewScale(for page: CGPDFPage, desired: Double, maxPixels: Int) -> Double {
        let box = page.getBoxRect(.mediaBox)
        let area = abs(box.width * box.height) * desired * desired
        guard area > Double(maxPixels), maxPixels > 0 else { return desired }
        return desired * (Double(maxPixels) / area).squareRoot()
    }

    public static func render(
        page: CGPDFPage,
        scale: Double,
        background: ImageBackground,
        format: ImageFormat,
        maxPixels: Int
    ) throws -> CGImage {
        try render(
            page: page,
            scale: scale,
            background: background,
            keepsAlpha: format.supportsAlpha,
            maxPixels: maxPixels
        )
    }

    /// - Parameters:
    ///   - keepsAlpha: 输出是否允许保留透明；false 时强制铺满背景色。
    public static func render(
        page: CGPDFPage,
        scale: Double,
        background: ImageBackground,
        keepsAlpha: Bool,
        maxPixels: Int
    ) throws -> CGImage {
        let box = effectiveBox(of: page)
        guard box.width > 0, box.height > 0 else {
            throw ConversionError(Localized.text("This page has an invalid size."))
        }

        let rotation = Int(((page.rotationAngle % 360) + 360) % 360)
        let swapped = rotation == 90 || rotation == 270
        let canvasWidth = swapped ? box.height : box.width
        let canvasHeight = swapped ? box.width : box.height

        let pixelWidth = Int((canvasWidth * scale).rounded())
        let pixelHeight = Int((canvasHeight * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw ConversionError(Localized.text("The computed output size is invalid. Lower the resolution."))
        }
        guard pixelWidth * pixelHeight <= maxPixels else {
            throw ConversionError.tooManyPixels(pixelWidth, pixelHeight, limit: maxPixels)
        }

        let wantsAlpha = keepsAlpha && background == .transparent
        // 不能保留 alpha 时，「透明」必须退化成实际颜色，否则未绘制区域会变成黑色。
        let effectiveBackground: ImageBackground =
            keepsAlpha
            ? background
            : (background == .black ? .black : .white)

        let context = try BitmapContext.make(width: pixelWidth, height: pixelHeight, wantsAlpha: wantsAlpha)

        if !wantsAlpha {
            context.fill(with: effectiveBackground)
        }

        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.concatenate(pageTransform(rotation: rotation, box: box))
        context.drawPDFPage(page)
        context.restoreGState()

        guard let image = context.makeImage() else {
            throw ConversionError(Localized.text("Rendering failed."))
        }
        return image
    }

    // MARK: - 缩略图

    /// 首页缩略图，用于队列里的预览。
    public static func thumbnail(for url: URL, maxSize: CGFloat) -> CGImage? {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else {
            return nil
        }
        let size = displaySize(of: page)
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(maxSize / size.width, maxSize / size.height)
        return try? render(
            page: page,
            scale: Double(scale),
            background: .white,
            keepsAlpha: false,
            maxPixels: 40_000_000
        )
    }

    // MARK: - 内部

    static func effectiveBox(of page: CGPDFPage) -> CGRect {
        var box = page.getBoxRect(.cropBox)
        if box.width <= 0 || box.height <= 0 {
            box = page.getBoxRect(.mediaBox)
        }
        return box
    }

    static func isQuarterTurned(_ page: CGPDFPage) -> Bool {
        let rotation = Int(((page.rotationAngle % 360) + 360) % 360)
        return rotation == 90 || rotation == 270
    }
}
