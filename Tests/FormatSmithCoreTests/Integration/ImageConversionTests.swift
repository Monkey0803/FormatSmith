import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import FormatSmithCore

/// 图片 → 图片 的端到端测试。
final class ImageConversionTests: XCTestCase {

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

    private func settings(format: ImageFormat, scale: Double = 1) -> ConversionSettings {
        var settings = ConversionSettings()
        settings.target = .image(format)
        settings.resolutionMode = .scale
        settings.scale = scale
        settings.outputDirectoryPath = outputDirectory.path
        settings.perFileSubfolder = false
        settings.filenamePattern = "{name}"
        return settings
    }

    private func convert(_ url: URL, _ settings: ConversionSettings) -> ConversionResult {
        ConversionEngine.convert(
            document: SourceDocument.make(from: url),
            target: settings.target,
            settings: settings,
            cancellation: CancellationFlag()
        )
    }

    // MARK: - 格式转换

    func testPNGToJPEGKeepsPixelsAndChangesType() throws {
        let source = try FixtureFactory.makeImage(width: 120, height: 80, format: .png, named: "photo", in: directory)
        let result = convert(source, settings(format: .jpeg))

        XCTAssertNil(result.error)
        XCTAssertEqual(result.producedCount, 1)

        let written = try XCTUnwrap(result.outputFiles.first)
        XCTAssertEqual(written.lastPathComponent, "photo.jpg")

        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, ImageFormat.jpeg.identifier)

        let rendered = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(rendered.width, 120)
        XCTAssertEqual(rendered.height, 80)

