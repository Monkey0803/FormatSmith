import CoreGraphics
import Foundation

/// 预览会话：把「每张图的解码与人像分析」缓存下来。
///
/// 界面每改一次参数就要重画一次预览。证件照要跑 Vision，一张 12MP 照片约 110ms，
/// 每次都重跑会让拖动参数发卡；缓存之后重新合成只要几毫秒。
public final class OutputPreviewSession: @unchecked Sendable {

    private let lock = NSLock()
    private var idPhotoSessions: [String: IDPhotoSession] = [:]

    public init() {}

    /// 按真实管线渲染第一份输出的预览。
    public func render(
        documents: [SourceDocument],
        target: OutputTarget,
        settings: ConversionSettings,
        maxPixels: Int = OutputPreview.defaultMaxPixels
    ) throws -> OutputPreview.Result {
        // 尺寸与页数决定预览的尺寸说明和页数统计；
        // 调用方给的文件未必探测过，这里补一次（只读元数据，不解码像素）。
        let documents = documents.map(OutputPreview.inspected)
        guard let first = documents.first else {
            throw ConversionError(Localized.text("There is nothing to convert."))
        }

        let plan = ConversionRouter.plan(input: first.kind, target: target)
        guard plan.isReady else {
            throw ConversionError(Localized.text("This combination is not supported."))
        }

        switch plan.kind {
        case .imagesToImages:
            return try OutputPreview.previewImage(
                document: first, settings: settings, maxPixels: maxPixels, session: self
            )

        case .imageToPDF, .imagesToOnePDF:
            return try OutputPreview.previewPDFPage(
                documents: documents, settings: settings, maxPixels: maxPixels, session: self
            )

        case .pdfPagesToImages:
            return try OutputPreview.previewRenderedPage(
                document: first, settings: settings, maxPixels: maxPixels
            )

        case .pdfToolbox:
            return try OutputPreview.previewToolboxPage(
                document: first, settings: settings, maxPixels: maxPixels
            )

        case .documentToPDF:
            return try OutputPreview.previewDocumentPage(
                document: first, settings: settings, maxPixels: maxPixels
            )
        }
    }

    /// 同一张图复用同一个分析会话。
    func idPhotoSession(for url: URL) throws -> IDPhotoSession {
        lock.lock()
        if let existing = idPhotoSessions[url.path] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let created = try IDPhotoSession(url: url)

        lock.lock()
        idPhotoSessions[url.path] = created
        lock.unlock()
        return created
    }
}

/// 生成「这份输出长什么样」的预览。
///
/// 存在的理由是用户看不到结果就只能靠猜：图片转 PDF 之后版面如何、PDF 转图片之后
/// 清晰度如何，都不该等到导出完才发现不对。
///
/// 两条原则：
/// - **走真实管线**：预览调用的是导出时同一段版面计算（`PDFComposer.drawPage`、
///   `IDPhotoSession`），尺寸可以缩小成缩略图，构图不会变。
/// - **说真实尺寸**：缩略图只是看着小，说明文字里给的是导出后的真实像素/磅值。
public enum OutputPreview {

    public enum Kind: Equatable, Sendable {
        /// 图片 → 图片（含证件照、相纸排版）
        case image
        /// PDF 页面（图片 → PDF、PDF 工具箱、文档 → PDF）
        case pdfPage
        /// PDF → 图片
        case renderedPage
    }

    public struct Result: Sendable {
        /// 预览图（缩略图，可能小于真实输出）。
        public let image: CGImage
        /// 这份输出的类型，界面据此决定要不要铺白底等。
        public let kind: Kind
        /// 展示对象的真实尺寸说明，例如「295 × 413 px」或「595 × 842 pt」。
        public let caption: String
        /// 需要注意的提示（没人像、页数被裁剪等）。
        public let notes: [String]
        /// 这批输入会产出多少份文件。
        public let fileCount: Int
        /// 首份输出有多少页。
        public let pageCount: Int

        public init(
            image: CGImage,
            kind: Kind,
            caption: String,
            notes: [String] = [],
            fileCount: Int = 1,
            pageCount: Int = 1
        ) {
            self.image = image
            self.kind = kind
            self.caption = caption
            self.notes = notes
            self.fileCount = fileCount
            self.pageCount = pageCount
        }
    }

    /// 预览时缩略图的像素上限。真实的输出尺寸会写在 `caption` 里。
    public static let defaultMaxPixels = 1_200_000

