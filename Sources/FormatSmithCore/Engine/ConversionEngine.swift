import CoreGraphics
import Foundation

/// 输入文件的元信息（不解码像素，只读元数据）。
public struct DocumentInfo: Sendable, Equatable {
    public var kind: InputKind
    public var pageCount: Int
    /// PDF 首页显示尺寸（点）或图片显示尺寸（像素）。
    public var displaySize: CGSize
    /// 多帧图片的帧数（GIF 等），普通文件为 1。
    public var frameCount: Int

    public init(kind: InputKind, pageCount: Int, displaySize: CGSize, frameCount: Int = 1) {
        self.kind = kind
        self.pageCount = pageCount
        self.displaySize = displaySize
        self.frameCount = frameCount
    }

    public static let unknown = DocumentInfo(kind: .unknown(identifier: nil), pageCount: 0, displaySize: .zero)
}

/// 转换编排：读元信息、决定输出位置、逐页/逐文件产出、汇报进度。
public enum ConversionEngine {

    static let maxPreviewPixels = 40_000_000

    // MARK: - 元信息

    public static func inspect(_ url: URL) -> DocumentInfo {
        let kind = InputKind.detect(url: url)
        switch kind {
        case .pdf:
            let count = PDFRasterizer.pageCount(of: url)
            return DocumentInfo(kind: kind, pageCount: count, displaySize: PDFRasterizer.pageSize(of: url))
        case .image:
            let frames = ImageDecoder.frameCount(of: url)
            return DocumentInfo(
                kind: kind,
                pageCount: max(frames, 1),
                displaySize: ImageDecoder.displaySize(of: url),
                frameCount: max(frames, 1)
            )
        default:
            // 文档类输入需要外部工具才能知道页数，转换时再确定。
            return DocumentInfo(kind: kind, pageCount: 1, displaySize: .zero)
        }
    }

    // MARK: - 输出位置

