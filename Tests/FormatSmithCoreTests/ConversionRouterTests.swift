import XCTest
@testable import FormatSmithCore

/// 输入 × 目标 的路由表：这条链路走哪条管线、能不能走。
final class ConversionRouterTests: XCTestCase {

    private let png = InputKind.image(identifier: "public.png")
    private let pdf = InputKind.pdf

    // MARK: - PDF 输入

    func testPDFToImageRoutesToRasterizer() {
        let plan = ConversionRouter.plan(input: .pdf, target: .image(.png))
        XCTAssertEqual(plan.kind, .pdfPagesToImages)
        XCTAssertEqual(plan.availability, .ready)
    }

    func testPDFToUnwritableFormatIsUnsupportedWithReason() throws {
        // WebP 在 macOS 上只能读不能写
        let webp = ImageFormat("org.webmproject.webp")
        guard !webp.isWritableBySystem else { throw XCTSkip("这台机器居然能写 WebP") }

        let plan = ConversionRouter.plan(input: .pdf, target: .image(webp))
        XCTAssertEqual(plan.kind, .pdfPagesToImages)
        guard case let .unsupported(reason) = plan.availability else {
            return XCTFail("应给出不支持的原因，实际 \(plan.availability)")
        }
        XCTAssertTrue(reason.contains("WebP"), "原因里应点名格式: \(reason)")
    }

    func testPDFToPDFRoutesToToolbox() {
        let plan = ConversionRouter.plan(input: .pdf, target: .pdf)
        XCTAssertEqual(plan.kind, .pdfToolbox)
    }

    // MARK: - 图片输入

    func testImageToImageRoutesToReencoder() {
        let plan = ConversionRouter.plan(input: png, target: .image(.jpeg))
        XCTAssertEqual(plan.kind, .imagesToImages)
        XCTAssertEqual(plan.availability, .ready)
    }

    func testSameFormatConversionIsStillAllowed() {
        // 同格式转同格式没有意义，但缩放/背景处理仍是有效需求，所以不拦。
        let plan = ConversionRouter.plan(input: png, target: .image(.png))
        XCTAssertEqual(plan.kind, .imagesToImages)
        XCTAssertTrue(plan.isReady)
    }

    func testImageToPDFRoutesToComposer() {
        let plan = ConversionRouter.plan(input: png, target: .pdf)
        XCTAssertEqual(plan.kind, .imageToPDF)
        XCTAssertTrue(plan.isReady)
    }

    // MARK: - 文档输入

    func testWebBasedDocumentInputsAreAlwaysReady() {
        // HTML / Markdown / 纯文本走系统 WebKit，不需要任何额外安装
        for kind in [InputKind.html, .markdown, .plainText] {
            let plan = ConversionRouter.plan(input: kind, target: .pdf)
            XCTAssertEqual(plan.kind, .documentToPDF)
            XCTAssertEqual(plan.availability, .ready, "\(kind.displayName) 应当可以直接转换")
        }
    }

    func testOfficeInputDependsOnLibreOffice() {
        let office = InputKind.classify(identifier: nil, fileExtension: "docx")
        let plan = ConversionRouter.plan(input: office, target: .pdf)
        XCTAssertEqual(plan.kind, .documentToPDF)

        if ToolLocator.libreOffice().isAvailable {
            XCTAssertEqual(plan.availability, .ready, "装了 LibreOffice 就该能转")
            XCTAssertNil(plan.unavailableReason)
        } else {
            guard case let .unsupported(reason) = plan.availability else {
                return XCTFail("没装 LibreOffice 时应明确说明，实际 \(plan.availability)")
            }
            XCTAssertTrue(reason.contains("LibreOffice"), reason)
            XCTAssertTrue(reason.lowercased().contains("install"), "应告诉用户怎么装: \(reason)")
        }
    }

    func testDocumentToImageExplainsThePDFStep() {
        let plan = ConversionRouter.plan(input: .markdown, target: .image(.png))
        XCTAssertEqual(plan.kind, .documentToPDF)
        guard case let .unsupported(reason) = plan.availability else {
            return XCTFail("应给出不支持的原因，实际 \(plan.availability)")
        }
        XCTAssertTrue(reason.lowercased().contains("pdf"), "应提示先转 PDF: \(reason)")
    }

    // MARK: - 未知输入

    func testUnknownInputIsUnsupported() {
        let plan = ConversionRouter.plan(input: .unknown(identifier: nil), target: .image(.png))
        XCTAssertFalse(plan.isReady)
        XCTAssertNotNil(plan.unavailableReason)
    }

    // MARK: - 整批执行

    func testBatchAvailabilityListsEveryReason() {
        let inputs: [InputKind] = [.pdf, .markdown, .unknown(identifier: "com.example.mystery")]
        let (_, reasons) = ConversionRouter.batchAvailability(inputs: inputs, target: .image(.png))
        XCTAssertEqual(reasons.count, 2, "markdown 与未知类型都应各自给出原因: \(reasons)")
    }

    func testBatchAvailabilityIsCleanWhenEverythingWorks() {
        let (plan, reasons) = ConversionRouter.batchAvailability(inputs: [.pdf, .pdf], target: .image(.png))
        XCTAssertTrue(reasons.isEmpty)
        XCTAssertEqual(plan.kind, .pdfPagesToImages)
    }

    // MARK: - 合并策略

    func testSeveralImagesMergeIntoOnePDFWhenEnabled() {
        let kind = ConversionRouter.strategy(
            inputs: [png, png, png],
            target: .pdf,
            mergesImages: true
        )
        XCTAssertEqual(kind, .imagesToOnePDF)
    }

    func testSeveralImagesStaySeparateWhenMergingIsOff() {
        let kind = ConversionRouter.strategy(
            inputs: [png, png],
            target: .pdf,
            mergesImages: false
        )
        XCTAssertEqual(kind, .imageToPDF)
    }

    func testSingleImageNeverMerges() {
        let kind = ConversionRouter.strategy(inputs: [png], target: .pdf, mergesImages: true)
        XCTAssertEqual(kind, .imageToPDF)
    }

    func testMixedInputWithPDFTargetDoesNotMerge() {
        let kind = ConversionRouter.strategy(inputs: [png, .pdf], target: .pdf, mergesImages: true)
        XCTAssertNil(kind, "混合输入时目标 PDF 路由到工具箱，不是合并")
    }

    func testStrategyIsNilForUnsupportedCombination() {
        let kind = ConversionRouter.strategy(
            inputs: [.markdown],
            target: .image(.png),
            mergesImages: true
        )
        XCTAssertNil(kind)
    }

    // MARK: - 目标模型

    func testOutputTargetRoundTripsThroughSettings() {
        var settings = ConversionSettings()
        settings.target = .image(.heic)
        XCTAssertEqual(settings.target, .image(.heic))
        XCTAssertFalse(settings.producesPDF)
        XCTAssertEqual(settings.format, .heic)

        settings.target = .pdf
        XCTAssertTrue(settings.producesPDF)
        // 切到 PDF 不应丢掉之前选的图片格式
        XCTAssertEqual(settings.format, .heic)

        settings.target = .image(.avif)
        XCTAssertEqual(settings.format, .avif)
        XCTAssertFalse(settings.producesPDF)
    }
}
