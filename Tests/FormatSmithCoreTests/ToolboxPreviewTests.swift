import AppKit
import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import FormatSmithCore

/// 工具箱预览必须等于实际输出。
///
/// 起因是一次实测：三页彩色 PDF 上「提取 3」的预览显示的是**第 1 页（红）**，
/// 实际输出却是**第 3 页（蓝）**，页数还报成输入页数；
/// 旋转工具的说明写着已旋转，画面却没有转。预览存在的全部意义就是所见即所得。
final class ToolboxPreviewTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = try FixtureFactory.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 三页彩色 PDF：红 / 绿 / 蓝，颜色即页码。
    private func makeThreePagePDF() throws -> SourceDocument {
        let colors: [(Double, Double, Double)] = [(0.9, 0.2, 0.2), (0.2, 0.8, 0.3), (0.2, 0.3, 0.9)]
        let doc = PDFDocument()
        for (index, c) in colors.enumerated() {
            let context = try BitmapContext.make(width: 200, height: 150, wantsAlpha: false)
            context.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
            let image = try XCTUnwrap(context.makeImage())
            doc.insert(
                PDFPage(image: NSImage(cgImage: image, size: NSSize(width: 200, height: 150)))!, at: index
            )
        }
        let url = directory.appendingPathComponent("three.pdf")
        doc.write(to: url)
        return SourceDocument.make(from: url)
    }

    private func centre(_ image: CGImage) throws -> PixelProbe.RGBA {
        try PixelProbe(image).pixel(x: image.width / 2, y: image.height / 2)
    }

    private func settings(_ tool: PDFTool) -> ConversionSettings {
        var settings = ConversionSettings()
        settings.target = .pdf
        settings.pdfTool = tool
        settings.outputDirectoryPath = directory.path
        settings.filenamePattern = "out"
        return settings
    }

    private func preview(_ tool: PDFTool, _ mutate: (inout ConversionSettings) -> Void = { _ in }) throws
        -> OutputPreview.Result
    {
        var s = settings(tool)
        mutate(&s)
        return try OutputPreview.render(documents: [try makeThreePagePDF()], target: .pdf, settings: s)
    }

    private func outputColour(_ tool: PDFTool, _ mutate: (inout ConversionSettings) -> Void) throws
        -> (colour: PixelProbe.RGBA, pages: Int)
    {
        var s = settings(tool)
        mutate(&s)
        let document = try makeThreePagePDF()
        let result = try ConversionEngine.runPDFTool(
            documents: [document], tool: tool, settings: s, cancellation: CancellationFlag()
        )
        let pdf = try PDFRasterizer.open(try XCTUnwrap(result.outputFiles.first))
        let page = try XCTUnwrap(pdf.page(at: 1))
        let image = try PDFRasterizer.render(
            page: page, scale: 0.5, background: .white, format: .png, maxPixels: 4_000_000
        )
        return (try centre(image), pdf.numberOfPages)
    }

    // MARK: - 提取

    func testExtractPreviewShowsTheFirstSelectedPage() throws {
        let result = try preview(.extract) {
            $0.pageRangeMode = .custom; $0.pageRangeText = "3"
        }
        let actual = try outputColour(.extract) {
            $0.pageRangeMode = .custom; $0.pageRangeText = "3"
        }

        let previewColour = try centre(result.image)
        XCTAssertTrue(
            previewColour.isClose(to: actual.colour, tolerance: 20),
            "预览应当画第 3 页（蓝），实际预览：\(previewColour)，输出：\(actual.colour)"
        )
        XCTAssertEqual(result.pageCount, actual.pages, "页数应当是输出页数")
        XCTAssertEqual(result.pageCount, 1, "提取一页，输出就一页")
    }

    func testExtractPreviewFollowsWrittenOrder() throws {
        // 写 3,1 就先 3 后 1，预览该显示第 3 页
        let result = try preview(.extract) {
            $0.pageRangeMode = .custom; $0.pageRangeText = "3,1"
        }
        let colour = try centre(result.image)
        XCTAssertTrue(
            colour.isClose(to: PixelProbe.RGBA(r: 66, g: 103, b: 235, a: 255), tolerance: 30),
            "写 3,1 就该以第 3 页开头，实际 \(colour)"
        )
    }

    // MARK: - 重排

    func testReorderPreviewShowsTheNewFirstPage() throws {
        let result = try preview(.reorder) {
            $0.pageRangeMode = .custom; $0.pageOrderText = "3"
        }
        let actual = try outputColour(.reorder) {
            $0.pageRangeMode = .custom; $0.pageOrderText = "3"
        }

        let previewColour = try centre(result.image)
        XCTAssertTrue(
            previewColour.isClose(to: actual.colour, tolerance: 20),
            "重排之后第一页是原来的第 3 页，实际预览 \(previewColour) / 输出 \(actual.colour)"
        )
        XCTAssertEqual(result.pageCount, actual.pages)
        XCTAssertEqual(result.pageCount, 3, "重排不丢页")
    }

    // MARK: - 删除

    func testDeletePreviewHidesDeletedPages() throws {
        // 删掉第 1 页，输出的第一页应当是原来的第 2 页（绿）
        let result = try preview(.delete) {
            $0.pageRangeMode = .custom; $0.pageRangeText = "1"
        }
        let actual = try outputColour(.delete) {
            $0.pageRangeMode = .custom; $0.pageRangeText = "1"
        }

        let previewColour = try centre(result.image)
        XCTAssertTrue(
            previewColour.isClose(to: actual.colour, tolerance: 20),
            "删掉第 1 页后应以第 2 页开头，实际预览 \(previewColour) / 输出 \(actual.colour)"
        )
        XCTAssertEqual(result.pageCount, 2, "三页删一页，输出两页")
    }

    // MARK: - 旋转

    func testRotatePreviewIsActuallyRotated() throws {
        // 源页是 200×150 的横版。旋转工具只有 90/180/270 三档（没有「不转」），
        // 所以拿 90° 与 180° 对比：前者换宽高，后者不换 —— 这才能证明画面真的转了，
        // 而不是只有说明文字在变。
        func preview(angle: RotationAngle) throws -> OutputPreview.Result {
            var s = settings(.rotate)
            s.rotationAngle = angle
            return try OutputPreview.render(
                documents: [try makeThreePagePDF()], target: .pdf, settings: s
            )
        }

        let quarter = try preview(angle: .clockwise90)
        let half = try preview(angle: .upsideDown)

        XCTAssertTrue(
            quarter.image.width < quarter.image.height,
            "转 90° 之后应当变竖版，实际 \(quarter.image.width)×\(quarter.image.height)"
        )
        XCTAssertTrue(
            half.image.width > half.image.height,
            "转 180° 应当保持横版，实际 \(half.image.width)×\(half.image.height)"
        )
        XCTAssertEqual(
            quarter.image.width, half.image.height,
            "90° 与 180° 的宽高关系应当互为转置"
        )
    }

    func testRotateCaptionMatchesTheRotatedImage() throws {
        // 说明里的「150 × 200 pt」是旋转后的尺寸；画面若不竖起来，两者就互相矛盾
        for angle in [RotationAngle.clockwise90, .counterClockwise90] {
            var rotated = settings(.rotate)
            rotated.rotationAngle = angle
            let result = try OutputPreview.render(
                documents: [try makeThreePagePDF()], target: .pdf, settings: rotated
            )
            XCTAssertTrue(
                result.image.width < result.image.height,
                "\(angle.rawValue)° 的说明写了竖版尺寸，画面却还是横的"
            )
            XCTAssertTrue(result.caption.contains("150 × 200"), "说明应当是旋转后的尺寸：\(result.caption)")
        }
    }

    // MARK: - 其它工具不受影响

    func testWholeDocumentToolsStillShowPageOne() throws {
        for tool in [PDFTool.merge, .compress, .ocr] {
            let result = try preview(tool)
            XCTAssertEqual(result.pageCount, 3, "\(tool.rawValue) 不改变页数")
            let colour = try centre(result.image)
            XCTAssertTrue(
                colour.isClose(to: PixelProbe.RGBA(r: 237, g: 75, b: 65, a: 255), tolerance: 30),
                "\(tool.rawValue) 的第一页仍是原来的第 1 页，实际 \(colour)"
            )
        }
    }
}