    /// 一次性预览：不做任何缓存，适合测试与单次调用。
    public static func render(
        documents: [SourceDocument],
        target: OutputTarget,
        settings: ConversionSettings,
        maxPixels: Int = defaultMaxPixels
    ) throws -> Result {
        try OutputPreviewSession().render(
            documents: documents,
            target: target,
            settings: settings,
            maxPixels: maxPixels
        )
    }

    /// 文档 → PDF 需要真正转换一次，界面据此决定要不要等用户停下来再预览。
    public static func isExpensive(documents: [SourceDocument], target: OutputTarget) -> Bool {
        guard let first = documents.first else { return false }
        return ConversionRouter.plan(input: first.kind, target: target).kind == .documentToPDF
    }

    // MARK: - 各管线的渲染（由 OutputPreviewSession 调用）

    fileprivate static func previewImage(
        document: SourceDocument,
        settings: ConversionSettings,
        maxPixels: Int,
        session: OutputPreviewSession
    ) throws -> Result {
        // 证件照与相纸排版的尺寸由规格决定，本身就不大，走缓存的会话
        if settings.idPhotoEnabled {
            let session = try session.idPhotoSession(for: document.url)
            let outcome = try renderIDPhoto(session: session, settings: settings)
            var caption = OutputPreview.sizeCaption(outcome.image)
            if settings.printSheetEnabled {
                caption = OutputPreview.sizeCaption(outcome.image)
            }
            return Result(
                image: outcome.image,
                kind: .image,
                caption: caption,
                notes: outcome.notes,
                fileCount: 1,
                pageCount: 1
            )
        }

        let pixels = settings.estimatedPixelSize(for: info(of: document))
        guard let pixels else {
            throw ConversionError(Localized.text("This combination is not supported."))
        }

        // 预览时按上限缩小解码，但说明里给的是真实输出尺寸
        let area = Double(pixels.width * pixels.height)
        let shrink = area > Double(maxPixels) ? (Double(maxPixels) / area).squareRoot() : 1
        let decoded = try ImageDecoder.decode(
            url: document.url,
            scale: settings.imageScale * shrink,
            maxPixels: settings.maxPixels
        )
        let prepared = try ImageEncoder.prepare(
            decoded,
            for: settings.format,
            background: settings.background
        )

        return Result(
            image: prepared,
            kind: .image,
            caption: "\(pixels.width) × \(pixels.height) px",
            fileCount: 1,
            pageCount: 1
        )
    }

    fileprivate static func renderIDPhoto(
        session: IDPhotoSession,
        settings: ConversionSettings
    ) throws -> IDPhotoProcessor.Outcome {
        let outcome = try session.render(
            size: settings.idPhotoSize,
            background: settings.idPhotoBackground,
            dpi: settings.dpi,
            autoCrop: settings.idPhotoAutoCrop
        )
        guard settings.printSheetEnabled else { return outcome }

        let sheet = try PhotoSheetTiler.render(
            photo: outcome.image,
            photoSize: settings.idPhotoSize,
            sheet: settings.printSheet,
            dpi: settings.dpi,
            marginMM: settings.printSheetMarginMM,
            gapMM: settings.printSheetGapMM,
            cutGuides: settings.printSheetCutGuides
        )
        return IDPhotoProcessor.Outcome(
            image: sheet,
            replacedBackground: outcome.replacedBackground,
            usedFace: outcome.usedFace,
            notes: outcome.notes
        )
    }

    // MARK: - 图片 → PDF

    fileprivate static func previewPDFPage(
        documents: [SourceDocument],
        settings: ConversionSettings,
        maxPixels: Int,
        session: OutputPreviewSession
    ) throws -> Result {
        // 一页可能排两张（证件扫描件），所以取够第一页需要的张数
        let perPage = settings.pdfLayout.imagesPerPage
        let selected = Array(documents.prefix(max(perPage, 1)))

        let images = try selected.map { document -> CGImage in
            if settings.idPhotoEnabled {
                return try session.idPhotoSession(for: document.url).render(
                    size: settings.idPhotoSize,
                    background: settings.idPhotoBackground,
                    dpi: settings.dpi,
                    autoCrop: settings.idPhotoAutoCrop
                ).image
            }
            return try ImageDecoder.decode(
                url: document.url,
                scale: settings.imageScale,
                maxPixels: settings.maxPixels
            )
        }

        let sheet = try PDFComposer.previewPage(images: images, settings: settings, maxPixels: maxPixels)
        let box = PDFComposer.pageBox(for: images, settings: settings)
        let pageCount = settings.pdfLayout.pageCount(forImageCount: documents.count)

        return Result(
            image: sheet,
            kind: .pdfPage,
            caption: "\(Int(box.width.rounded())) × \(Int(box.height.rounded())) pt",
            fileCount: 1,
            pageCount: max(pageCount, 1)
        )
    }

