import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import FormatSmithCore

/// 转换编排的端到端测试：从磁盘上的 PDF 到磁盘上的图片。
final class ConversionEngineTests: XCTestCase {

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

    private func settings(format: ImageFormat = .png, subfolder: Bool = false) -> ConversionSettings {
        var settings = ConversionSettings()
        settings.format = format
        settings.resolutionMode = .scale
        settings.scale = 1
        settings.outputDirectoryPath = outputDirectory.path
        settings.perFileSubfolder = subfolder
        settings.padsPageNumbers = false
        return settings
    }

    // MARK: - 多页导出

    func testExportsEveryPageAsASeparateFile() throws {
        let pdf = try FixtureFactory.makePDF(pages: 3, named: "doc", in: directory)
        let document = SourceDocument.make(from: pdf)

        let result = ConversionEngine.convertPDFToImages(
            document: document,
            settings: settings(),
            cancellation: CancellationFlag()
        )

        XCTAssertNil(result.error)
        XCTAssertEqual(result.producedCount, 3)
        XCTAssertEqual(result.outputFolder, outputDirectory)

        let names = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path).sorted()
        XCTAssertEqual(names, ["doc-1.png", "doc-2.png", "doc-3.png"])
    }

    func testOutputIsWrittenIntoPerFileSubfolderWhenEnabled() throws {
        let pdf = try FixtureFactory.makePDF(pages: 2, named: "report", in: directory)
        let document = SourceDocument.make(from: pdf)

        let result = ConversionEngine.convertPDFToImages(
            document: document,
            settings: settings(subfolder: true),
            cancellation: CancellationFlag()
        )

        XCTAssertNil(result.error)
        let folder = try XCTUnwrap(result.outputFolder)
        XCTAssertEqual(folder.lastPathComponent, "report")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("report-1.png").path))
    }

    func testPageRangeLimitsOutput() throws {
        let pdf = try FixtureFactory.makePDF(pages: 5, named: "doc", in: directory)
        let document = SourceDocument.make(from: pdf)

        var configuration = settings()
        configuration.pageRangeMode = .custom
        configuration.pageRangeText = "2-3"

        let result = ConversionEngine.convertPDFToImages(
            document: document,
            settings: configuration,
            cancellation: CancellationFlag()
        )

        XCTAssertNil(result.error)
        XCTAssertEqual(result.producedCount, 2)
        let names = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path).sorted()
        XCTAssertEqual(names, ["doc-2.png", "doc-3.png"])
    }

    func testInvalidPageRangeFailsWithClearError() throws {
        let pdf = try FixtureFactory.makePDF(pages: 2, named: "doc", in: directory)
        let document = SourceDocument.make(from: pdf)

        var configuration = settings()
        configuration.pageRangeMode = .custom
        configuration.pageRangeText = "99-120"

        let result = ConversionEngine.convertPDFToImages(
            document: document,
            settings: configuration,
            cancellation: CancellationFlag()
        )

        XCTAssertNotNil(result.error)
        XCTAssertEqual(result.producedCount, 0)
    }

    // MARK: - 输出正确性

    func testExportedFileHasRequestedDimensionsAndContent() throws {
        let pdf = try FixtureFactory.makePDF(size: CGSize(width: 400, height: 300), named: "doc", in: directory)
        let document = SourceDocument.make(from: pdf)

        var configuration = settings()
        configuration.resolutionMode = .dpi
        configuration.dpi = 144  // 2 倍

        let result = ConversionEngine.convertPDFToImages(
            document: document,
            settings: configuration,
            cancellation: CancellationFlag()
        )
        XCTAssertNil(result.error)

        let written = try XCTUnwrap(result.outputFiles.first)
        XCTAssertEqual(written.pathExtension, "png")

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))
        let rendered = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(rendered.width, 800)
        XCTAssertEqual(rendered.height, 600)

        // 红块在 2 倍缩放后应落在 (160, 160) 附近
        let probe = try PixelProbe(rendered)
        XCTAssertTrue(probe.pixel(x: 160, y: 160).isClose(to: .red, tolerance: 40))
    }

    func testHonorsOutputFormat() throws {
        let pdf = try FixtureFactory.makePDF(pages: 1, named: "doc", in: directory)
        let document = SourceDocument.make(from: pdf)

        for format in [ImageFormat.jpeg, .tiff, .heic] {
            var configuration = settings(format: format)
            configuration.filenamePattern = "{name}-\(format.fileExtension)"

            let result = ConversionEngine.convertPDFToImages(
                document: document,
                settings: configuration,
                cancellation: CancellationFlag()
            )
            XCTAssertNil(result.error, "\(format.displayName) 转换失败: \(result.error?.message ?? "")")

            let written = try XCTUnwrap(result.outputFiles.first)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))
            let type = CGImageSourceGetType(source) as String?
            XCTAssertEqual(type, format.identifier, "写出的类型应是 \(format.displayName)")
        }
    }

    // MARK: - 命名与保护

    func testExistingFilesAreNotOverwritten() throws {
        let pdf = try FixtureFactory.makePDF(pages: 1, named: "doc", in: directory)
        let document = SourceDocument.make(from: pdf)

        let first = ConversionEngine.convertPDFToImages(
            document: document, settings: settings(), cancellation: CancellationFlag()
        )
        let second = ConversionEngine.convertPDFToImages(
            document: document, settings: settings(), cancellation: CancellationFlag()
        )

        XCTAssertNil(first.error)
        XCTAssertNil(second.error)
        let names = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path).sorted()
        XCTAssertEqual(names, ["doc-1-1.png", "doc-1.png"])
    }

    // MARK: - 进度与取消

    func testProgressIsReportedForEveryPage() throws {
        let pdf = try FixtureFactory.makePDF(pages: 4, named: "doc", in: directory)
        let document = SourceDocument.make(from: pdf)

        let lock = NSLock()
        var reported: [Int] = []
        let observer = ConversionObserver(onProgress: { progress in
            lock.lock()
            reported.append(progress.completedUnits)
            lock.unlock()
        })

        let result = ConversionEngine.convertPDFToImages(
            document: document,
            settings: settings(),
            cancellation: CancellationFlag(),
            observer: observer
        )

        XCTAssertNil(result.error)
        XCTAssertEqual(reported, [1, 2, 3, 4])
    }

    func testCancellationStopsTheConversion() throws {
        let pdf = try FixtureFactory.makePDF(pages: 5, named: "doc", in: directory)
        let document = SourceDocument.make(from: pdf)

        let flag = CancellationFlag()
        flag.cancel()

        let result = ConversionEngine.convertPDFToImages(
            document: document, settings: settings(), cancellation: flag
        )

        XCTAssertNotNil(result.error)
        XCTAssertEqual(result.producedCount, 0)
    }

    func testProgressFractionSpansWholeRun() {
        let first = ConversionProgress(completedUnits: 0, totalUnits: 4, fileIndex: 0, fileCount: 4)
        XCTAssertEqual(first.fraction, 0, accuracy: 0.0001)

        let middle = ConversionProgress(completedUnits: 2, totalUnits: 4, fileIndex: 2, fileCount: 4)
        XCTAssertEqual(middle.fraction, 0.625, accuracy: 0.0001)

        let last = ConversionProgress(completedUnits: 4, totalUnits: 4, fileIndex: 3, fileCount: 4)
        XCTAssertEqual(last.fraction, 1.0, accuracy: 0.0001)
    }

    // MARK: - 元信息

    func testInspectReadsPageCountAndSize() throws {
        let pdf = try FixtureFactory.makePDF(
            pages: 3, size: CGSize(width: 400, height: 300), named: "doc", in: directory)
        let info = ConversionEngine.inspect(pdf)
        XCTAssertEqual(info.kind, .pdf)
        XCTAssertEqual(info.pageCount, 3)
        XCTAssertEqual(info.displaySize, CGSize(width: 400, height: 300))
    }

    func testInspectReadsImageSize() throws {
        let png = try FixtureFactory.makeImage(width: 120, height: 80, in: directory)
        let info = ConversionEngine.inspect(png)
        XCTAssertTrue(info.kind.isImage)
        XCTAssertEqual(info.pageCount, 1)
        XCTAssertEqual(info.displaySize, CGSize(width: 120, height: 80))
    }

    func testSourceDocumentPicksUpFileMetadata() throws {
        let pdf = try FixtureFactory.makePDF(named: "doc", in: directory)
        let document = SourceDocument.make(from: pdf)
        XCTAssertEqual(document.kind, .pdf)
        XCTAssertEqual(document.displayName, "doc")
        XCTAssertGreaterThan(document.byteSize, 0)
    }
}
