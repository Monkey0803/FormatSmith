import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import FormatSmithCore

/// 页面重排与删除。
///
/// 断言的是**页序**本身，不只是页数——页数对得上但顺序错了，用户拿到的是另一份文档。
final class PDFPageOrderTests: XCTestCase {

    private var directory: URL!
    private var output: URL!

    /// 三页的 PDF，颜色依次是 红 / 绿 / 蓝，用来辨认顺序。
    private let palette: [(name: String, rgb: PixelProbe.RGBA)] = [
        ("红", PixelProbe.RGBA(r: 220, g: 50, b: 50, a: 255)),
        ("绿", PixelProbe.RGBA(r: 50, g: 200, b: 80, a: 255)),
        ("蓝", PixelProbe.RGBA(r: 60, g: 90, b: 220, a: 255)),
    ]

    override func setUpWithError() throws {
        directory = try FixtureFactory.makeTemporaryDirectory()
        output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeColorPagesPDF(named name: String) throws -> URL {
        var pages: [CGImage] = []
        for (index, entry) in palette.enumerated() {
            let context = try BitmapContext.make(width: 200, height: 150, wantsAlpha: false)
            context.setFillColor(
                CGColor(
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    components: [
                        Double(entry.rgb.r) / 255, Double(entry.rgb.g) / 255, Double(entry.rgb.b) / 255, 1,
                    ]
                )!
            )
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
            pages.append(try XCTUnwrap(context.makeImage()))
            _ = index
        }
        return try PDFComposer.compose(
            images: pages,
            settings: ConversionSettings(),
            to: directory.appendingPathComponent("\(name).pdf")
        )
    }

    /// 逐页取中心颜色，得到这份 PDF 的颜色顺序。
    private func colors(of url: URL) throws -> [String] {
        let pdf = try PDFRasterizer.open(url)
        var seen: [String] = []
        for index in 1...pdf.numberOfPages {
            guard let page = pdf.page(at: index) else { continue }
            let image = try PDFRasterizer.render(
                page: page, scale: 0.5, background: .white, format: .png, maxPixels: 4_000_000
            )
            let probe = try PixelProbe(image)
            let centre = probe.pixel(x: image.width / 2, y: image.height / 2)
            let match = palette.first { centre.isClose(to: $0.rgb, tolerance: 40) }?.name ?? "?"
            seen.append(match)
        }
        return seen
    }

    private func run(
        _ tool: PDFTool,
        source: URL,
        configure: (inout ConversionSettings) -> Void = { _ in }
    ) throws -> URL {
        var settings = ConversionSettings()
        settings.target = .pdf
        settings.pdfTool = tool
        settings.outputDirectoryPath = output.path
        settings.perFileSubfolder = false
        settings.filenamePattern = "out"
        configure(&settings)

        let result = ConversionEngine.runPDFTool(
            documents: [SourceDocument.make(from: source)],
            tool: tool,
            settings: settings,
            cancellation: CancellationFlag()
        )
        XCTAssertNil(result.error, "失败：\(result.error?.message ?? "")")
        return try XCTUnwrap(result.outputFiles.first)
    }

    // MARK: - 重排

    func testReorderMovesListedPagesToTheFrontAndKeepsTheRest() throws {
        let source = try makeColorPagesPDF(named: "src")
        XCTAssertEqual(try colors(of: source), ["红", "绿", "蓝"])

        let result = try run(.reorder, source: source) { $0.pageOrderText = "3" }
        XCTAssertEqual(try colors(of: result), ["蓝", "红", "绿"], "第 3 页移到最前，其余按原顺序跟随")
    }

    func testReorderFollowsTheWrittenOrder() throws {
        let source = try makeColorPagesPDF(named: "src")
        let result = try run(.reorder, source: source) { $0.pageOrderText = "3,1" }
        XCTAssertEqual(try colors(of: result), ["蓝", "红", "绿"])
    }

    func testReorderNeverDropsPages() throws {
        // 重排只挪位置。如果它也能丢页，一个笔误就会静默少几页。
        let source = try makeColorPagesPDF(named: "src")
        let result = try run(.reorder, source: source) { $0.pageOrderText = "1" }

        XCTAssertEqual(try colors(of: result).count, 3, "只列了一页，另外两页也要在")
        XCTAssertEqual(try colors(of: result), ["红", "绿", "蓝"], "列出的页本来就在最前，顺序不变")
    }

    func testReorderIgnoresOutOfRangePages() throws {
        let source = try makeColorPagesPDF(named: "src")
        let result = try run(.reorder, source: source) { $0.pageOrderText = "3,99" }
        XCTAssertEqual(try colors(of: result), ["蓝", "红", "绿"], "越界的页码忽略掉，不该报错也不该丢页")
    }

    // MARK: - 删除

    func testDeleteRemovesOnlyTheListedPage() throws {
        let source = try makeColorPagesPDF(named: "src")
        let result = try run(.delete, source: source) {
            $0.pageRangeMode = .custom
            $0.pageRangeText = "2"
        }
        XCTAssertEqual(try colors(of: result), ["红", "蓝"], "删掉第 2 页，其余保持原顺序")
    }

    func testDeleteSupportsRanges() throws {
        let source = try makeColorPagesPDF(named: "src")
        let result = try run(.delete, source: source) {
            $0.pageRangeMode = .custom
            $0.pageRangeText = "1-2"
        }
        XCTAssertEqual(try colors(of: result), ["蓝"])
    }

    func testDeletingEverythingIsRefused() throws {
        let source = try makeColorPagesPDF(named: "src")
        var settings = ConversionSettings()
        settings.target = .pdf
        settings.pdfTool = .delete
        settings.pageRangeMode = .custom
        settings.pageRangeText = "1-3"
        settings.outputDirectoryPath = output.path
        settings.filenamePattern = "nothing"

        let result = ConversionEngine.runPDFTool(
            documents: [SourceDocument.make(from: source)],
            tool: .delete,
            settings: settings,
            cancellation: CancellationFlag()
        )
        XCTAssertNotNil(result.error, "全删光不是「删几页」，应当拒绝并说明")
        XCTAssertTrue(result.error?.message.contains("every page") ?? false, "实际：\(result.error?.message ?? "")")
    }

    // MARK: - 与提取的对比

    func testExtractStillTakesItsOwnMeaningFromTheSameField() throws {
        // 同一个输入框，在「提取」下是「保留这些页」，语义不能串
        let source = try makeColorPagesPDF(named: "src")
        let result = try run(.extract, source: source) {
            $0.pageRangeMode = .custom
            $0.pageRangeText = "3,1"
        }
        XCTAssertEqual(try colors(of: result), ["蓝", "红"], "提取只保留列出的页，顺序按写法")
    }

    // MARK: - 生效规则

    func testPageSelectionIsOnlyActiveForTheToolsThatUseIt() {
        func scope(_ tool: PDFTool) -> SettingsScope {
            var settings = ConversionSettings()
            settings.pdfTool = tool
            return SettingsScope(
                documentKinds: [.pdf], pageCounts: [5], target: .pdf, settings: settings
            )
        }

        XCTAssertTrue(scope(.extract).isActive(.pageRange))
        XCTAssertTrue(scope(.reorder).isActive(.pageRange))
        XCTAssertTrue(scope(.delete).isActive(.pageRange))
        XCTAssertFalse(scope(.merge).isActive(.pageRange))
        XCTAssertFalse(scope(.compress).isActive(.pageRange))
        XCTAssertFalse(scope(.rotate).isActive(.pageRange))
    }

    func testToolSelectionMeaningMatchesTheEngine() {
        XCTAssertEqual(PDFTool.extract.pageSelectionMeaning, .keep)
        XCTAssertEqual(PDFTool.reorder.pageSelectionMeaning, .front)
        XCTAssertEqual(PDFTool.delete.pageSelectionMeaning, .remove)
        XCTAssertNil(PDFTool.merge.pageSelectionMeaning)
    }
}
