import CoreGraphics
import Foundation
import XCTest
@testable import FormatSmithCore

/// 图片 → PDF 的端到端测试。
///
/// 关键验证方式是「写出去再读回来」：把生成的 PDF 重新光栅化，采样像素，
/// 确认图片真的落在了页面上，而不只是页数对得上。
final class PDFComposerTests: XCTestCase {

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

    private func settings(pageSize: PDFPageSize = .fitImage) -> ConversionSettings {
        var settings = ConversionSettings()
        settings.target = .pdf
        settings.resolutionMode = .scale
        settings.scale = 1
        settings.outputDirectoryPath = outputDirectory.path
        settings.perFileSubfolder = false
        settings.filenamePattern = "{name}"
        settings.pdfPageSize = pageSize
        return settings
    }

    private func pageCount(_ url: URL) throws -> Int {
        try XCTUnwrap(PDFRasterizer.open(url)).numberOfPages
    }

    private func pageBox(_ url: URL, page index: Int = 1) throws -> CGRect {
        let document = try XCTUnwrap(PDFRasterizer.open(url))
        let page = try XCTUnwrap(document.page(at: index))
        return PDFRasterizer.effectiveBox(of: page)
    }

    // MARK: - 单张

    func testSingleImageBecomesOnePagePDF() throws {
        let source = try FixtureFactory.makeImage(width: 120, height: 80, format: .png, named: "photo", in: directory)
        let result = ConversionEngine.convert(
            document: SourceDocument.make(from: source),
            target: .pdf,
            settings: settings(),
            cancellation: CancellationFlag()
        )

        XCTAssertNil(result.error)
        let written = try XCTUnwrap(result.outputFiles.first)
        XCTAssertEqual(written.lastPathComponent, "photo.pdf")
        XCTAssertEqual(try pageCount(written), 1)

        // fitImage：页面尺寸等于图片的像素尺寸（1 px = 1 pt）
        let box = try pageBox(written)
        XCTAssertEqual(box.width, 120, accuracy: 0.5)
        XCTAssertEqual(box.height, 80, accuracy: 0.5)
    }

    func testPageContentMatchesTheSourceImage() throws {
        let source = try FixtureFactory.makeImage(width: 120, height: 80, format: .png, named: "photo", in: directory)
        let result = ConversionEngine.convert(
            document: SourceDocument.make(from: source),
            target: .pdf,
            settings: settings(),
            cancellation: CancellationFlag()
        )
        let written = try XCTUnwrap(result.outputFiles.first)

        // 把 PDF 页面重新光栅化，确认红块与蓝块还在原位。
        let document = try XCTUnwrap(PDFRasterizer.open(written))
        let page = try XCTUnwrap(document.page(at: 1))
        let rendered = try PDFRasterizer.render(
            page: page, scale: 1, background: .white, keepsAlpha: false, maxPixels: 10_000_000
        )
        XCTAssertEqual(rendered.width, 120)
        XCTAssertEqual(rendered.height, 80)

        let probe = try PixelProbe(rendered)
        XCTAssertTrue(probe.pixel(x: 20, y: 20).isClose(to: .red, tolerance: 40), "实际 \(probe.pixel(x: 20, y: 20))")
        XCTAssertTrue(probe.pixel(x: 100, y: 60).isClose(to: .blue, tolerance: 40), "实际 \(probe.pixel(x: 100, y: 60))")
    }

    // MARK: - 合并

