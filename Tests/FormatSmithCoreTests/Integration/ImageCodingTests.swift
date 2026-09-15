import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import FormatSmithCore

/// 编码/解码管线测试：每种可写格式都真实跑一遍。
final class ImageCodingTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = try FixtureFactory.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeTestImage(wantsAlpha: Bool = false, width: Int = 64, height: Int = 48) throws -> CGImage {
        let context = try BitmapContext.make(width: width, height: height, wantsAlpha: wantsAlpha)
        if !wantsAlpha { context.fill(with: .white) }
        context.setFillColor(FixtureFactory.color(FixtureFactory.Palette.red))
        context.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
        return try XCTUnwrap(context.makeImage())
    }

    // MARK: - 所有精选格式都能编码并回读

    func testEveryCuratedFormatRoundTrips() throws {
        let image = try makeTestImage()
        for format in FormatRegistry.curated {
            let data = try ImageEncoder.encode(image, format: format, quality: 0.9)
            XCTAssertFalse(data.isEmpty, "\(format.displayName) 编码结果为空")

            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                return XCTFail("\(format.displayName) 无法回读")
            }
            XCTAssertEqual(decoded.width, 64, "\(format.displayName) 宽度不对")
            XCTAssertEqual(decoded.height, 48, "\(format.displayName) 高度不对")

            // 声明的类型要和实际写出的类型一致
            let written = CGImageSourceGetType(source) as String?
            XCTAssertEqual(written, format.identifier, "\(format.displayName) 实际写出的是 \(written ?? "nil")")
        }
    }

    func testLongTailFormatsRoundTrip() throws {
        // 用正方形，满足 ICO 的尺寸约束。
        let image = try makeTestImage(width: 64, height: 64)
        for format in FormatRegistry.allWritable {
            let data = try ImageEncoder.encode(image, format: format, quality: 0.9)
            XCTAssertFalse(data.isEmpty, "\(format.displayName) 编码结果为空")

            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(decoded.width, 64, "\(format.displayName) 回读宽度不对")
        }
    }

    func testNonSquareOutputForICOIsRejectedWithClearMessage() throws {
        let ico = ImageFormat("com.microsoft.ico")
        guard ico.isWritableBySystem else { throw XCTSkip("这台机器不支持写 ICO") }

        let wide = try makeTestImage(width: 64, height: 48)
        XCTAssertThrowsError(try ImageEncoder.encode(wide, format: ico, quality: 1)) { error in
            guard let conversion = error as? ConversionError else {
                return XCTFail("应抛出 ConversionError，实际 \(error)")
            }
            XCTAssertTrue(conversion.message.contains("square"), "错误信息应说明需要正方形: \(conversion.message)")
        }

        let square = try makeTestImage(width: 64, height: 64)
        let data = try ImageEncoder.encode(square, format: ico, quality: 1)
        XCTAssertFalse(data.isEmpty)
    }

    func testUpscalingPreservesContentPosition() throws {
        let url = try FixtureFactory.makeImage(width: 120, height: 80, in: directory)
        let image = try ImageDecoder.decode(url: url, scale: 2, maxPixels: 10_000_000)
        let probe = try PixelProbe(image)
        // 红块原本在左上，放大后仍应在左上
        XCTAssertTrue(probe.pixel(x: 40, y: 40).isClose(to: .red, tolerance: 40), "实际 \(probe.pixel(x: 40, y: 40))")
        XCTAssertTrue(
            probe.pixel(x: 200, y: 120).isClose(to: .blue, tolerance: 40), "实际 \(probe.pixel(x: 200, y: 120))")
    }

    func testResampleKeepsTransparency() throws {
        let url = try FixtureFactory.makeTransparentImage(width: 40, height: 40, in: directory)
        let image = try ImageDecoder.decode(url: url, scale: 2, maxPixels: 1_000_000)
        XCTAssertEqual(image.width, 80)
        XCTAssertTrue(PixelProbe.hasAlphaChannel(image), "放大后仍应保留 alpha")
        let probe = try PixelProbe(image)
        XCTAssertEqual(probe.pixel(x: 5, y: 5).a, 0, "未绘制区域放大后仍应透明")
    }

    // MARK: - 透明通道

    func testAlphaSurvivesPNGButNotJPEG() throws {
        let image = try makeTestImage(wantsAlpha: true)

        let png = try ImageEncoder.encode(image, format: .png, quality: 1)
        let pngSource = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let pngImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(pngSource, 0, nil))
        XCTAssertTrue(PixelProbe.hasAlphaChannel(pngImage), "PNG 应带 alpha 通道")

        let jpeg = try ImageEncoder.encode(image, format: .jpeg, quality: 1)
        let jpegSource = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let jpegImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(jpegSource, 0, nil))
        XCTAssertFalse(PixelProbe.hasAlphaChannel(jpegImage), "JPEG 不应带 alpha 通道")
    }

    // MARK: - 质量参数

    func testLowerQualityProducesSmallerJPEG() throws {
        // 用带渐变的图，避免纯色导致不同质量下体积相同。
        let width = 256
        let height = 256
        let context = try BitmapContext.make(width: width, height: height, wantsAlpha: false)
        for y in 0..<height {
            let shade = Double(y) / Double(height)
            context.setFillColor(CGColor(red: shade, green: 1 - shade, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        let image = try XCTUnwrap(context.makeImage())

        let high = try ImageEncoder.encode(image, format: .jpeg, quality: 0.95)
        let low = try ImageEncoder.encode(image, format: .jpeg, quality: 0.2)
        XCTAssertLessThan(low.count, high.count, "低质量文件应更小（low=\(low.count), high=\(high.count)）")
    }

    func testQualityIsIgnoredForLosslessFormatsWithoutFailing() throws {
        let image = try makeTestImage()
        let low = try ImageEncoder.encode(image, format: .png, quality: 0.05)
        let high = try ImageEncoder.encode(image, format: .png, quality: 1.0)
        XCTAssertEqual(low.count, high.count, "无损格式不应受质量参数影响")
    }

    // MARK: - 写盘

    func testWriteCreatesDirectoryAndFile() throws {
        let image = try makeTestImage()
        let nested = directory.appendingPathComponent("a/b/c/shot.png")
        let written = try ImageEncoder.write(image, format: .png, quality: 1, to: nested)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
        XCTAssertEqual(written.lastPathComponent, "shot.png")
    }

    func testWriteNeverOverwritesExistingFile() throws {
        let image = try makeTestImage()
        let target = directory.appendingPathComponent("same.png")
        let first = try ImageEncoder.write(image, format: .png, quality: 1, to: target)
        let second = try ImageEncoder.write(image, format: .png, quality: 1, to: target)
        XCTAssertEqual(first.lastPathComponent, "same.png")
        XCTAssertEqual(second.lastPathComponent, "same-1.png")
        XCTAssertNotEqual(first, second)
    }

    func testUnsupportedFormatThrows() throws {
        let image = try makeTestImage()
        let webp = ImageFormat("org.webmproject.webp")
        guard !webp.isWritableBySystem else {
            throw XCTSkip("这台机器居然能写 WebP，跳过")
        }
        XCTAssertThrowsError(try ImageEncoder.encode(image, format: webp, quality: 0.9)) { error in
            guard let conversion = error as? ConversionError else {
                return XCTFail("应抛出 ConversionError，实际 \(error)")
            }
            XCTAssertTrue(conversion.message.contains("WebP"))
        }
    }

    // MARK: - 解码

    func testDecodeKeepsOriginalPixelSizeAtScaleOne() throws {
        let url = try FixtureFactory.makeImage(width: 120, height: 80, in: directory)
        let image = try ImageDecoder.decode(url: url, scale: 1, maxPixels: 10_000_000)
        XCTAssertEqual(image.width, 120)
        XCTAssertEqual(image.height, 80)
    }

    func testDecodeScalesUp() throws {
        let url = try FixtureFactory.makeImage(width: 120, height: 80, in: directory)
        let image = try ImageDecoder.decode(url: url, scale: 2, maxPixels: 10_000_000)
        XCTAssertEqual(image.width, 240)
        XCTAssertEqual(image.height, 160)
    }

    func testDecodeRespectsPixelLimit() throws {
        let url = try FixtureFactory.makeImage(width: 120, height: 80, in: directory)
        XCTAssertThrowsError(try ImageDecoder.decode(url: url, scale: 10, maxPixels: 100_000))
    }

    func testDecodeReportsSizeAndFrames() throws {
        let url = try FixtureFactory.makeImage(width: 120, height: 80, in: directory)
        XCTAssertEqual(ImageDecoder.displaySize(of: url), CGSize(width: 120, height: 80))
        XCTAssertEqual(ImageDecoder.frameCount(of: url), 1)
    }

    func testDecodedOrientationMatchesTheOriginalDrawing() throws {
        let url = try FixtureFactory.makeImage(width: 120, height: 80, in: directory)
        let image = try ImageDecoder.decode(url: url, scale: 1, maxPixels: 10_000_000)
        let probe = try PixelProbe(image)

        // 生成时红块在左上、蓝块在右下
        XCTAssertTrue(
            probe.pixel(x: 20, y: 20).isClose(to: .red, tolerance: 40), "左上应为红，实际 \(probe.pixel(x: 20, y: 20))")
        XCTAssertTrue(
            probe.pixel(x: 100, y: 60).isClose(to: .blue, tolerance: 40), "右下应为蓝，实际 \(probe.pixel(x: 100, y: 60))")
    }
}
