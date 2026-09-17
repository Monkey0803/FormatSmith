import CoreGraphics
import Foundation
import XCTest
@testable import FormatSmithCore

/// 通用预览：每条管线都要能给出「导出后长什么样」，而且必须和真实输出一致。
final class OutputPreviewTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = try FixtureFactory.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func settings(_ configure: (inout ConversionSettings) -> Void = { _ in }) -> ConversionSettings {
        var settings = ConversionSettings()
        settings.outputDirectoryPath = directory.path
        settings.perFileSubfolder = false
        configure(&settings)
        return settings
    }

    // MARK: - 图片 → 图片

    func testImagePreviewReportsTheRealOutputSize() throws {
        let source = try FixtureFactory.makeImage(width: 800, height: 600, named: "src", in: directory)
        var settings = settings { $0.scale = 0.5 }

        let preview = try OutputPreview.render(
            documents: [SourceDocument.make(from: source)],
            target: settings.target,
            settings: settings
        )

        XCTAssertEqual(preview.caption, "400 × 300 px", "说明文字应当给真实输出尺寸，而不是缩略图尺寸")
        XCTAssertEqual(preview.fileCount, 1)
    }

    func testImagePreviewHugeOutputIsShrunkButCaptionStaysTrue() throws {
        let source = try FixtureFactory.makeImage(width: 4000, height: 3000, named: "big", in: directory)
        let settings = settings { $0.scale = 1 }

        let preview = try OutputPreview.render(
            documents: [SourceDocument.make(from: source)],
            target: settings.target,
            settings: settings,
            maxPixels: 100_000
        )

        XCTAssertEqual(preview.caption, "4000 × 3000 px")
        XCTAssertLessThanOrEqual(
            preview.image.width * preview.image.height, 200_000,
            "预览图本身应当被压到上限附近"
        )
    }

    func testImagePreviewMatchesTheExportedFile() throws {
        let source = try FixtureFactory.makeImage(width: 400, height: 300, named: "src", in: directory)
        let settings = settings { $0.filenamePattern = "out" }

        let preview = try OutputPreview.render(
            documents: [SourceDocument.make(from: source)],
            target: settings.target,
            settings: settings
        )

        let result = ConversionEngine.convert(
            document: SourceDocument.make(from: source),
            target: settings.target,
            settings: settings,
            cancellation: CancellationFlag()
        )
        let written = try XCTUnwrap(result.outputFiles.first)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))
        let exported = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))

        XCTAssertEqual(preview.image.width, exported.width, "预览尺寸应当就是导出尺寸")
        XCTAssertEqual(preview.image.height, exported.height)

        let a = try PixelProbe(preview.image)
        let b = try PixelProbe(exported)
        for point in [(20, 20), (a.width / 2, a.height / 2), (a.width - 20, a.height - 20)] {
            XCTAssertTrue(
                a.pixel(x: point.0, y: point.1).isClose(to: b.pixel(x: point.0, y: point.1), tolerance: 12),
                "预览与导出在 \(point) 处应当一致"
            )
        }
    }

    // MARK: - 图片 → PDF

    func testPDFPagePreviewMatchesTheExportedLayout() throws {
        // 上红下蓝：预览必须和导出的 PDF 版面落在同样的位置
        let red = try FixtureFactory.makeSilhouette(
            width: 600, height: 380, colour: FixtureFactory.Palette.red, named: "red", in: directory
        )
        let blue = try FixtureFactory.makeSilhouette(
            width: 600, height: 380, colour: FixtureFactory.Palette.blue, named: "blue", in: directory
        )

        var settings = settings {
            $0.target = .pdf
            $0.pdfLayout = .twoPerPage
            $0.pdfPageSize = .a4
            $0.pdfMargin = 24
            $0.mergeImagesIntoOnePDF = true
            $0.filenamePattern = "scan"
        }

        let documents = [SourceDocument.make(from: red), SourceDocument.make(from: blue)]
        let preview = try OutputPreview.render(documents: documents, target: settings.target, settings: settings)

        // 导出真的做一遍
        let result = ConversionEngine.composePDF(
            documents: documents, settings: settings, cancellation: CancellationFlag()
        )
        let pdf = try PDFRasterizer.open(try XCTUnwrap(result.outputFiles.first))
        let page = try XCTUnwrap(pdf.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        let exported = try PDFRasterizer.render(
            page: page, scale: Double(preview.image.width) / box.width,
            background: .white, format: .png, maxPixels: 40_000_000
        )

        XCTAssertEqual(preview.pageCount, 1)
        XCTAssertEqual(preview.caption, "595 × 842 pt", "A4 的磅值")

        let shown = try PixelProbe(preview.image)
        let real = try PixelProbe(exported)

        // 上半页是红、下半页是蓝 —— 两者都应当如此
        for probe in [shown, real] {
            let top = probe.pixel(x: probe.width / 2, y: probe.height / 4)
            let bottom = probe.pixel(x: probe.width / 2, y: probe.height * 3 / 4)
            XCTAssertTrue(top.isClose(to: .red, tolerance: 45), "上半页应偏红，实际 \(top)")
            XCTAssertTrue(bottom.isClose(to: .blue, tolerance: 45), "下半页应偏蓝，实际 \(bottom)")
        }
    }

    func testMergedPDFPreviewCountsEveryPage() throws {
        let urls = try (1...5).map {
            try FixtureFactory.makeImage(width: 300, height: 200, named: "p\($0)", in: directory)
        }
        var settings = settings {
            $0.target = .pdf
            $0.pdfLayout = .twoPerPage
            $0.pdfPageSize = .a4
        }

        let preview = try OutputPreview.render(
            documents: urls.map { SourceDocument.make(from: $0) },
            target: settings.target,
            settings: settings
        )
        XCTAssertEqual(preview.pageCount, 3, "五张图每页两张应当是三页")
        XCTAssertEqual(preview.fileCount, 1)
    }

    // MARK: - PDF → 图片

    func testPDFToImagePreviewRendersFirstPageAndReportsRealPixels() throws {
        let pdf = try FixtureFactory.makePDF(
            pages: 3, size: CGSize(width: 400, height: 300), named: "doc", in: directory)
        var settings = settings {
            $0.resolutionMode = .dpi
            $0.dpi = 144  // 2 倍
            $0.filenamePattern = "page"
        }

        let preview = try OutputPreview.render(
            documents: [SourceDocument.make(from: pdf)],
            target: settings.target,
            settings: settings
        )

        XCTAssertEqual(preview.caption, "800 × 600 px", "144 DPI 对 400×300pt 的页面是 2 倍")
        XCTAssertEqual(preview.pageCount, 3)
        XCTAssertEqual(preview.fileCount, 3)
    }

    func testPDFPreviewRespectsThePageRange() throws {
        let pdf = try FixtureFactory.makePDF(pages: 6, named: "doc", in: directory)
        var settings = settings {
            $0.pageRangeMode = .custom
            $0.pageRangeText = "2-4"
        }

        let preview = try OutputPreview.render(
            documents: [SourceDocument.make(from: pdf)],
            target: settings.target,
            settings: settings
        )
        XCTAssertEqual(preview.fileCount, 3, "页码范围 2-4 应当只产出 3 个文件")
    }

    // MARK: - 证件照

    func testIDPhotoPreviewUsesTheSpecAndIsNotShrunk() throws {
        let source = try FixtureFactory.makeImage(width: 1200, height: 1600, named: "portrait", in: directory)
        var settings = settings {
            $0.idPhotoEnabled = true
            $0.idPhotoSize = .oneInch
            $0.idPhotoBackground = .white
            $0.dpi = 300
        }

        let preview = try OutputPreview.render(
            documents: [SourceDocument.make(from: source)],
            target: settings.target,
            settings: settings
        )

        XCTAssertEqual(preview.caption, "295 × 413 px")
        XCTAssertEqual(preview.image.width, 295, "证件照本来就小，不该被缩成缩略图")
        XCTAssertEqual(preview.image.height, 413)
    }

    func testPhotoSheetPreviewUsesThePaperSize() throws {
        let source = try FixtureFactory.makeImage(width: 1200, height: 1600, named: "portrait", in: directory)
        var settings = settings {
            $0.idPhotoEnabled = true
            $0.printSheetEnabled = true
            $0.printSheet = .sixInch
            $0.dpi = 300
        }

        let preview = try OutputPreview.render(
            documents: [SourceDocument.make(from: source)],
            target: settings.target,
            settings: settings
        )
        XCTAssertEqual(preview.caption, "1205 × 1795 px")
    }

    // MARK: - 不支持与昂贵路线

    func testPreviewThrowsWhenThereIsNothingToConvert() {
        let settings = ConversionSettings()
        XCTAssertThrowsError(
            try OutputPreview.render(documents: [], target: settings.target, settings: settings)
        )
    }

    func testExpensiveRoutesAreReported() throws {
        let markdown = directory.appendingPathComponent("note.md")
        try "# 标题\n\n正文".write(to: markdown, atomically: true, encoding: .utf8)

        let documents = [SourceDocument.make(from: markdown)]
        XCTAssertTrue(
            OutputPreview.isExpensive(documents: documents, target: .pdf),
            "文档 → PDF 要真的跑一次转换，界面需要据此延迟触发"
        )

        let image = try FixtureFactory.makeImage(width: 100, height: 100, named: "x", in: directory)
        XCTAssertFalse(
            OutputPreview.isExpensive(documents: [SourceDocument.make(from: image)], target: .pdf)
        )
    }
}