    // MARK: - PDF → 图片

    fileprivate static func previewRenderedPage(
        document: SourceDocument,
        settings: ConversionSettings,
        maxPixels: Int
    ) throws -> Result {
        let pdf = try PDFRasterizer.open(document.url)
        guard let page = pdf.page(at: 1) else {
            throw ConversionError(Localized.text("This PDF has no pages."))
        }

        let pixels = settings.estimatedPixelSize(for: info(of: document))
        guard let pixels else {
            throw ConversionError(Localized.text("This combination is not supported."))
        }

        // 真实输出可能很大，预览时只按上限渲染，说明里仍给真实尺寸
        let area = Double(pixels.width * pixels.height)
        let shrink = area > Double(maxPixels) ? (Double(maxPixels) / area).squareRoot() : 1

        let image = try PDFRasterizer.render(
            page: page,
            scale: settings.effectiveScale * shrink,
            background: settings.background,
            format: settings.format,
            maxPixels: settings.maxPixels
        )

        let pageCount = settings.pages(outOf: document.pageCount).count
        return Result(
            image: image,
            kind: .renderedPage,
            caption: "\(pixels.width) × \(pixels.height) px",
            fileCount: max(pageCount, 1),
            pageCount: max(pageCount, 1)
        )
    }

    // MARK: - PDF 工具箱

    fileprivate static func previewToolboxPage(
        document: SourceDocument,
        settings: ConversionSettings,
        maxPixels: Int
    ) throws -> Result {
        let pdf = try PDFRasterizer.open(document.url)
        guard let page = pdf.page(at: 1) else {
            throw ConversionError(Localized.text("This PDF has no pages."))
        }

        let image = try PDFRasterizer.render(
            page: page,
            scale: PDFRasterizer.previewScale(
                for: page,
                desired: settings.effectiveScale,
                maxPixels: maxPixels
            ),
            background: settings.background,
            format: settings.format,
            maxPixels: settings.maxPixels
        )

        let box = page.getBoxRect(.mediaBox)
        let rotated = settings.rotationAngle.rawValue % 180 != 0
        let shownWidth = rotated ? box.height : box.width
        let shownHeight = rotated ? box.width : box.height
        let caption = "\(Int(shownWidth.rounded())) × \(Int(shownHeight.rounded())) pt"

        return Result(
            image: image,
            kind: .pdfPage,
            caption: caption,
            notes: [settings.pdfTool.summary],
            fileCount: 1,
            pageCount: document.pageCount
        )
    }

    // MARK: - 文档 → PDF

    fileprivate static func previewDocumentPage(
        document: SourceDocument,
        settings: ConversionSettings,
        maxPixels: Int
    ) throws -> Result {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormatSmithPreview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let produced = directory.appendingPathComponent("preview.pdf")
        _ = try DocumentConverter.convert(
            url: document.url,
            kind: document.kind,
            to: produced
        )

        let pdf = try PDFRasterizer.open(produced)
        guard let page = pdf.page(at: 1) else {
            throw ConversionError(Localized.text("This PDF has no pages."))
        }

        let image = try PDFRasterizer.render(
            page: page,
            scale: PDFRasterizer.previewScale(for: page, desired: 1, maxPixels: maxPixels),
            background: .white,
            format: .png,
            maxPixels: settings.maxPixels
        )

        let box = page.getBoxRect(.mediaBox)
        let caption = "\(Int(box.width.rounded())) × \(Int(box.height.rounded())) pt"
        let pageCount = settings.pages(outOf: pdf.numberOfPages).count

        return Result(
            image: image,
            kind: .pdfPage,
            caption: caption,
            fileCount: 1,
            pageCount: max(pageCount, 1)
        )
    }

    // MARK: - 工具

    /// 补齐尺寸与页数；已经探测过的原样返回。
    fileprivate static func inspected(_ document: SourceDocument) -> SourceDocument {
        guard document.size.width <= 0 || (document.kind == .pdf && document.pageCount <= 0) else {
            return document
        }
        let info = ConversionEngine.inspect(document.url)
        return document.with(info: info)
    }

    fileprivate static func info(of document: SourceDocument) -> DocumentInfo {
        DocumentInfo(
            kind: document.kind,
            pageCount: document.pageCount,
            displaySize: document.size
        )
    }

    fileprivate static func sizeCaption(_ image: CGImage) -> String {
        "\(image.width) × \(image.height) px"
    }
}