        // 内容位置不能变
        let probe = try PixelProbe(rendered)
        XCTAssertTrue(probe.pixel(x: 20, y: 20).isClose(to: .red, tolerance: 40), "实际 \(probe.pixel(x: 20, y: 20))")
        XCTAssertTrue(probe.pixel(x: 100, y: 60).isClose(to: .blue, tolerance: 40), "实际 \(probe.pixel(x: 100, y: 60))")
    }

    func testEveryCuratedFormatCanBeATargetForAnImage() throws {
        let source = try FixtureFactory.makeImage(width: 64, height: 64, format: .png, named: "src", in: directory)

        for format in FormatRegistry.curated {
            let result = convert(source, settings(format: format))
            XCTAssertNil(result.error, "转 \(format.displayName) 失败: \(result.error?.message ?? "")")

            let written = try XCTUnwrap(result.outputFiles.first)
            XCTAssertEqual(written.pathExtension, format.fileExtension)

            let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, format.identifier)
        }
    }

    // MARK: - 缩放

    func testScalingUpAndDown() throws {
        let source = try FixtureFactory.makeImage(width: 120, height: 80, format: .png, named: "src", in: directory)

        let doubled = convert(source, settings(format: .png, scale: 2))
        let doubledImage = try XCTUnwrap(
            CGImageSourceCreateWithURL(try XCTUnwrap(doubled.outputFiles.first) as CFURL, nil))
        let big = try XCTUnwrap(CGImageSourceCreateImageAtIndex(doubledImage, 0, nil))
        XCTAssertEqual(big.width, 240)
        XCTAssertEqual(big.height, 160)

        var half = settings(format: .png, scale: 0.5)
        half.filenamePattern = "half"
        let halved = convert(source, half)
        let halvedSource = try XCTUnwrap(
            CGImageSourceCreateWithURL(try XCTUnwrap(halved.outputFiles.first) as CFURL, nil))
        let small = try XCTUnwrap(CGImageSourceCreateImageAtIndex(halvedSource, 0, nil))
        XCTAssertEqual(small.width, 60)
        XCTAssertEqual(small.height, 40)
    }

    func testDPIDoesNotMagnifyImages() throws {
        // 曾经把 DPI 当作图片的放大倍数（144 DPI = 2×），
        // 结果默认的 200 DPI 会把照片放大 2.78 倍，手机原图直接撞上像素上限。
        // 图片有自己的像素尺寸，放大必须由用户显式选择倍数。
        var settings = settings(format: .png)
        settings.resolutionMode = .dpi
        settings.dpi = 144
        settings.scale = 1
        settings.filenamePattern = "dpi"

        let result = convert(
            try FixtureFactory.makeImage(width: 100, height: 50, format: .png, named: "src", in: directory),
            settings
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(try XCTUnwrap(result.outputFiles.first) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 100, "DPI 不该改变图片的输出尺寸")
        XCTAssertEqual(image.height, 50)
    }

    func testScaleMagnifiesImagesWhenAskedExplicitly() throws {
        var settings = settings(format: .png)
        settings.scale = 2
        settings.resolutionMode = .scale
        settings.filenamePattern = "twice"

        let result = convert(
            try FixtureFactory.makeImage(width: 100, height: 50, format: .png, named: "src", in: directory),
            settings
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(try XCTUnwrap(result.outputFiles.first) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 200, "显式选了 2× 才放大")
        XCTAssertEqual(image.height, 100)
    }

    func testAbsurdScaleIsRejected() throws {
        let source = try FixtureFactory.makeImage(width: 120, height: 80, format: .png, named: "src", in: directory)
        // 120×80 的图放大 200 倍 = 3.84 亿像素，超过 1.2 亿的安全上限
        let result = convert(source, settings(format: .png, scale: 200))
        XCTAssertNotNil(result.error)
        XCTAssertEqual(result.producedCount, 0)
    }

    // MARK: - 透明通道

    func testTransparentImageKeepsAlphaInPNG() throws {
        let source = try FixtureFactory.makeTransparentImage(width: 100, height: 100, named: "ghost", in: directory)
        let result = convert(source, settings(format: .png))

        XCTAssertNil(result.error)
        let written = try XCTUnwrap(result.outputFiles.first)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))

        XCTAssertTrue(PixelProbe.hasAlphaChannel(image))
        let probe = try PixelProbe(image)
        XCTAssertEqual(probe.pixel(x: 5, y: 5).a, 0, "未绘制区域应保持透明")
        XCTAssertEqual(probe.pixel(x: 50, y: 50).a, 255, "红块应不透明")
    }

    func testTransparentImageIsFlattenedForOpaqueFormats() throws {
        let source = try FixtureFactory.makeTransparentImage(width: 100, height: 100, named: "ghost", in: directory)

        for (background, expected) in [(ImageBackground.white, PixelProbe.RGBA.white), (.black, .black)] {
            var configuration = settings(format: .jpeg)
            configuration.background = background
            configuration.filenamePattern = "flat-\(background.rawValue)"
            let result = convert(source, configuration)

            XCTAssertNil(result.error)
            let written = try XCTUnwrap(result.outputFiles.first)
            let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))

            XCTAssertFalse(PixelProbe.hasAlphaChannel(image), "JPEG 不应带 alpha")
            let probe = try PixelProbe(image)
            XCTAssertTrue(
                probe.pixel(x: 5, y: 5).isClose(to: expected, tolerance: 20),
                "\(background.rawValue) 背景应填充透明区域，实际 \(probe.pixel(x: 5, y: 5))"
            )
        }
    }

    // MARK: - 路由入口

    func testRouterEntryPointHandlesImages() throws {
        let source = try FixtureFactory.makeImage(width: 64, height: 64, format: .png, named: "src", in: directory)
        let result = ConversionEngine.convert(
            document: SourceDocument.make(from: source),
            target: .image(.tiff),
            settings: settings(format: .tiff),
            cancellation: CancellationFlag()
        )
        XCTAssertNil(result.error)
        XCTAssertEqual(result.outputFiles.first?.pathExtension, "tiff")
    }

    // MARK: - 命名

    func testSingleImageOutputHasNoPageSuffix() throws {
        let source = try FixtureFactory.makeImage(width: 64, height: 64, format: .png, named: "holiday", in: directory)
        var configuration = settings(format: .png)
        configuration.filenamePattern = "{name}-{page}"

        let result = convert(source, configuration)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.outputFiles.first?.lastPathComponent, "holiday.png")
    }
}
