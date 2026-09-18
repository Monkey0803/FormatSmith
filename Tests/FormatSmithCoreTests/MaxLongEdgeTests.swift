import CoreGraphics
import Foundation
import XCTest
@testable import FormatSmithCore

/// 最长边限制。
///
/// 加它的直接原因：「邮件」预设写着「小到能当附件」，实际只换了格式和质量，
/// 一张 48MP 的手机照片原样输出，尺寸一个像素没变。
final class MaxLongEdgeTests: XCTestCase {

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

    private func settings(_ configure: (inout ConversionSettings) -> Void = { _ in }) -> ConversionSettings {
        var settings = ConversionSettings()
        settings.target = .image(.jpeg)
        settings.outputDirectoryPath = output.path
        settings.perFileSubfolder = false
        settings.filenamePattern = "out"
        configure(&settings)
        return settings
    }

    /// 真正转换一次，返回产出的像素尺寸。
    private func rendered(_ url: URL, settings: ConversionSettings) throws -> (width: Int, height: Int) {
        let result = ConversionEngine.convert(
            document: SourceDocument.make(from: url),
            target: settings.target,
            settings: settings,
            cancellation: CancellationFlag()
        )
        XCTAssertNil(result.error)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(try XCTUnwrap(result.outputFiles.first) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    // MARK: - 基本行为

    func testLandscapeImageIsShrunkToTheLimit() throws {
        let url = try FixtureFactory.makeImage(width: 4000, height: 3000, named: "big", in: directory)
        let settings = settings { $0.maxLongEdge = 1600 }

        let size = try rendered(url, settings: settings)
        XCTAssertEqual(size.width, 1600)
        XCTAssertEqual(size.height, 1200, "比例要保持")
    }

    func testPortraitImageIsShrunkByItsHeight() throws {
        let url = try FixtureFactory.makeImage(width: 3000, height: 4000, named: "tall", in: directory)
        let settings = settings { $0.maxLongEdge = 1600 }

        let size = try rendered(url, settings: settings)
        XCTAssertEqual(size.width, 1200)
        XCTAssertEqual(size.height, 1600, "竖图的长边是高")
    }

    func testSmallImageIsNeverEnlarged() throws {
        let url = try FixtureFactory.makeImage(width: 800, height: 600, named: "small", in: directory)
        let settings = settings { $0.maxLongEdge = 4000 }

        let size = try rendered(url, settings: settings)
        XCTAssertEqual(size.width, 800, "比上限小的图不该被放大")
        XCTAssertEqual(size.height, 600)
    }

    func testZeroMeansNoLimit() throws {
        let url = try FixtureFactory.makeImage(width: 2000, height: 1000, named: "wide", in: directory)
        let settings = settings { $0.maxLongEdge = 0 }

        let size = try rendered(url, settings: settings)
        XCTAssertEqual(size.width, 2000)
        XCTAssertEqual(size.height, 1000)
    }

    func testScaleAndLimitTakeTheSmallerOne() throws {
        let url = try FixtureFactory.makeImage(width: 4000, height: 3000, named: "big", in: directory)

        // 倍数 0.5 → 2000；最长边 1000 → 取更小的 1000
        let limited = try rendered(
            url,
            settings: settings {
                $0.scale = 0.5
                $0.maxLongEdge = 1000
            })
        XCTAssertEqual(limited.width, 1000)

        // 倍数 0.25 → 1000；最长边 3000 不起作用
        let scaled = try rendered(
            url,
            settings: settings {
                $0.scale = 0.25
                $0.maxLongEdge = 3000
            })
        XCTAssertEqual(scaled.width, 1000, "倍数更小时应当以倍数为准")
    }

    // MARK: - 估算要一致

    func testEstimateMatchesTheExportedSize() throws {
        let url = try FixtureFactory.makeImage(width: 4000, height: 3000, named: "big", in: directory)
        let settings = settings { $0.maxLongEdge = 2048 }

        let document = SourceDocument.make(from: url)
        let estimate = settings.estimatedPixelSize(for: document.info)
        XCTAssertEqual(estimate?.width, 2048)
        XCTAssertEqual(estimate?.height, 1536)

        let size = try rendered(url, settings: settings)
        XCTAssertEqual(size.width, estimate?.width, "估算必须等于实际产出")
        XCTAssertEqual(size.height, estimate?.height)
    }

    // MARK: - 元信息

    func testMakeFromURLKnowsTheSizeAndPageCount() throws {
        // 这是个真实缺陷的回归测试：`make(from:)` 以前不探测尺寸，
        // 于是所有依赖尺寸的设置（比如最长边）对没单独探测过的调用方静默失效。
        let image = try FixtureFactory.makeImage(width: 640, height: 480, named: "img", in: directory)
        let document = SourceDocument.make(from: image)
        XCTAssertGreaterThan(document.size.width, 0, "图片必须有尺寸")
        XCTAssertEqual(document.size.width, 640)
        XCTAssertEqual(document.pageCount, 1, "图片算一页")

        let pdf = try FixtureFactory.makePDF(pages: 3, named: "doc", in: directory)
        let pdfDocument = SourceDocument.make(from: pdf)
        XCTAssertEqual(pdfDocument.pageCount, 3)
        XCTAssertGreaterThan(pdfDocument.size.width, 0)
    }

    func testDocumentInfoUsesTheDocumentSize() throws {
        let url = try FixtureFactory.makeImage(width: 4000, height: 3000, named: "big", in: directory)
        var settings = ConversionSettings()
        let document = SourceDocument.make(from: url)

        settings.maxLongEdge = 1600
        XCTAssertEqual(settings.imageScale(for: document.info), 0.4, accuracy: 0.001, "1600/4000")

        settings.maxLongEdge = 8000
        XCTAssertEqual(settings.imageScale(for: document.info), 1, "比原图大就不缩也不放")
    }
}
