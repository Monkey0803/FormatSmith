import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import FormatSmithCore

/// PDF 工具箱的端到端测试：合并、拆分、提取、旋转、压缩。
final class PDFToolkitTests: XCTestCase {

    private var directory: URL!
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        directory = try FixtureFactory.makeTemporaryDirectory()
        outputDirectory = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func settings(tool: PDFTool = .merge) -> ConversionSettings {
        var settings = ConversionSettings()
        settings.target = .pdf
        settings.pdfTool = tool
        settings.outputDirectoryPath = outputDirectory.path
        settings.perFileSubfolder = false
        settings.filenamePattern = "{name}"
        return settings
    }

    private func run(_ tool: PDFTool, _ urls: [URL], settings mutate: ((inout ConversionSettings) -> Void)? = nil)
        -> ConversionResult
    {
        var configuration = settings(tool: tool)
        mutate?(&configuration)
        return ConversionEngine.runPDFTool(
            documents: urls.map { SourceDocument.make(from: $0) },
            tool: tool,
            settings: configuration,
            cancellation: CancellationFlag()
        )
    }

    private func pageCount(_ url: URL) -> Int {
        PDFRasterizer.pageCount(of: url)
    }

    // MARK: - 合并

    func testMergeConcatenatesPagesInOrder() throws {
        let first = try FixtureFactory.makePDF(pages: 2, named: "one", in: directory)
        let second = try FixtureFactory.makePDF(pages: 3, named: "two", in: directory)

        let result = run(.merge, [first, second])

        XCTAssertNil(result.error)
        let merged = try XCTUnwrap(result.outputFiles.first)
        XCTAssertEqual(pageCount(merged), 5, "2 页 + 3 页应得到 5 页")
        XCTAssertEqual(result.includedDocumentIDs.count, 2)
    }

    func testMergedPagesStillContainTheirContent() throws {
        // 合并后每一页都要能正常光栅化出内容，而不只是页数对得上。
        let first = try FixtureFactory.makePDF(
            pages: 2, size: CGSize(width: 400, height: 300), named: "one", in: directory)
        let second = try FixtureFactory.makePDF(
            pages: 1, size: CGSize(width: 400, height: 300), named: "two", in: directory)

        let result = run(.merge, [first, second])
        let merged = try XCTUnwrap(result.outputFiles.first)

        let document = try XCTUnwrap(PDFRasterizer.open(merged))
        for pageNumber in 1...3 {
            let page = try XCTUnwrap(document.page(at: pageNumber))
            let image = try PDFRasterizer.render(
                page: page, scale: 1, background: .white, keepsAlpha: false, maxPixels: 10_000_000
            )
            XCTAssertEqual(image.width, 400, "第 \(pageNumber) 页宽度不对")
            let probe = try PixelProbe(image)
            XCTAssertTrue(
                probe.pixel(x: 80, y: 80).isClose(to: .red, tolerance: 40),
                "第 \(pageNumber) 页的红块丢失了，实际 \(probe.pixel(x: 80, y: 80))"
            )
        }
    }

    func testMergingTwoFilesDoesNotReuseTheFirstFileName() throws {
        let first = try FixtureFactory.makePDF(pages: 1, named: "report", in: directory)
        let second = try FixtureFactory.makePDF(pages: 1, named: "appendix", in: directory)
        var configuration = settings(tool: .merge)
        configuration.filenamePattern = "{name}"

        let result = ConversionEngine.runPDFTool(
            documents: [first, second].map { SourceDocument.make(from: $0) },
            tool: .merge,
            settings: configuration,
            cancellation: CancellationFlag()
        )

        let name = try XCTUnwrap(result.outputFiles.first).lastPathComponent
        XCTAssertEqual(name, "report-merged.pdf", "合并输出不应与第一个输入同名")
    }

    func testMergingSingleFileKeepsItsName() throws {
        let only = try FixtureFactory.makePDF(pages: 1, named: "solo", in: directory)
        let result = run(.merge, [only])
        XCTAssertEqual(try XCTUnwrap(result.outputFiles.first).lastPathComponent, "solo.pdf")
    }

    // MARK: - 拆分

    func testSplitWritesOneFilePerChunk() throws {
        let source = try FixtureFactory.makePDF(pages: 7, named: "doc", in: directory)
        var configuration = settings(tool: .split)
        configuration.splitEveryPages = 3
        configuration.filenamePattern = "{name}-{page}"

        let result = ConversionEngine.runPDFTool(
            documents: [SourceDocument.make(from: source)],
            tool: .split,
            settings: configuration,
            cancellation: CancellationFlag()
        )

        XCTAssertNil(result.error)
        XCTAssertEqual(result.producedCount, 3, "7 页每 3 页一份应该是 3 个文件")

        let names = result.outputFiles.map(\.lastPathComponent).sorted()
        // 补零宽度由总页数决定：7 页 → 1 位
        XCTAssertEqual(names, ["doc-1.pdf", "doc-4.pdf", "doc-7.pdf"])

        XCTAssertEqual(pageCount(result.outputFiles[0]), 3)
        XCTAssertEqual(pageCount(result.outputFiles[1]), 3)
        XCTAssertEqual(pageCount(result.outputFiles[2]), 1, "最后一份应只剩 1 页")
    }

