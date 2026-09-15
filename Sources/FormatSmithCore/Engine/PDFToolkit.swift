import CoreGraphics
import Foundation
import PDFKit

/// PDF 工具箱：结构层面的操作，输入输出都是 PDF。
///
/// 合并、拆分、提取、旋转用 PDFKit（它按页操作最直接），压缩则走 Core Graphics
/// 重新栅格化 —— 那是有损的，`PDFTool.compress.isLossy` 会把这件事如实告诉界面。
public enum PDFToolkit {

    // MARK: - 合并

    /// 按给定顺序把多个 PDF 首尾相接。
    @discardableResult
    public static func merge(
        urls: [URL],
        to outputURL: URL,
        cancellation: CancellationFlag = CancellationFlag(),
        onPageCopied: ((Int, Int) -> Void)? = nil
    ) throws -> URL {
        guard !urls.isEmpty else {
            throw ConversionError(Localized.text("There is nothing to convert."))
        }

        let merged = PDFDocument()
        var inserted = 0
        var totalPages = 0
        for url in urls {
            totalPages += PDFRasterizer.pageCount(of: url)
        }

        for url in urls {
            guard let document = PDFDocument(url: url) else {
                throw ConversionError.unreadablePDF()
            }
            for index in 0..<document.pageCount {
                if cancellation.isCancelled {
                    throw ConversionError(Localized.text("Cancelled."))
                }
                guard let page = document.page(at: index) else { continue }
                merged.insert(page, at: inserted)
                inserted += 1
                onPageCopied?(inserted, totalPages)
            }
        }

        guard merged.pageCount > 0 else { throw ConversionError.emptyPDF() }
        return try write(merged, to: outputURL)
    }

    // MARK: - 拆分

    /// 每 `every` 页输出一个 PDF。
    ///
    /// 文件名用「本部分的起始页」编号，例如 10 页文档每 3 页一拆得到
    /// `doc-01.pdf`、`doc-04.pdf`、`doc-07.pdf`、`doc-10.pdf`。
    @discardableResult
    public static func split(
        url: URL,
        every: Int,
        into folder: URL,
        settings: ConversionSettings,
        cancellation: CancellationFlag = CancellationFlag(),
        onPartWritten: ((Int, Int) -> Void)? = nil
    ) throws -> [URL] {
        let chunkSize = max(1, every)
        guard let source = PDFDocument(url: url) else { throw ConversionError.unreadablePDF() }
        let pageCount = source.pageCount
        guard pageCount > 0 else { throw ConversionError.emptyPDF() }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var written: [URL] = []
        let partCount = Int(ceil(Double(pageCount) / Double(chunkSize)))

        for part in 0..<partCount {
            if cancellation.isCancelled { throw ConversionError(Localized.text("Cancelled.")) }

            let start = part * chunkSize
            let end = min(start + chunkSize, pageCount)
            let partDocument = PDFDocument()
            for index in start..<end {
                guard let page = source.page(at: index) else { continue }
                partDocument.insert(page, at: partDocument.pageCount)
            }

            let firstPageNumber = start + 1
            var naming = settings
            naming.filenamePattern = settings.filenamePattern.isEmpty ? "{name}-{page}" : settings.filenamePattern
            let base = OutputNaming.expand(
                pattern: naming.filenamePattern,
                documentName: url.deletingPathExtension().lastPathComponent,
                page: firstPageNumber,
                pageCount: pageCount,
                padsPageNumbers: true
            )
            let target = folder.appendingPathComponent("\(base).pdf")
            written.append(try write(partDocument, to: target))
            onPartWritten?(part + 1, partCount)
        }

        return written
    }

    // MARK: - 提取