    func testSeveralImagesMergeIntoOneMultiPagePDF() throws {
        let first = try FixtureFactory.makeImage(width: 100, height: 100, named: "one", in: directory)
        let second = try FixtureFactory.makeImage(width: 60, height: 90, named: "two", in: directory)
        let third = try FixtureFactory.makeImage(width: 80, height: 80, named: "three", in: directory)

        let documents = [first, second, third].map { SourceDocument.make(from: $0) }
        let result = ConversionEngine.composePDF(
            documents: documents,
            settings: settings(),
            cancellation: CancellationFlag()
        )

        XCTAssertNil(result.error)
        XCTAssertEqual(result.producedCount, 3)
        XCTAssertEqual(result.includedDocumentIDs.count, 3, "合并输出应记录全部输入")

        let written = try XCTUnwrap(result.outputFiles.first)
        XCTAssertEqual(try pageCount(written), 3)

        // 每页保留各自的尺寸
        XCTAssertEqual(try pageBox(written, page: 1).width, 100, accuracy: 0.5)
        XCTAssertEqual(try pageBox(written, page: 2).width, 60, accuracy: 0.5)
        XCTAssertEqual(try pageBox(written, page: 2).height, 90, accuracy: 0.5)
        XCTAssertEqual(try pageBox(written, page: 3).height, 80, accuracy: 0.5)
    }

    func testMergedPDFReportsProgressPerPage() throws {
        let documents = try ["a", "b", "c"].map {
            SourceDocument.make(from: try FixtureFactory.makeImage(width: 40, height: 40, named: $0, in: directory))
        }

        let lock = NSLock()
        var reported: [Int] = []
        let observer = ConversionObserver(onProgress: { progress in
            lock.lock()
            reported.append(progress.completedUnits)
            lock.unlock()
        })

        _ = ConversionEngine.composePDF(
            documents: documents,
            settings: settings(),
            cancellation: CancellationFlag(),
            observer: observer
        )
        XCTAssertEqual(reported, [1, 2, 3])
    }

    // MARK: - 页面尺寸策略

    func testA4PageFitsImageWithMargin() throws {
        let source = try FixtureFactory.makeImage(width: 200, height: 100, format: .png, named: "wide", in: directory)
        var configuration = settings(pageSize: .a4)
        configuration.pdfMargin = 24

        let result = ConversionEngine.convert(
            document: SourceDocument.make(from: source),
            target: .pdf,
            settings: configuration,
            cancellation: CancellationFlag()
        )
        let written = try XCTUnwrap(result.outputFiles.first)

        let box = try pageBox(written)
        XCTAssertEqual(box.width, 595.28, accuracy: 0.5)
        XCTAssertEqual(box.height, 841.89, accuracy: 0.5)

        // 图片应等比缩放到页面内并居中：2:1 的图放进 A4，宽度受限
        let availableWidth = box.width - 2 * 24
        let availableHeight = box.height - 2 * 24
        let expectedWidth = min(availableWidth, availableHeight * 2)
        XCTAssertEqual(expectedWidth, availableWidth, accuracy: 0.5, "这张图应是宽度受限")

        // 页面四角应是白的（图片没有铺满整页）
        let document = try XCTUnwrap(PDFRasterizer.open(written))
        let page = try XCTUnwrap(document.page(at: 1))
        let rendered = try PDFRasterizer.render(
            page: page, scale: 0.5, background: .white, keepsAlpha: false, maxPixels: 10_000_000
        )
        let probe = try PixelProbe(rendered)
        XCTAssertTrue(probe.pixel(x: 20, y: 20).isClose(to: .white, tolerance: 12), "边距区域应是白的")
    }

    func testLetterPageSize() throws {
        let source = try FixtureFactory.makeImage(width: 100, height: 100, format: .png, named: "sq", in: directory)
        let result = ConversionEngine.convert(
            document: SourceDocument.make(from: source),
            target: .pdf,
            settings: settings(pageSize: .letter),
            cancellation: CancellationFlag()
        )
        let written = try XCTUnwrap(result.outputFiles.first)
        let box = try pageBox(written)
        XCTAssertEqual(box.width, 612, accuracy: 0.5)
        XCTAssertEqual(box.height, 792, accuracy: 0.5)
    }

    // MARK: - 压缩选项

