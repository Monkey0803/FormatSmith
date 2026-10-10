import CoreGraphics
import Foundation
import PDFKit

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
        maxPixels: Int = OutputPreview.defaultMaxPixels,
        /// 识别器可注入：测试用固定结果就能把「文字层怎么铺」单独测清楚，
        /// 也让预览与导出在同一处指定识别方式。
        recognizer: TextRecognizing = VisionTextRecognizer()
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

        case .toText:
            return try OutputPreview.previewText(
                document: first,
                settings: settings,
                maxPixels: maxPixels,
                session: self,
                recognizer: recognizer
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
        /// 导出纯文本：预览的主要内容是文字，不是画面
        case text
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
        /// 纯文本输出时，真正会被写进 .txt 的内容（前面若干行）。
        ///
        /// 预览的意义就是所见即所得：只显示源图等于什么都没告诉用户。
        public let text: String?

        public init(
            image: CGImage,
            kind: Kind,
            caption: String,
            notes: [String] = [],
            fileCount: Int = 1,
            pageCount: Int = 1,
            text: String? = nil
        ) {
            self.image = image
            self.kind = kind
            self.caption = caption
            self.notes = notes
            self.fileCount = fileCount
            self.pageCount = pageCount
            self.text = text
        }
    }

    /// 预览时缩略图的像素上限。真实的输出尺寸会写在 `caption` 里。
    public static let defaultMaxPixels = 1_200_000

    /// 一次性预览：不做任何缓存，适合测试与单次调用。
    public static func render(
        documents: [SourceDocument],
        target: OutputTarget,
        settings: ConversionSettings,
        maxPixels: Int = defaultMaxPixels,
        recognizer: TextRecognizing = VisionTextRecognizer()
    ) throws -> Result {
        try OutputPreviewSession().render(
            documents: documents,
            target: target,
            settings: settings,
            maxPixels: maxPixels,
            recognizer: recognizer
        )
    }

    /// 文档 → PDF 需要真正转换一次，界面据此决定要不要等用户停下来再预览。
    public static func isExpensive(documents: [SourceDocument], target: OutputTarget) -> Bool {
        guard let first = documents.first else { return false }
        let kind = ConversionRouter.plan(input: first.kind, target: target).kind
        // 文档 → PDF 要跑 WebKit/LibreOffice；导出文字要跑 OCR。
        // 两者都由界面用更长的防抖，避免每敲一个字就重算一遍。
        return kind == .documentToPDF || kind == .toText
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
            scale: settings.imageScale(for: document.info) * shrink,
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
                scale: settings.imageScale(for: document.info),
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

    /// 纯文本目标的预览：显示**真正会写进 .txt 的文字**。
    ///
    /// 一开始这里只画源图——那等于什么都没告诉用户，而预览的意义就是所见即所得。
    /// 只处理第一页/第一张：预览跟着设置反复重算，整份识别代价太高。
    /// 取文字的逻辑与导出共用（PDF 走 PDFToolkit.pageText，图片走 ImageTextExporter）。
    fileprivate static func previewText(
        document: SourceDocument,
        settings: ConversionSettings,
        maxPixels: Int,
        session: OutputPreviewSession,
        recognizer: TextRecognizing
    ) throws -> Result {
        // 背景仍用源图/首页，让用户知道看的是哪一页
        let source: Result
        if document.kind.isPDFLike {
            source = try previewToolboxPage(
                document: document, settings: settings, maxPixels: maxPixels
            )
        } else {
            source = try previewImage(
                document: document, settings: settings, maxPixels: maxPixels, session: session
            )
        }

        var extracted = ""
        if document.kind.isPDFLike {
            guard let pdf = PDFDocument(url: document.url),
                let raster = try? PDFRasterizer.open(document.url)
            else { throw ConversionError.unreadablePDF() }

            let wanted = settings.selectedPagesInOrder(outOf: pdf.pageCount)
            if let first = wanted.first {
                extracted =
                    (try? PDFToolkit.pageText(
                        url: document.url, index: first, source: pdf, raster: raster,
                        scale: max(settings.dpi, 72) / 72.0, settings: settings,
                        recognizer: recognizer
                    ).text) ?? ""
            }
        } else {
            extracted =
                (try? ImageTextExporter.recognisedText(
                    url: document.url, recognizer: recognizer
                )) ?? ""
        }

        let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        // 只展示开头一段：预览要的是「对不对」，不是整份文本
        let shown =
            trimmed.count > Self.previewTextLimit
            ? String(trimmed.prefix(Self.previewTextLimit)) + "…"
            : trimmed

        var notes: [String] = []
        if trimmed.isEmpty {
            notes.append(Localized.text("No text was recognised in this page."))
        } else if document.kind.isPDFLike {
            notes.append(
                Localized.text("Only the first selected page is shown here; every selected page is written.")
            )
        }

        return Result(
            image: source.image,
            kind: .text,
            caption: Localized.text("%d page(s) → one .txt", source.pageCount),
            notes: notes,
            fileCount: 1,
            pageCount: source.pageCount,
            text: shown
        )
    }

    /// 预览里最多展示多少个字符。
    static let previewTextLimit = 600

    /// 把一张图按 90 的倍数旋转（预览用）。    /// 把一张图按 90 的倍数旋转（预览用）。
    fileprivate static func rotatedCopy(of image: CGImage, degrees: Int) throws -> CGImage {
        let normalised = ((degrees % 360) + 360) % 360
        guard normalised != 0 else { return image }

        let swaps = normalised % 180 != 0
        let width = swaps ? image.height : image.width
        let height = swaps ? image.width : image.height
        let context = try BitmapContext.make(width: width, height: height, wantsAlpha: true)
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: CGFloat(normalised) * .pi / 180)
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                width: CGFloat(image.width), height: CGFloat(image.height)
            )
        )
        guard let rotated = context.makeImage() else {
            throw ConversionError(Localized.text("Could not rotate the preview."))
        }
        return rotated
    }

    fileprivate static func previewToolboxPage(
        document: SourceDocument,
        settings: ConversionSettings,
        maxPixels: Int
    ) throws -> Result {
        let pdf = try PDFRasterizer.open(document.url)
        let total = pdf.numberOfPages
        guard total > 0 else {
            throw ConversionError(Localized.text("This PDF has no pages."))
        }

        // 预览要画的是**输出后的第一页**，不是输入的第一页：
        // 「提取 3」「重排 3,1」的结果都以别的页开头。
        let sequence = PDFToolkit.outputPageSequence(
            tool: settings.pdfTool, settings: settings, pageCount: total
        )
        guard let firstPageNumber = sequence.first, let page = pdf.page(at: firstPageNumber) else {
            throw ConversionError(Localized.text("No pages were selected."))
        }

        let rendered = try PDFRasterizer.render(
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

        // 旋转工具会把页面转过去，那么预览也得转，否则图和说明互相矛盾
        let rotates = settings.pdfTool == .rotate
        let image =
            rotates
            ? (try rotatedCopy(of: rendered, degrees: settings.rotationAngle.rawValue))
            : rendered

        let box = page.getBoxRect(.mediaBox)
        let swapped =
            (settings.pdfTool == .rotate)
            ? settings.rotationAngle.rawValue % 180 != 0
            : false
        let shownWidth = swapped ? box.height : box.width
        let shownHeight = swapped ? box.width : box.height
        let caption = "\(Int(shownWidth.rounded())) × \(Int(shownHeight.rounded())) pt"

        return Result(
            image: image,
            kind: .pdfPage,
            caption: caption,
            notes: [settings.pdfTool.summary],
            fileCount: 1,
            pageCount: sequence.count
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