    func testSplitEveryPageProducesOneFilePerPage() throws {
        let source = try FixtureFactory.makePDF(pages: 4, named: "doc", in: directory)
        var configuration = settings(tool: .split)
        configuration.splitEveryPages = 1
        configuration.filenamePattern = "{name}-{page}"

        let result = ConversionEngine.runPDFTool(
            documents: [SourceDocument.make(from: source)],
            tool: .split,
            settings: configuration,
            cancellation: CancellationFlag()
        )
        XCTAssertEqual(result.producedCount, 4)
        for url in result.outputFiles {
            XCTAssertEqual(pageCount(url), 1)
        }
    }

    func testSplitChunkLargerThanDocumentStillWorks() throws {
        let source = try FixtureFactory.makePDF(pages: 2, named: "doc", in: directory)
        var configuration = settings(tool: .split)
        configuration.splitEveryPages = 10

        let result = ConversionEngine.runPDFTool(
            documents: [SourceDocument.make(from: source)],
            tool: .split,
            settings: configuration,
            cancellation: CancellationFlag()
        )
        XCTAssertNil(result.error)
        XCTAssertEqual(result.producedCount, 1)
        XCTAssertEqual(pageCount(result.outputFiles[0]), 2)
    }

    // MARK: - 提取

    func testExtractKeepsOnlyRequestedPages() throws {
        let source = try FixtureFactory.makePDF(pages: 6, named: "doc", in: directory)
        var configuration = settings(tool: .extract)
        configuration.pageRangeMode = .custom
        configuration.pageRangeText = "1,4-5"

        let result = ConversionEngine.runPDFTool(
            documents: [SourceDocument.make(from: source)],
            tool: .extract,
            settings: configuration,
            cancellation: CancellationFlag()
        )

        XCTAssertNil(result.error)
        XCTAssertEqual(result.producedCount, 3)
        XCTAssertEqual(pageCount(result.outputFiles[0]), 3)
    }

    func testExtractWithEmptyRangeFails() throws {
        let source = try FixtureFactory.makePDF(pages: 3, named: "doc", in: directory)
        var configuration = settings(tool: .extract)
        configuration.pageRangeMode = .custom
        configuration.pageRangeText = "99"

        let result = ConversionEngine.runPDFTool(
            documents: [SourceDocument.make(from: source)],
            tool: .extract,
            settings: configuration,
            cancellation: CancellationFlag()
        )
        XCTAssertNotNil(result.error)
    }

    // MARK: - 旋转

    func testRotate90SwapsDisplayedPageSize() throws {
        let source = try FixtureFactory.makePDF(
            pages: 1, size: CGSize(width: 400, height: 300), named: "doc", in: directory)
        var configuration = settings(tool: .rotate)
        configuration.rotationAngle = .clockwise90

        let result = ConversionEngine.runPDFTool(
            documents: [SourceDocument.make(from: source)],
            tool: .rotate,
            settings: configuration,
            cancellation: CancellationFlag()
        )

        XCTAssertNil(result.error)
        let rotated = try XCTUnwrap(result.outputFiles.first)
        XCTAssertEqual(PDFRasterizer.pageSize(of: rotated), CGSize(width: 300, height: 400), "旋转 90 度后显示尺寸应互换")
        XCTAssertEqual(pageCount(rotated), 1)
    }

    func testRotate180KeepsPageSizeButFlipsContent() throws {
        let source = try FixtureFactory.makePDF(
            pages: 1, size: CGSize(width: 400, height: 300), named: "doc", in: directory)
        var configuration = settings(tool: .rotate)
        configuration.rotationAngle = .upsideDown

        let result = ConversionEngine.runPDFTool(
            documents: [SourceDocument.make(from: source)],
            tool: .rotate,
            settings: configuration,
            cancellation: CancellationFlag()
        )
        let rotated = try XCTUnwrap(result.outputFiles.first)
        XCTAssertEqual(PDFRasterizer.pageSize(of: rotated), CGSize(width: 400, height: 300))

        // 内容应落到对角位置
        let document = try XCTUnwrap(PDFRasterizer.open(rotated))
        let page = try XCTUnwrap(document.page(at: 1))
        let image = try PDFRasterizer.render(
            page: page, scale: 1, background: .white, keepsAlpha: false, maxPixels: 10_000_000
        )
        let probe = try PixelProbe(image)
        XCTAssertTrue(
            probe.pixel(x: 320, y: 220).isClose(to: .red, tolerance: 40),
            "180 度后红块应在右下方，实际 \(probe.pixel(x: 320, y: 220))"
        )
    }

