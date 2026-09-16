import CoreGraphics
import Foundation
import ImageIO

/// 把图片写成 PDF。
///
/// 用 `CGPDFContext` 而不是 ImageIO 的 PDF 输出，因为需要控制页面尺寸、页边距，
/// 以及「一页放几张」——ImageIO 只会把像素尺寸直接当成点尺寸，一张图一页。
public enum PDFComposer {

    /// 把图片写成 PDF。
    ///
    /// - Parameters:
    ///   - images: 图片序列，顺序即阅读顺序。
    ///   - url: 目标路径；已存在时不会覆盖。
    ///   - onPageWritten: 每写完一页回调一次（已写页数, 总页数）。
    /// - Returns: 实际写入的路径。
    @discardableResult
    public static func compose(
        images: [CGImage],
        settings: ConversionSettings,
        to url: URL,
        cancellation: CancellationFlag = CancellationFlag(),
        onPageWritten: ((Int, Int) -> Void)? = nil
    ) throws -> URL {
        guard !images.isEmpty else {
            throw ConversionError(Localized.text("There is nothing to convert."))
        }

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = OutputNaming.uniqueURL(url)

        let perPage = settings.pdfLayout.imagesPerPage
        let sheets = stride(from: 0, to: images.count, by: perPage).map {
            Array(images[$0..<min($0 + perPage, images.count)])
        }

        // 上下文创建时必须给一个 mediaBox；每页会用页面字典里的 box 覆盖它。
        var defaultBox = CGRect(origin: .zero, size: CGSize(width: 595.28, height: 841.89))
        guard let context = CGContext(target as CFURL, mediaBox: &defaultBox, nil) else {
            throw ConversionError(Localized.text("Could not create the PDF context."))
        }

        for (index, sheet) in sheets.enumerated() {
            if cancellation.isCancelled {
                context.closePDF()
                try? FileManager.default.removeItem(at: target)
                throw ConversionError(Localized.text("Cancelled."))
            }

            let prepared = sheet.map { embeddable($0, settings: settings) }
            let box = pageBox(for: prepared, settings: settings)

            var mutableBox = box
            let boxData = NSData(bytes: &mutableBox, length: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)

            context.interpolationQuality = .high
            for (slot, image) in prepared.enumerated() {
                let area = contentArea(forSlot: slot, of: prepared.count, in: box, settings: settings)
                context.draw(image, in: placement(for: image, in: area))
            }

            context.endPDFPage()
            onPageWritten?(index + 1, sheets.count)
        }

        context.closePDF()
        return target
    }

    // MARK: - 版面计算

    /// 页面尺寸（点）。
    ///
    /// 一页一张且选了「跟随图片」时，页面就是图片尺寸（1 像素 = 1 点）；
    /// 一页多张必须有固定纸张，否则没有共同基准。
    static func pageBox(for images: [CGImage], settings: ConversionSettings) -> CGRect {
        if images.count > 1 {
            let fixed = settings.pdfPageSize.pointSize ?? CGSize(width: 595.28, height: 841.89)
            return CGRect(origin: .zero, size: fixed)
        }
        if let fixed = settings.pdfPageSize.pointSize {
            return CGRect(origin: .zero, size: fixed)
        }
        guard let first = images.first else { return CGRect(x: 0, y: 0, width: 595.28, height: 841.89) }
        return CGRect(x: 0, y: 0, width: first.width, height: first.height)
    }

    /// 一张图在页面上分到的区域（已扣掉页边距）；两张时上下平分。
    static func contentArea(
        forSlot slot: Int,
        of count: Int,
        in box: CGRect,
        settings: ConversionSettings
    ) -> CGRect {
        let margin = settings.pdfPageSize.pointSize == nil && count == 1 ? 0 : max(0, settings.pdfMargin)
        let available = box.insetBy(dx: margin, dy: margin)
        guard available.width > 0, available.height > 0 else { return box }
        guard count > 1 else { return available }

        // 两张之间留出和页边距同宽的分隔
        let gap = margin
        let slotHeight = (available.height - gap * CGFloat(count - 1)) / CGFloat(count)
        guard slotHeight > 0 else { return available }

        // 第 0 张在上面：原点在左下，所以靠上的槽位 y 更大
        let fromTop = CGFloat(slot)
        let y = available.maxY - slotHeight * (fromTop + 1) - gap * fromTop
        return CGRect(x: available.minX, y: y, width: available.width, height: slotHeight)
    }

    /// 图片在给定区域里等比缩放并居中。
    static func placement(for image: CGImage, in area: CGRect) -> CGRect {
        guard area.width > 0, area.height > 0 else { return area }
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        guard imageWidth > 0, imageHeight > 0 else { return area }

        let scale = min(area.width / imageWidth, area.height / imageHeight)
        let width = imageWidth * scale
        let height = imageHeight * scale
        return CGRect(
            x: area.midX - width / 2,
            y: area.midY - height / 2,
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