    func testLosslessIsTheDefaultAndCompressionShrinksTheFile() throws {
        // 必须用接近照片的内容：渐变或纯色会被 Flate 压得比 JPEG 还小，
        // 用那种素材验证「压缩有效」是自欺欺人。
        let source = try FixtureFactory.makeNoisyImage(width: 300, height: 300, named: "photo", in: directory)

        let lossless = ConversionEngine.convert(
            document: SourceDocument.make(from: source),
            target: .pdf,
            settings: settings(),
            cancellation: CancellationFlag()
        )
        let losslessSize =
            try FileManager.default
            .attributesOfItem(atPath: try XCTUnwrap(lossless.outputFiles.first).path)[.size] as? Int64 ?? 0

        var compressed = settings()
        compressed.pdfCompressesImages = true
        compressed.pdfImageQuality = 0.4
        compressed.filenamePattern = "compressed"
        let compressedResult = ConversionEngine.convert(
            document: SourceDocument.make(from: source),
            target: .pdf,
            settings: compressed,
            cancellation: CancellationFlag()
        )
        let compressedSize =
            try FileManager.default
            .attributesOfItem(atPath: try XCTUnwrap(compressedResult.outputFiles.first).path)[.size] as? Int64 ?? 0

        XCTAssertGreaterThan(losslessSize, 0)
        XCTAssertLessThan(
            compressedSize, losslessSize,
            "照片类内容开启 JPEG 压缩后文件应明显更小，实际 \(compressedSize) vs \(losslessSize)"
        )
    }

    func testTransparentImagesAreNotJPEGCompressed() throws {
        // JPEG 存不了 alpha，带透明的图必须保持无损，否则透明区域会变黑。
        let source = try FixtureFactory.makeTransparentImage(width: 200, height: 200, named: "ghost", in: directory)
        var configuration = settings()
        configuration.pdfCompressesImages = true
        configuration.pdfImageQuality = 0.3

        let result = ConversionEngine.convert(
            document: SourceDocument.make(from: source),
            target: .pdf,
            settings: configuration,
            cancellation: CancellationFlag()
        )
        XCTAssertNil(result.error)

        let written = try XCTUnwrap(result.outputFiles.first)
        let document = try XCTUnwrap(PDFRasterizer.open(written))
        let page = try XCTUnwrap(document.page(at: 1))
        let rendered = try PDFRasterizer.render(
            page: page, scale: 1, background: .white, keepsAlpha: false, maxPixels: 10_000_000
        )
        let probe = try PixelProbe(rendered)
        // 透明区域在铺白底后应是白的；若被当成 JPEG 压过，这里会变成黑块
        XCTAssertTrue(
            probe.pixel(x: 10, y: 10).isClose(to: .white, tolerance: 24),
            "透明区域不应变黑，实际 \(probe.pixel(x: 10, y: 10))"
        )
    }

    // MARK: - 取消与命名

    func testCancellationLeavesNoPartialFile() throws {
        let documents = try ["a", "b", "c"].map {
            SourceDocument.make(from: try FixtureFactory.makeImage(width: 40, height: 40, named: $0, in: directory))
        }
        let flag = CancellationFlag()
        flag.cancel()

        let result = ConversionEngine.composePDF(
            documents: documents,
            settings: settings(),
            cancellation: flag
        )

        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.outputFiles.isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
        XCTAssertTrue(leftovers.isEmpty, "取消后不应留下半成品: \(leftovers)")
    }

    func testOutputNameComesFromThePattern() throws {
        let source = try FixtureFactory.makeImage(width: 40, height: 40, format: .png, named: "scan", in: directory)
        var configuration = settings()
        configuration.filenamePattern = "archive-{date}"

        let result = ConversionEngine.convert(
            document: SourceDocument.make(from: source),
            target: .pdf,
            settings: configuration,
            cancellation: CancellationFlag()
        )
        let name = try XCTUnwrap(result.outputFiles.first).lastPathComponent
        XCTAssertTrue(name.hasPrefix("archive-"), "实际 \(name)")
        XCTAssertTrue(name.hasSuffix(".pdf"))
    }

    // MARK: - 工具

}

/// 证件扫描件用的「一页两张」版面。
@MainActor
final class PDFPageLayoutTests: XCTestCase {

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

    private func settings(layout: PDFPageLayout) -> ConversionSettings {
        var settings = ConversionSettings()
        settings.target = .pdf
        settings.pdfLayout = layout
        settings.pdfPageSize = .a4
        settings.pdfMargin = 24
        settings.outputDirectoryPath = outputDirectory.path
        settings.perFileSubfolder = false
        settings.filenamePattern = "scan"
        return settings
    }