    /// 只保留给定页面（1 基），按给定顺序写入一个新 PDF。
    @discardableResult
    public static func extract(
        url: URL,
        pages: [Int],
        to outputURL: URL,
        cancellation: CancellationFlag = CancellationFlag(),
        onPageCopied: ((Int, Int) -> Void)? = nil
    ) throws -> URL {
        guard !pages.isEmpty else { throw ConversionError.emptyPageRange() }
        guard let source = PDFDocument(url: url) else { throw ConversionError.unreadablePDF() }

        let extracted = PDFDocument()
        var copied = 0
        for pageNumber in pages {
            if cancellation.isCancelled { throw ConversionError(Localized.text("Cancelled.")) }
            guard let page = source.page(at: pageNumber - 1) else { continue }
            extracted.insert(page, at: copied)
            copied += 1
            onPageCopied?(copied, pages.count)
        }

        guard extracted.pageCount > 0 else { throw ConversionError.emptyPageRange() }
        return try write(extracted, to: outputURL)
    }

    // MARK: - 旋转

    /// 在原有旋转基础上再转 `degrees` 度。
    @discardableResult
    public static func rotate(
        url: URL,
        degrees: Int,
        to outputURL: URL,
        cancellation: CancellationFlag = CancellationFlag(),
        onPageRotated: ((Int, Int) -> Void)? = nil
    ) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw ConversionError.unreadablePDF() }
        guard document.pageCount > 0 else { throw ConversionError.emptyPDF() }

        let delta = ((degrees % 360) + 360) % 360

        for index in 0..<document.pageCount {
            if cancellation.isCancelled { throw ConversionError(Localized.text("Cancelled.")) }
            guard let page = document.page(at: index) else { continue }
            // PDFKit 的 rotation 可能已经是 90/180/270，这里叠加后再归一化。
            page.rotation = ((page.rotation + delta) % 360 + 360) % 360
            onPageRotated?(index + 1, document.pageCount)
        }

        return try write(document, to: outputURL)
    }

    // MARK: - 压缩

    /// 以较低分辨率重新栅格化每一页。
    ///
    /// ⚠️ 这会丢掉文本层与矢量信息：输出页面变成一张图片。
    /// 界面必须把这件事说清楚，不能让用户以为是无损压缩。
    @discardableResult
    public static func compress(
        url: URL,
        settings: ConversionSettings,
        to outputURL: URL,
        cancellation: CancellationFlag = CancellationFlag(),
        onPageWritten: ((Int, Int) -> Void)? = nil
    ) throws -> URL {
        let document = try PDFRasterizer.open(url)
        let pageCount = document.numberOfPages
        guard pageCount > 0 else { throw ConversionError.emptyPDF() }

        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = OutputNaming.uniqueURL(outputURL)

        var defaultBox = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let context = CGContext(target as CFURL, mediaBox: &defaultBox, nil) else {
            throw ConversionError(Localized.text("Could not create the PDF context."))
        }

        let scale = max(0.05, settings.dpi / 72.0)

        for pageNumber in 1...pageCount {
            if cancellation.isCancelled {
                context.closePDF()
                try? FileManager.default.removeItem(at: target)
                throw ConversionError(Localized.text("Cancelled."))
            }
            guard let page = document.page(at: pageNumber) else { continue }

            let box = PDFRasterizer.effectiveBox(of: page)
            var mutableBox = box
            let boxData = NSData(bytes: &mutableBox, length: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)

            var rendered = try PDFRasterizer.render(
                page: page,
                scale: scale,
                background: settings.background,
                keepsAlpha: false,
                maxPixels: settings.maxPixels
            )
            rendered = PDFComposer.embeddable(rendered, settings: settings)

            // 渲染结果比页面大 scale 倍，画回原页面尺寸即可。
            context.interpolationQuality = .high
            context.draw(rendered, in: box)

            context.endPDFPage()
            onPageWritten?(pageNumber, pageCount)
        }

        context.closePDF()
        return target
    }

    // MARK: - 工具

    /// PDFKit 写出。已存在时不覆盖。
    static func write(_ document: PDFDocument, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = OutputNaming.uniqueURL(url)
        guard document.write(to: target) else {
            throw ConversionError(Localized.text("Could not write the PDF."))
        }
        return target
    }
}
