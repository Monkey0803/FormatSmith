import CoreGraphics
import Foundation
import ImageIO

/// 把图片写成 PDF。
///
/// 用 `CGPDFContext` 而不是 ImageIO 的 PDF 输出，因为需要控制页面尺寸与页边距 ——
/// ImageIO 只会把像素尺寸直接当成点尺寸。
public enum PDFComposer {

    /// 一个要写进 PDF 的页面。
    public struct Page {
        public let image: CGImage
        public init(image: CGImage) {
            self.image = image
        }
    }

    /// 把图片写成多页 PDF。
    ///
    /// - Parameters:
    ///   - pages: 每一页一张图，顺序即页序。
    ///   - url: 目标路径；已存在时不会覆盖。
    ///   - onPageWritten: 每写完一页回调一次（1 基页号）。
    /// - Returns: 实际写入的路径。
    @discardableResult
    public static func compose(
        pages: [Page],
        settings: ConversionSettings,
        to url: URL,
        cancellation: CancellationFlag = CancellationFlag(),
        onPageWritten: ((Int) -> Void)? = nil
    ) throws -> URL {
        guard !pages.isEmpty else {
            throw ConversionError(Localized.text("There is nothing to convert."))
        }

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = OutputNaming.uniqueURL(url)

        // 上下文创建时必须给一个 mediaBox；每页会用页面字典里的 box 覆盖它。
        var defaultBox = CGRect(origin: .zero, size: CGSize(width: 595.28, height: 841.89))
        guard let context = CGContext(target as CFURL, mediaBox: &defaultBox, nil) else {
            throw ConversionError(Localized.text("Could not create the PDF context."))
        }

        for (index, page) in pages.enumerated() {
            if cancellation.isCancelled {
                context.closePDF()
                try? FileManager.default.removeItem(at: target)
                throw ConversionError(Localized.text("Cancelled."))
            }

            let image = embeddable(page.image, settings: settings)
            let box = pageBox(for: image, settings: settings)

            var mutableBox = box
            let boxData = NSData(bytes: &mutableBox, length: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)

            context.interpolationQuality = .high
            context.draw(image, in: placement(for: image, in: box, settings: settings))

            context.endPDFPage()
            onPageWritten?(index + 1)
        }

        context.closePDF()
        return target
    }

    // MARK: - 版面计算

    /// 页面尺寸（点）。`.fitImage` 时 1 像素 = 1 点。
    static func pageBox(for image: CGImage, settings: ConversionSettings) -> CGRect {
        if let fixed = settings.pdfPageSize.pointSize {
            return CGRect(origin: .zero, size: fixed)
        }
        return CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }

    /// 图片在页面上的绘制矩形：固定页面尺寸下等比缩放并居中。
    static func placement(for image: CGImage, in box: CGRect, settings: ConversionSettings) -> CGRect {
        let margin = settings.pdfPageSize.pointSize == nil ? 0 : max(0, settings.pdfMargin)
        let available = box.insetBy(dx: margin, dy: margin)
        guard available.width > 0, available.height > 0 else { return box }

        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        guard imageWidth > 0, imageHeight > 0 else { return available }

        let scale = min(available.width / imageWidth, available.height / imageHeight)
        let width = imageWidth * scale
        let height = imageHeight * scale
        return CGRect(
            x: available.midX - width / 2,
            y: available.midY - height / 2,
            width: width,
            height: height
        )
    }

    /// 按设置决定是否把图片降级成 JPEG 再嵌入，以换取更小的文件。
    ///
    /// 带透明通道的图片不会被有损压缩：JPEG 存不了 alpha，会把透明区域变成黑块。
    static func embeddable(_ image: CGImage, settings: ConversionSettings) -> CGImage {
        guard settings.pdfCompressesImages, !image.hasAlphaChannel else { return image }
        guard let data = try? ImageEncoder.encode(image, format: .jpeg, quality: settings.pdfImageQuality),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let recompressed = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return image
        }
        return recompressed
    }
}
