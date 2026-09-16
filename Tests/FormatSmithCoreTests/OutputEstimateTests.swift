import CoreGraphics
import XCTest
@testable import FormatSmithCore

/// 输出尺寸估算与安全上限。
///
/// 这一组直接对应一个真实误报：开启证件照后，通用估算仍然按「输入尺寸 × 缩放」算，
/// 于是一张 1200 万像素的照片被算成 2.12 亿像素，界面提示「超过安全上限，转换时会被拒绝」，
/// 而实际输出只有 295×413。
final class OutputEstimateTests: XCTestCase {

    private func info(_ kind: InputKind, _ width: CGFloat, _ height: CGFloat, pages: Int = 1) -> DocumentInfo {
        DocumentInfo(kind: kind, pageCount: pages, displaySize: CGSize(width: width, height: height))
    }

    private var phonePhoto: DocumentInfo {
        info(.image(identifier: "public.jpeg"), 4032, 3024)
    }

    private var letterPage: DocumentInfo {
        info(.pdf, 612, 792, pages: 3)
    }

    // MARK: - 证件照

    func testIDPhotoEstimateUsesTheSpecNotTheInputSize() {
        var settings = ConversionSettings()
        settings.idPhotoEnabled = true
        settings.idPhotoSize = .oneInch
        settings.dpi = 300

        let estimate = settings.estimatedPixelSize(for: phonePhoto)
        XCTAssertEqual(estimate?.width, 295)
        XCTAssertEqual(estimate?.height, 413)
        XCTAssertFalse(
            settings.estimateExceedsLimit(for: phonePhoto),
            "一寸证件照只有 0.12MP，不该被判成超过上限"
        )
    }

    func testIDPhotoEstimateFollowsTheChosenSize() {
        var settings = ConversionSettings()
        settings.idPhotoEnabled = true
        settings.dpi = 300

        settings.idPhotoSize = .twoInch
        XCTAssertEqual(settings.estimatedPixelSize(for: phonePhoto)?.width, 413)

        settings.idPhotoSize = .usVisa
        let visa = settings.estimatedPixelSize(for: phonePhoto)
        XCTAssertEqual(visa?.width, 600)
        XCTAssertEqual(visa?.height, 600)
    }

    func testSheetTilingEstimateUsesThePaperSize() {
        var settings = ConversionSettings()
        settings.idPhotoEnabled = true
        settings.printSheetEnabled = true
        settings.printSheet = .sixInch
        settings.dpi = 300

        let estimate = settings.estimatedPixelSize(for: phonePhoto)
        XCTAssertEqual(estimate?.width, 1205)
        XCTAssertEqual(estimate?.height, 1795)
        XCTAssertFalse(settings.estimateExceedsLimit(for: phonePhoto))
    }

    // MARK: - 图片

    func testImageDefaultsToOriginalSize() {
        let settings = ConversionSettings()
        let estimate = settings.estimatedPixelSize(for: phonePhoto)
        XCTAssertEqual(estimate?.width, 4032, "默认就该是原始尺寸，不做放大")
        XCTAssertEqual(estimate?.height, 3024)
        XCTAssertFalse(settings.estimateExceedsLimit(for: phonePhoto))
    }

    func testDPIDoesNotMagnifyImages() {
        // 这是误报的根源：以前 200 DPI 会被图片当成 2.78 倍放大
        var settings = ConversionSettings()
        settings.resolutionMode = .dpi
        settings.dpi = 300

        let estimate = settings.estimatedPixelSize(for: phonePhoto)
        XCTAssertEqual(estimate?.width, 4032, "切到 DPI 也不该改变图片的输出尺寸")
        XCTAssertFalse(settings.estimateExceedsLimit(for: phonePhoto))
    }

    func testLargeImageWithExplicitUpscaleThrowsTheWarning() {
        var settings = ConversionSettings()
        settings.scale = 3
        // 4032×3024 × 3 = 12096×9072 ≈ 110MP，仍在 120MP 以内
        XCTAssertFalse(settings.estimateExceedsLimit(for: phonePhoto))

        settings.scale = 4
        // ×4 就是 1.95 亿像素，确实该拦
        XCTAssertTrue(settings.estimateExceedsLimit(for: phonePhoto))
    }

    func testDownscaleEstimate() {
        var settings = ConversionSettings()
        settings.scale = 0.5
        XCTAssertEqual(settings.estimatedPixelSize(for: phonePhoto)?.width, 2016)
        XCTAssertEqual(settings.estimatedPixelSize(for: phonePhoto)?.height, 1512)
    }

    // MARK: - PDF

    func testPDFEstimateUsesDPI() {
        var settings = ConversionSettings()
        settings.resolutionMode = .dpi
        settings.dpi = 300

        let estimate = settings.estimatedPixelSize(for: letterPage)
        XCTAssertEqual(estimate?.width, 2550)
        XCTAssertEqual(estimate?.height, 3300)
        XCTAssertFalse(settings.estimateExceedsLimit(for: letterPage))

        settings.dpi = 2400
        XCTAssertTrue(settings.estimateExceedsLimit(for: letterPage), "2400 DPI 的 Letter 应有 5 亿像素，必须拦下")
    }

    func testPDFIgnoresTheImageScale() {
        var settings = ConversionSettings()
        settings.scale = 4
        settings.resolutionMode = .dpi
        settings.dpi = 72

        XCTAssertEqual(settings.estimatedPixelSize(for: letterPage)?.width, 612, "PDF 看 DPI，不看图片的倍数")
    }

    // MARK: - 其它输入

    func testDocumentInputsHaveNoEstimateYet() {
        let settings = ConversionSettings()
        XCTAssertNil(settings.estimatedPixelSize(for: info(.markdown, 0, 0)))
        XCTAssertFalse(settings.estimateExceedsLimit(for: info(.markdown, 0, 0)))
    }

    // MARK: - 与真实输出一致

    func testEstimateMatchesTheActualExportedSize() throws {
        // 估算不能只是「看起来合理」，得和真跑出来的文件尺寸一致
        let directory = try FixtureFactory.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let photo = try FixtureFactory.makeImage(width: 4032, height: 3024, named: "big", in: directory)
        var settings = ConversionSettings()
        settings.idPhotoEnabled = true
        settings.idPhotoSize = .oneInch
        settings.dpi = 300
        settings.outputDirectoryPath = directory.path
        settings.perFileSubfolder = false
        settings.filenamePattern = "id"

        let estimate = settings.estimatedPixelSize(for: info(.image(identifier: "public.png"), 4032, 3024))
        let result = ConversionEngine.convert(
            document: SourceDocument.make(from: photo),
            target: .image(.jpeg),
            settings: settings,
            cancellation: CancellationFlag()
        )

        XCTAssertNil(result.error)
        let written = try XCTUnwrap(result.outputFiles.first)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))
        let rendered = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        XCTAssertEqual(estimate?.width, rendered.width)
        XCTAssertEqual(estimate?.height, rendered.height)
    }
}
