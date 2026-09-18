import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import FormatSmithCore

/// 可搜索 PDF（OCR）。
///
/// 扫描件只有像素，搜不了也选不中。这里验证两件事：
/// 文字层**能被搜到**，而且**不改变看到的样子**。
final class SearchablePDFTests: XCTestCase {

    private var directory: URL!
    private var output: URL!

    override func setUpWithError() throws {
        directory = try FixtureFactory.makeTemporaryDirectory()
        output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 一份「扫描件」PDF：只有图片，没有文字层。
    private func makeScannedPDF(_ texts: [String], named name: String) throws -> URL {
        var images: [CGImage] = []
        for (index, text) in texts.enumerated() {
            let url = try FixtureFactory.makeTextImage(
                text, width: 900, height: 300, named: "\(name)-\(index)", in: directory
            )
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            images.append(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        }
        return try PDFComposer.compose(
            images: images,
            settings: ConversionSettings(),
            to: directory.appendingPathComponent("\(name).pdf")
        )
    }

    private func runOCR(_ source: URL, recognizer: TextRecognizing? = nil) throws -> URL {
        var settings = ConversionSettings()
        settings.target = .pdf
        settings.pdfTool = .ocr
        settings.outputDirectoryPath = output.path
        settings.perFileSubfolder = false
        settings.filenamePattern = "searchable"

        let url = try PDFToolkit.makeSearchable(
            url: source,
            settings: settings,
            recognizer: recognizer ?? VisionTextRecognizer(),
            to: output.appendingPathComponent("searchable.pdf")
        )
        return url
    }

    // MARK: - 真跑 Vision

    func testScannedPDFBecomesSearchable() throws {
        let source = try makeScannedPDF(["Invoice 2024-0315"], named: "scan")

        // 前提：原始扫描件里没有文字层
        let before = PDFDocument(url: source)
        XCTAssertTrue(
            (before?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "素材本身不该有文字层，否则测不出东西"
        )

        let searchable = try runOCR(source)
        let text = (PDFDocument(url: searchable)?.string ?? "")
        XCTAssertTrue(text.contains("2024-0315"), "识别结果应当可搜索，实际：\(text)")
    }

    func testEveryPageKeepsItsText() throws {
        let source = try makeScannedPDF(["First page alpha", "Second page beta"], named: "two")
        let searchable = try runOCR(source)

        let document = try XCTUnwrap(PDFDocument(url: searchable))
        XCTAssertEqual(document.pageCount, 2, "页数不能变")
        let text = document.string ?? ""
        XCTAssertTrue(text.contains("alpha"))
        XCTAssertTrue(text.contains("beta"))
    }

    func testPageSizeIsPreserved() throws {
        let source = try makeScannedPDF(["Size check"], named: "size")
        let searchable = try runOCR(source)

        func box(_ url: URL) throws -> CGRect {
            let pdf = try PDFRasterizer.open(url)
            return try XCTUnwrap(pdf.page(at: 1)).getBoxRect(.mediaBox)
        }
        XCTAssertEqual(try box(searchable).width, try box(source).width, accuracy: 1)
        XCTAssertEqual(try box(searchable).height, try box(source).height, accuracy: 1)
    }

    func testVisiblePixelsSurvive() throws {
        // 文字层是透明的，看到的还应当是原来那张扫描图
        let source = try makeScannedPDF(["Keep the pixels"], named: "pixels")
        let searchable = try runOCR(source)

        func pixels(_ url: URL) throws -> PixelProbe {
            let pdf = try PDFRasterizer.open(url)
            let page = try XCTUnwrap(pdf.page(at: 1))
            let image = try PDFRasterizer.render(
                page: page, scale: 0.5, background: .white, format: .png, maxPixels: 4_000_000
            )
            return try PixelProbe(image)
        }

        let before = try pixels(source)
        let after = try pixels(searchable)
        XCTAssertEqual(before.width, after.width)

        // 采样几个点：白底与黑字的位置都不该被文字层改动
        for point in [(10, 10), (before.width / 2, before.height / 2), (before.width - 10, before.height - 10)] {
            let a = before.pixel(x: point.0, y: point.1)
            let b = after.pixel(x: point.0, y: point.1)
            XCTAssertTrue(
                a.isClose(to: b, tolerance: 25),
                "\(point) 处像素被改动了：\(a) → \(b)"
            )
        }
    }

    // MARK: - 注入式识别器（把「文字层怎么放」单独测清楚）

    private struct FixedRecognizer: TextRecognizing {
        let lines: [RecognizedLine]
        func lines(in image: CGImage) throws -> [RecognizedLine] { lines }
    }

    func testInjectedTextEndsUpSearchable() throws {
        let source = try makeScannedPDF(["placeholder"], named: "fixed")
        let recognizer = FixedRecognizer(lines: [
            RecognizedLine(text: "HELLO-4242", bounds: CGRect(x: 0.1, y: 0.4, width: 0.6, height: 0.15))
        ])

        let searchable = try runOCR(source, recognizer: recognizer)
        let text = (PDFDocument(url: searchable)?.string ?? "")
        XCTAssertTrue(text.contains("HELLO-4242"), "注入的文字也应当写进文字层，实际：\(text)")
    }

    func testRecognisingNothingStillProducesAValidPDF() throws {
        let source = try makeScannedPDF(["nothing readable"], named: "empty")
        let searchable = try runOCR(source, recognizer: FixedRecognizer(lines: []))

        let document = try XCTUnwrap(PDFDocument(url: searchable))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertTrue((document.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: - 工具语义

    func testOCRToolIsMarkedLossy() {
        XCTAssertTrue(PDFTool.ocr.isLossy, "它栅格化并重建页面，必须如实标记")
        XCTAssertFalse(PDFTool.ocr.operatesOnWholeBatch, "逐份文档处理")
        XCTAssertNil(PDFTool.ocr.pageSelectionMeaning)
    }

    func testEmptyOCRKeepsAllPagesEvenIfNothingIsFound() throws {
        // 全是空白页也要正常输出，不能因为「没认出字」就报错
        let images = try (0..<3).map { _ -> CGImage in
            let context = try BitmapContext.make(width: 200, height: 150, wantsAlpha: false)
            context.fill(with: .white)
            return try XCTUnwrap(context.makeImage())
        }
        let source = try PDFComposer.compose(
            images: images, settings: ConversionSettings(),
            to: directory.appendingPathComponent("blank.pdf")
        )

        let searchable = try runOCR(source)
        XCTAssertEqual(PDFDocument(url: searchable)?.pageCount, 3)
    }
}
