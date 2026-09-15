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
