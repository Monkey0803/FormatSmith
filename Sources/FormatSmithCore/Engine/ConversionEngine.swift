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

        case .pdfToolbox:
            return runPDFTool(
                documents: [document],
                tool: settings.pdfTool,
                settings: settings,
                cancellation: cancellation,
                observer: observer,
                fileIndex: fileIndex,
                fileCount: fileCount
            )

        case .documentToPDF:
            return convertDocument(
                document: document,
                settings: settings,
                cancellation: cancellation,
                observer: observer,
                fileIndex: fileIndex,
                fileCount: fileCount
            )

        case .imagesToOnePDF:
            return ConversionResult(
                documentID: document.id,
                error: ConversionError(plan.unavailableReason ?? Localized.text("Not available in this build yet."))
            )
        }
    }

    // MARK: - 批量

    /// 并发转换一批文件。
    ///
    /// 渲染是 CPU 密集的，串行处理一批几十个文件会白白空着多核；
    /// 这里同时跑 `maxConcurrency` 个，其余排队。
    ///
    /// - Returns: 每个输入的结果（顺序不保证，按完成先后返回）。
    public static func convertBatch(
        documents: [SourceDocument],
        target: OutputTarget,
        settings: ConversionSettings,
        cancellation: CancellationFlag,
        maxConcurrency: Int = 4,
        observer: ConversionObserver = .none
    ) async -> [ConversionResult] {
        guard !documents.isEmpty else { return [] }
        let limit = min(max(1, maxConcurrency), documents.count)

        return await withTaskGroup(of: ConversionResult.self) { group in
            var nextIndex = 0

            func submitNext() {
                guard nextIndex < documents.count, !cancellation.isCancelled else { return }
                let index = nextIndex
                let document = documents[index]
                nextIndex += 1
                group.addTask(priority: .userInitiated) {
                    convert(
                        document: document,
                        target: target,
                        settings: settings,
                        cancellation: cancellation,
                        observer: observer,
                        fileIndex: index,
                        fileCount: documents.count
                    )
                }
            }

            for _ in 0..<limit { submitNext() }

            var results: [ConversionResult] = []
            for await result in group {
                results.append(result)
                observer.onFileFinished?(result)
                submitNext()
            }
            return results
        }
    }

    /// 自动并发度：按核数，但不超过 4 —— 再多收益很小，内存却按倍数上涨。
    public static func automaticConcurrency(configured: Int) -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return configured > 0 ? configured : min(cores, 4)
    }

    // MARK: - 文档 → PDF

    /// Office / HTML / Markdown / 纯文本 → PDF。
    public static func convertDocument(
        document: SourceDocument,
        settings: ConversionSettings,
        cancellation: CancellationFlag,
        observer: ConversionObserver = .none,
        fileIndex: Int = 0,
        fileCount: Int = 1
    ) -> ConversionResult {
        let started = Date()
        var folder: URL?

        do {
            if cancellation.isCancelled { throw ConversionError(Localized.text("Cancelled.")) }

            observer.onProgress?(
                ConversionProgress(
                    completedUnits: 0,
                    totalUnits: 1,
                    fileIndex: fileIndex,
                    fileCount: fileCount,
                    documentID: document.id
                )
            )

            let target = try outputFolder(for: document, settings: settings)
            folder = target

            let url = try DocumentConverter.convert(
                url: document.url,
                kind: document.kind,
                to: target.appendingPathComponent(pdfFileName(for: document, settings: settings))
            )

            observer.onProgress?(
                ConversionProgress(
                    completedUnits: 1,
                    totalUnits: 1,
                    fileIndex: fileIndex,
                    fileCount: fileCount,
                    documentID: document.id
                )
            )

            return ConversionResult(
                documentID: document.id,
                outputFiles: [url],
                outputFolder: folder,
                producedCount: PDFRasterizer.pageCount(of: url),
                duration: Date().timeIntervalSince(started)
            )
        } catch {
            return ConversionResult(
                documentID: document.id,
                outputFolder: folder,
                error: Self.conversionError(from: error),
                duration: Date().timeIntervalSince(started)
            )
        }
    }

    // MARK: - PDF 工具箱

    /// 执行 PDF 结构操作。
    ///
    /// - Parameter documents: `.merge` 会把全部输入合成一个文件；其余操作每个输入各自产出一份。
    public static func runPDFTool(
        documents: [SourceDocument],
        tool: PDFTool,
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
                documentID: primaryID,
                error: ConversionError(Localized.text("There is nothing to convert."))
            )
        }

        do {
            switch tool {
            case .merge:
                let folder = try outputFolder(for: first, settings: settings)
                let observerBox = ProgressReporter(observer: observer, fileIndex: fileIndex, fileCount: fileCount)
                let url = try PDFToolkit.merge(
                    urls: documents.map(\.url),
                    to: folder.appendingPathComponent(mergedFileName(for: documents, settings: settings)),
                    cancellation: cancellation,
                    onPageCopied: { done, total in
                        observerBox.report(completed: done, total: total)
                    }
                )
                return ConversionResult(
                    documentID: primaryID,
                    outputFiles: [url],
                    outputFolder: folder,
                    producedCount: documents.count,
                    duration: Date().timeIntervalSince(started),
                    includedDocumentIDs: ids
                )

            case .split:
                let folder = try outputFolder(for: first, settings: settings)
                let observerBox = ProgressReporter(observer: observer, fileIndex: fileIndex, fileCount: fileCount)
                let urls = try PDFToolkit.split(
                    url: first.url,
                    every: settings.splitEveryPages,
                    into: folder,
                    settings: settings,
                    cancellation: cancellation,
                    onPartWritten: { done, total in observerBox.report(completed: done, total: total) }
                )
                return ConversionResult(
                    documentID: primaryID,
                    outputFiles: urls,
                    outputFolder: folder,
                    producedCount: urls.count,
                    duration: Date().timeIntervalSince(started)
                )

            case .extract:
                let folder = try outputFolder(for: first, settings: settings)
                let pageCount = PDFRasterizer.pageCount(of: first.url)
                let pages = settings.pages(outOf: pageCount)
                let observerBox = ProgressReporter(observer: observer, fileIndex: fileIndex, fileCount: fileCount)
                let url = try PDFToolkit.extract(
                    url: first.url,
                    pages: pages,
                    to: folder.appendingPathComponent(pdfFileName(for: first, settings: settings)),
                    cancellation: cancellation,
                    onPageCopied: { done, total in observerBox.report(completed: done, total: total) }
                )
                return ConversionResult(
                    documentID: primaryID,
                    outputFiles: [url],
                    outputFolder: folder,
                    producedCount: pages.count,
                    duration: Date().timeIntervalSince(started)
                )

            case .rotate:
                let folder = try outputFolder(for: first, settings: settings)
                let observerBox = ProgressReporter(observer: observer, fileIndex: fileIndex, fileCount: fileCount)
                let url = try PDFToolkit.rotate(
                    url: first.url,
                    degrees: settings.rotationAngle.rawValue,
                    to: folder.appendingPathComponent(pdfFileName(for: first, settings: settings)),
                    cancellation: cancellation,
                    onPageRotated: { done, total in observerBox.report(completed: done, total: total) }
                )
                return ConversionResult(
                    documentID: primaryID,
                    outputFiles: [url],
                    outputFolder: folder,
                    producedCount: PDFRasterizer.pageCount(of: first.url),
                    duration: Date().timeIntervalSince(started)
                )

            case .compress:
                let folder = try outputFolder(for: first, settings: settings)
                let observerBox = ProgressReporter(observer: observer, fileIndex: fileIndex, fileCount: fileCount)
                let url = try PDFToolkit.compress(
                    url: first.url,
                    settings: settings,
                    to: folder.appendingPathComponent(pdfFileName(for: first, settings: settings)),
                    cancellation: cancellation,
                    onPageWritten: { done, total in observerBox.report(completed: done, total: total) }
                )
                return ConversionResult(
                    documentID: primaryID,
                    outputFiles: [url],
                    outputFolder: folder,
                    producedCount: PDFRasterizer.pageCount(of: first.url),
                    duration: Date().timeIntervalSince(started)
                )
            }
        } catch {
            return ConversionResult(
                documentID: primaryID,
                error: Self.conversionError(from: error),
                duration: Date().timeIntervalSince(started),
                includedDocumentIDs: ids
            )
        }
    }

    /// 合并输出的文件名。
    ///
    /// 合并 PDF 时若沿用它自己的名字会得到「a.pdf → a.pdf」这种让人困惑的结果，
    /// 因此当展开结果与第一个输入同名时补一个 -merged。
    static func mergedFileName(for documents: [SourceDocument], settings: ConversionSettings) -> String {
        let base = OutputNaming.expand(
            pattern: settings.filenamePattern,
            documentName: documents.first?.displayName ?? "output",
            page: nil,
            pageCount: documents.count,
            padsPageNumbers: settings.padsPageNumbers
        )
        if documents.count > 1, base == documents.first?.displayName {
            return "\(base)-merged.pdf"
        }
        return "\(base).pdf"
    }

    /// 单文件 PDF 输出的文件名。
    static func pdfFileName(for document: SourceDocument, settings: ConversionSettings) -> String {
        let base = OutputNaming.expand(
            pattern: settings.filenamePattern,
            documentName: document.displayName,
            page: nil,
            pageCount: nil,
            padsPageNumbers: settings.padsPageNumbers
        )
        return "\(base).pdf"
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
                ConversionProgress(
                    completedUnits: 0,
                    totalUnits: 1,
                    fileIndex: fileIndex,
                    fileCount: fileCount,
                    documentID: document.id
                )
            )

            var notes: [String] = []
            var prepared: CGImage

            if settings.idPhotoEnabled {
                // 证件照：尺寸与底色由证件规格决定，缩放设置不参与
                let outcome = try IDPhotoProcessor.makeIDPhoto(
                    from: document.url,
                    size: settings.idPhotoSize,
                    background: settings.idPhotoBackground,
                    dpi: settings.dpi,
                    autoCrop: settings.idPhotoAutoCrop
                )
                prepared = outcome.image
                // 提示由处理器给出，预览与实际转换用的是同一套文案
                notes.append(contentsOf: outcome.notes)
            } else {
                let decoded = try ImageDecoder.decode(
                    url: document.url,
                    scale: settings.imageScale,
                    maxPixels: settings.maxPixels
                )
                // 目标格式存不了透明通道时先铺底，避免透明区域变黑。
                prepared = try ImageEncoder.prepare(
                    decoded,
                    for: settings.format,
                    background: settings.background
                )
            }

            // 相纸排版：把做好的证件照在相纸上排满
            if settings.idPhotoEnabled, settings.printSheetEnabled {
                prepared = try PhotoSheetTiler.render(
                    photo: prepared,
                    photoSize: settings.idPhotoSize,
                    sheet: settings.printSheet,
                    dpi: settings.dpi,
                    marginMM: settings.printSheetMarginMM,
                    gapMM: settings.printSheetGapMM,
                    cutGuides: settings.printSheetCutGuides
                )
            }

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
                ConversionProgress(
                    completedUnits: 1,
                    totalUnits: 1,
                    fileIndex: fileIndex,
                    fileCount: fileCount,
                    documentID: document.id
                )
            )

            return ConversionResult(
                documentID: document.id,
                outputFiles: written,
                outputFolder: folder,
                producedCount: written.count,
                duration: Date().timeIntervalSince(started),
                notes: notes
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
            var pages: [CGImage] = []
            for (offset, document) in documents.enumerated() {
                if cancellation.isCancelled { throw ConversionError(Localized.text("Cancelled.")) }
                // 图片按原始像素嵌入：DPI 是给 PDF 页面用的概念，
                // 套到图片上会让「默认 200 DPI」悄悄把照片放大 2.78 倍。
                let image = try ImageDecoder.decode(
                    url: document.url, scale: 1, maxPixels: settings.maxPixels)
                pages.append(image)
                observer.onProgress?(
                    ConversionProgress(
                        completedUnits: offset + 1,
                        totalUnits: documents.count,
                        fileIndex: fileIndex,
                        fileCount: fileCount,
                        documentID: document.id
                    )
                )
            }

            let folder = try outputFolder(for: first, settings: settings)
            let fileName = mergedFileName(for: documents, settings: settings)
            let url = try PDFComposer.compose(
                images: pages,
                settings: settings,
                to: folder.appendingPathComponent(fileName),
                cancellation: cancellation
            )

            return ConversionResult(
                documentID: primaryID,
                outputFiles: [url],
                outputFolder: folder,
                // 一页可能放两张，所以「产出页数」要按版面算
                producedCount: settings.pdfLayout.pageCount(forImageCount: pages.count),
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
                        fileCount: fileCount,
                        documentID: document.id
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