    func testRotateIsAdditive() throws {
        let source = try FixtureFactory.makePDF(
            pages: 1, size: CGSize(width: 400, height: 300), named: "doc", in: directory)
        var configuration = settings(tool: .rotate)
        configuration.rotationAngle = .clockwise90

        let first = ConversionEngine.runPDFTool(
            documents: [SourceDocument.make(from: source)],
            tool: .rotate,
            settings: configuration,
            cancellation: CancellationFlag()
        )
        let once = try XCTUnwrap(first.outputFiles.first)

        // 再转 90 度，应等价于 180 度：显示尺寸回到原样
        configuration.perFileSubfolder = false
        let second = ConversionEngine.runPDFTool(
            documents: [SourceDocument.make(from: once)],
            tool: .rotate,
            settings: configuration,
            cancellation: CancellationFlag()
        )
        let twice = try XCTUnwrap(second.outputFiles.first)
        XCTAssertEqual(PDFRasterizer.pageSize(of: twice), CGSize(width: 400, height: 300))
    }

    // MARK: - 压缩

    func testCompressShrinksTheFileAndKeepsPageCount() throws {
        // 噪声页更接近扫描件，压缩效果才看得出来
        let noisy = try FixtureFactory.makeNoisyImage(width: 600, height: 600, named: "scan", in: directory)
        var embedSettings = ConversionSettings()
        embedSettings.target = .pdf
        embedSettings.outputDirectoryPath = directory.path
        embedSettings.perFileSubfolder = false
        embedSettings.filenamePattern = "heavy"

        let photoPDF = try XCTUnwrap(
            ConversionEngine.convert(
                document: SourceDocument.make(from: noisy),
                target: .pdf,
                settings: embedSettings,
                cancellation: CancellationFlag()
            ).outputFiles.first
        )
        // 图片按原始像素嵌入，因此页面就是 600×600 点
        XCTAssertEqual(PDFRasterizer.pageSize(of: photoPDF), CGSize(width: 600, height: 600))

        let heavySize = try fileSize(photoPDF)

        var configuration = settings(tool: .compress)
        configuration.dpi = 72
        configuration.pdfCompressesImages = true
        configuration.pdfImageQuality = 0.4
        configuration.filenamePattern = "small"

        let result = ConversionEngine.runPDFTool(
            documents: [SourceDocument.make(from: photoPDF)],
            tool: .compress,
            settings: configuration,
            cancellation: CancellationFlag()
        )

        XCTAssertNil(result.error)
        let compressed = try XCTUnwrap(result.outputFiles.first)
        XCTAssertEqual(pageCount(compressed), 1)
        XCTAssertLessThan(try fileSize(compressed), heavySize, "压缩后应更小")

        // 页面尺寸必须保持原样，否则等于偷偷改了纸张
        XCTAssertEqual(PDFRasterizer.pageSize(of: compressed), CGSize(width: 600, height: 600))
    }

    func testCompressKeepsContent() throws {
        let source = try FixtureFactory.makePDF(
            pages: 1, size: CGSize(width: 400, height: 300), named: "doc", in: directory)
        var configuration = settings(tool: .compress)
        configuration.dpi = 100

        let result = ConversionEngine.runPDFTool(
            documents: [SourceDocument.make(from: source)],
            tool: .compress,
            settings: configuration,
            cancellation: CancellationFlag()
        )
        let compressed = try XCTUnwrap(result.outputFiles.first)

        let document = try XCTUnwrap(PDFRasterizer.open(compressed))
        let page = try XCTUnwrap(document.page(at: 1))
        let image = try PDFRasterizer.render(
            page: page, scale: 1, background: .white, keepsAlpha: false, maxPixels: 10_000_000
        )
        XCTAssertEqual(image.width, 400)
        let probe = try PixelProbe(image)
        XCTAssertTrue(probe.pixel(x: 80, y: 80).isClose(to: .red, tolerance: 48), "实际 \(probe.pixel(x: 80, y: 80))")
    }

    // MARK: - 取消与错误

    func testCancelledMergeLeavesNoFile() throws {
        let first = try FixtureFactory.makePDF(pages: 2, named: "one", in: directory)
        let second = try FixtureFactory.makePDF(pages: 2, named: "two", in: directory)

        let flag = CancellationFlag()
        flag.cancel()

        let result = ConversionEngine.runPDFTool(
            documents: [first, second].map { SourceDocument.make(from: $0) },
            tool: .merge,
            settings: settings(tool: .merge),
            cancellation: flag
        )

        XCTAssertNotNil(result.error)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
        XCTAssertEqual(leftovers.count, 0, "取消后不应留下半成品: \(leftovers)")
    }

    func testCorruptInputFailsCleanly() throws {
        let broken = directory.appendingPathComponent("broken.pdf")
        try Data("not a pdf at all".utf8).write(to: broken)

        let result = run(.merge, [broken])
        XCTAssertNotNil(result.error)
    }

    // MARK: - 工具

    private func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}