    /// 解析并创建本次转换的输出目录。
    public static func outputFolder(
        for document: SourceDocument,
        settings: ConversionSettings
    ) throws -> URL {
        let root = settings.resolvedOutputDirectory
        let folder =
            settings.perFileSubfolder
            ? root.appendingPathComponent(OutputNaming.sanitize(document.displayName), isDirectory: true)
            : root
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - 统一入口

    /// 按输入类型与目标路由到对应管线。
    ///
    /// 这里是「一个转换器」和「一堆转换脚本」的区别：调用方不需要知道
    /// 手里的东西是 PDF 还是图片，只需要说清楚要什么。
    public static func convert(
        document: SourceDocument,
        target: OutputTarget,
        settings: ConversionSettings,
        cancellation: CancellationFlag,
        observer: ConversionObserver = .none,
        fileIndex: Int = 0,
        fileCount: Int = 1
    ) -> ConversionResult {
        let plan = ConversionRouter.plan(input: document.kind, target: target)

        if let reason = plan.unavailableReason {
            return ConversionResult(
                documentID: document.id,
                error: ConversionError(reason)
            )
        }

        switch plan.kind {
        case .pdfPagesToImages:
            return convertPDFToImages(
                document: document,
                settings: settings,
                cancellation: cancellation,
                observer: observer,
                fileIndex: fileIndex,
                fileCount: fileCount
            )

        case .imagesToImages:
            return convertImageToImage(
                document: document,
                settings: settings,
                cancellation: cancellation,
                observer: observer,
                fileIndex: fileIndex,
                fileCount: fileCount
            )

        case .imageToPDF:
            return composePDF(
                documents: [document],
                settings: settings,
                cancellation: cancellation,
                observer: observer,
                fileIndex: fileIndex,
                fileCount: fileCount
            )

        case .documentToPDF, .pdfToolbox, .imagesToOnePDF:
            return ConversionResult(
                documentID: document.id,
                error: ConversionError(plan.unavailableReason ?? Localized.text("Not available in this build yet."))
            )
        }
    }

    // MARK: - 图片 → 图片

    /// 解码、按需缩放，再按目标格式重新编码。
    public static func convertImageToImage(
        document: SourceDocument,
        settings: ConversionSettings,
        cancellation: CancellationFlag,
        observer: ConversionObserver = .none,
        fileIndex: Int = 0,
        fileCount: Int = 1
    ) -> ConversionResult {
        let started = Date()
        var written: [URL] = []
        var folder: URL?

        do {
            if cancellation.isCancelled { throw ConversionError(Localized.text("Cancelled.")) }

            observer.onProgress?(
                ConversionProgress(completedUnits: 0, totalUnits: 1, fileIndex: fileIndex, fileCount: fileCount)
            )

            let decoded = try ImageDecoder.decode(
                url: document.url,
                scale: settings.imageScale,
                maxPixels: settings.maxPixels
            )
            // 目标格式存不了透明通道时先铺底，避免透明区域变黑。
            let prepared = try ImageEncoder.prepare(
                decoded,
                for: settings.format,
                background: settings.background
            )

            let target = try outputFolder(for: document, settings: settings)
            folder = target

            let fileName = OutputNaming.fileName(
                for: document.displayName, page: nil, pageCount: nil, settings: settings)
            let url = try ImageEncoder.write(
                prepared,
                format: settings.format,
                quality: settings.quality,
                to: target.appendingPathComponent(fileName)
            )
            written.append(url)

            observer.onProgress?(
                ConversionProgress(completedUnits: 1, totalUnits: 1, fileIndex: fileIndex, fileCount: fileCount)
            )

            return ConversionResult(
                documentID: document.id,
                outputFiles: written,
                outputFolder: folder,
                producedCount: written.count,
                duration: Date().timeIntervalSince(started)
            )
        } catch {
            return ConversionResult(
                documentID: document.id,
                outputFiles: written,
                outputFolder: folder,
                producedCount: written.count,
                error: Self.conversionError(from: error),
                duration: Date().timeIntervalSince(started)
            )
        }
    }

    // MARK: - 图片 → PDF

    /// 把一张或多张图片写成一个 PDF。传多张即为合并。
    public static func composePDF(
        documents: [SourceDocument],
        settings: ConversionSettings,
        cancellation: CancellationFlag,
        observer: ConversionObserver = .none,
        fileIndex: Int = 0,
        fileCount: Int = 1
    ) -> ConversionResult {
        let started = Date()
        let primaryID = documents.first?.id ?? UUID()
        let ids = documents.map(\.id)

        guard let first = documents.first else {
            return ConversionResult(
                documentID: primaryID, error: ConversionError(Localized.text("There is nothing to convert.")))
        }

        do {
            var pages: [PDFComposer.Page] = []
            for (offset, document) in documents.enumerated() {
                if cancellation.isCancelled { throw ConversionError(Localized.text("Cancelled.")) }
                let image = try ImageDecoder.decode(
                    url: document.url, scale: settings.imageScale, maxPixels: settings.maxPixels)
                pages.append(PDFComposer.Page(image: image))
                observer.onProgress?(
                    ConversionProgress(
                        completedUnits: offset + 1,
                        totalUnits: documents.count,
                        fileIndex: fileIndex,
                        fileCount: fileCount
                    )
                )
            }

            let folder = try outputFolder(for: first, settings: settings)
            let fileName = outputNamingForPDF(
                documents: documents,
                settings: settings
            )
            let url = try PDFComposer.compose(
                pages: pages,
                settings: settings,
                to: folder.appendingPathComponent(fileName),
                cancellation: cancellation
            )

            return ConversionResult(
                documentID: primaryID,
                outputFiles: [url],
                outputFolder: folder,
                producedCount: pages.count,
                duration: Date().timeIntervalSince(started),
                includedDocumentIDs: ids
            )
        } catch {
            return ConversionResult(
                documentID: primaryID,
                error: Self.conversionError(from: error),
                duration: Date().timeIntervalSince(started),
                includedDocumentIDs: ids
            )
        }
    }

    /// 输出 PDF 的文件名：沿用同一套模板，`{page}` 在单文件输出下会被去掉。
    /// 合并多张时把总张数写进 `{total}`。
    static func outputNamingForPDF(documents: [SourceDocument], settings: ConversionSettings) -> String {
        let base = OutputNaming.expand(
            pattern: settings.filenamePattern,
            documentName: documents.first?.displayName ?? "output",
            page: nil,
            pageCount: documents.count,
            padsPageNumbers: settings.padsPageNumbers
        )
        return "\(base).pdf"
    }

    // MARK: - PDF → 图片

    /// 把一个 PDF 的选定页面导出为图片序列。
    public static func convertPDFToImages(
        document: SourceDocument,
        settings: ConversionSettings,
        cancellation: CancellationFlag,
        observer: ConversionObserver = .none,
        fileIndex: Int = 0,
        fileCount: Int = 1
    ) -> ConversionResult {
        let started = Date()
        var written: [URL] = []
        var folder: URL?

        do {
            let pdf = try PDFRasterizer.open(document.url)
            let totalPages = pdf.numberOfPages
            let pages = settings.pages(outOf: totalPages)
            guard !pages.isEmpty else { throw ConversionError.emptyPageRange() }

            let target = try outputFolder(for: document, settings: settings)
            folder = target
            let scale = settings.effectiveScale

            for (offset, pageNumber) in pages.enumerated() {
                if cancellation.isCancelled {
                    return ConversionResult(
                        documentID: document.id,
                        outputFiles: written,
                        outputFolder: folder,
                        producedCount: written.count,
                        error: ConversionError(Localized.text("Cancelled.")),
                        duration: Date().timeIntervalSince(started)
                    )
                }
                guard let page = pdf.page(at: pageNumber) else { continue }

                let image = try PDFRasterizer.render(
                    page: page,
                    scale: scale,
                    background: settings.background,
                    format: settings.format,
                    maxPixels: settings.maxPixels
                )
                let fileName = OutputNaming.fileName(
                    for: document.displayName,
                    page: pageNumber,
                    pageCount: totalPages,
                    settings: settings
                )
                let url = try ImageEncoder.write(
                    image,
                    format: settings.format,
                    quality: settings.quality,
                    to: target.appendingPathComponent(fileName)
                )
                written.append(url)

                observer.onProgress?(
                    ConversionProgress(
                        completedUnits: offset + 1,
                        totalUnits: pages.count,
                        fileIndex: fileIndex,
                        fileCount: fileCount
                    )
                )
            }

            return ConversionResult(
                documentID: document.id,
                outputFiles: written,
                outputFolder: folder,
                producedCount: written.count,
                duration: Date().timeIntervalSince(started)
            )
        } catch {
            return ConversionResult(
                documentID: document.id,
                outputFiles: written,
                outputFolder: folder,
                producedCount: written.count,
                error: Self.conversionError(from: error),
                duration: Date().timeIntervalSince(started)
            )
        }
    }

    // MARK: - 工具

    /// 把任意 Error 收敛成 ConversionError，保证文案统一。
    static func conversionError(from error: Error) -> ConversionError {
        if let conversion = error as? ConversionError { return conversion }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return ConversionError(description)
        }
        return ConversionError(error.localizedDescription)
    }
}