    private func compose(_ urls: [URL], layout: PDFPageLayout) throws -> URL {
        let images = try urls.map { url in
            try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                .let { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        }
        return try PDFComposer.compose(
            images: images.compactMap { $0 },
            settings: settings(layout: layout),
            to: outputDirectory.appendingPathComponent("scan.pdf")
        )
    }

    func testTwoImagesShareOnePage() throws {
        let front = try FixtureFactory.makeImage(width: 600, height: 380, named: "front", in: directory)
        let back = try FixtureFactory.makeImage(width: 600, height: 380, named: "back", in: directory)

        let url = try compose([front, back], layout: .twoPerPage)
        XCTAssertEqual(PDFRasterizer.pageCount(of: url), 1, "两张图应当排在同一页")
    }

    func testThreeImagesBecomeTwoPages() throws {
        let urls = try (1...3).map {
            try FixtureFactory.makeImage(width: 400, height: 260, named: "p\($0)", in: directory)
        }
        let url = try compose(urls, layout: .twoPerPage)
        XCTAssertEqual(PDFRasterizer.pageCount(of: url), 2)
    }

    func testOnePerPageKeepsTheOldBehaviour() throws {
        let urls = try (1...3).map {
            try FixtureFactory.makeImage(width: 400, height: 260, named: "q\($0)", in: directory)
        }
        let url = try compose(urls, layout: .onePerPage)
        XCTAssertEqual(PDFRasterizer.pageCount(of: url), 3)
    }

    func testBothImagesAreVisibleOnTheSharedPage() throws {
        // 上红下蓝：两张图分别落在页面上半与下半
        let red = try makeSolidImage(
            width: 600, height: 380, colour: FixtureFactory.Palette.red, name: "red", in: directory)
        let blue = try makeSolidImage(
            width: 600, height: 380, colour: FixtureFactory.Palette.blue, name: "blue", in: directory)

        let url = try compose([red, blue], layout: .twoPerPage)
        let document = try XCTUnwrap(PDFRasterizer.open(url))
        let page = try XCTUnwrap(document.page(at: 1))
        let rendered = try PDFRasterizer.render(
            page: page, scale: 1, background: .white, keepsAlpha: false, maxPixels: 40_000_000
        )
        let probe = try PixelProbe(rendered)

        // 第 0 张画在上半页，第 1 张在下半页（探针 y 从上往下）
        let upperY = rendered.height / 4
        let lowerY = rendered.height * 3 / 4
        XCTAssertTrue(
            probe.pixel(x: rendered.width / 2, y: upperY).isClose(to: .red, tolerance: 45),
            "上半页应是第一张（红），实际 \(probe.pixel(x: rendered.width / 2, y: upperY))"
        )
        XCTAssertTrue(
            probe.pixel(x: rendered.width / 2, y: lowerY).isClose(to: .blue, tolerance: 45),
            "下半页应是第二张（蓝），实际 \(probe.pixel(x: rendered.width / 2, y: lowerY))"
        )
    }

    func testPageCountHelper() {
        XCTAssertEqual(PDFPageLayout.onePerPage.pageCount(forImageCount: 5), 5)
        XCTAssertEqual(PDFPageLayout.twoPerPage.pageCount(forImageCount: 5), 3)
        XCTAssertEqual(PDFPageLayout.twoPerPage.pageCount(forImageCount: 0), 0)
    }

    private func makeSolidImage(
        width: Int, height: Int,
        colour: (r: Double, g: Double, b: Double),
        name: String,
        in directory: URL
    ) throws -> URL {
        let context = try BitmapContext.make(width: width, height: height, wantsAlpha: false)
        context.setFillColor(FixtureFactory.color(colour))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let url = directory.appendingPathComponent("\(name).png")
        try ImageEncoder.encode(image, format: .png, quality: 1).write(to: url)
        return url
    }
}

private extension CGImageSource {
    func `let`<T>(_ transform: (CGImageSource) -> T) -> T { transform(self) }
}
