import CoreGraphics
import XCTest
@testable import FormatSmithCore

/// 端到端渲染测试：生成真实 PDF → 光栅化 → 按坐标采样像素。
///
/// 这是本项目最有价值的一组测试：尺寸对不对只能说明「没崩」，像素落在哪才说明「画对了」。
final class PDFRasterizerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = try FixtureFactory.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 尺寸与缩放

    func testRendersAtOriginalSizeWhenScaleIsOne() throws {
        let url = try FixtureFactory.makePDF(size: CGSize(width: 400, height: 300), in: directory)
        let document = try PDFRasterizer.open(url)
        let page = try XCTUnwrap(document.page(at: 1))

        let image = try PDFRasterizer.render(
            page: page, scale: 1, background: .white, format: .png, maxPixels: 10_000_000)
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 300)
    }

    func testDPIConversionScalesPixels() throws {
        let url = try FixtureFactory.makePDF(size: CGSize(width: 400, height: 300), in: directory)
        let document = try PDFRasterizer.open(url)
        let page = try XCTUnwrap(document.page(at: 1))

        // 144 dpi = 2 倍
        let image = try PDFRasterizer.render(
            page: page, scale: 144.0 / 72.0, background: .white, format: .png, maxPixels: 10_000_000)
        XCTAssertEqual(image.width, 800)
        XCTAssertEqual(image.height, 600)
    }

    func testPageSizeReportsDisplaySize() throws {
        let url = try FixtureFactory.makePDF(size: CGSize(width: 400, height: 300), in: directory)
        XCTAssertEqual(PDFRasterizer.pageSize(of: url), CGSize(width: 400, height: 300))
        XCTAssertEqual(PDFRasterizer.pageCount(of: url), 1)
    }

    // MARK: - 内容位置

    func testPaintedAreasLandWhereExpected() throws {
        let url = try FixtureFactory.makePDF(size: CGSize(width: 400, height: 300), in: directory)
        let document = try PDFRasterizer.open(url)
        let page = try XCTUnwrap(document.page(at: 1))
        let image = try PDFRasterizer.render(
            page: page, scale: 1, background: .white, format: .png, maxPixels: 10_000_000)
        let probe = try PixelProbe(image)

        // 红块在 x 30…130、y 170…270（点，原点左下）→ 距顶部 30…130，中心约 (80, 80)
        XCTAssertTrue(
            probe.pixel(x: 80, y: 80).isClose(to: .red, tolerance: 40),
            "红块中心应是红色，实际 \(probe.pixel(x: 80, y: 80))"
        )
        // 蓝圆圆心 (300, 220) → 距顶部 80
        XCTAssertTrue(
            probe.pixel(x: 300, y: 80).isClose(to: .blue, tolerance: 40),
            "蓝圆中心应是蓝色，实际 \(probe.pixel(x: 300, y: 80))"
        )
        // 未绘制区域应是白底
        XCTAssertTrue(
            probe.pixel(x: 200, y: 260).isClose(to: .white, tolerance: 12),
            "空白处应是白底，实际 \(probe.pixel(x: 200, y: 260))"
        )
    }

    // MARK: - /Rotate 回归测试

    func testRotation90SwapsCanvasAndMovesContentCorrectly() throws {
        let url = try FixtureFactory.makePDF(size: CGSize(width: 400, height: 300), rotation: 90, in: directory)
        let document = try PDFRasterizer.open(url)
        let page = try XCTUnwrap(document.page(at: 1))

        XCTAssertEqual(PDFRasterizer.displaySize(of: page), CGSize(width: 300, height: 400))

        let image = try PDFRasterizer.render(
            page: page, scale: 1, background: .white, format: .png, maxPixels: 10_000_000)
        XCTAssertEqual(image.width, 300)
        XCTAssertEqual(image.height, 400)
        let probe = try PixelProbe(image)

        // 顺时针 90 度后：pixel_x = 原来的 y，pixel_y(距顶) = 原来的 x
        // 红块 x 30…130, y 170…270 → 像素 x 170…270、距顶 30…130，中心约 (220, 80)
        XCTAssertTrue(
            probe.pixel(x: 220, y: 80).isClose(to: .red, tolerance: 40),
            "旋转后红块应落在右上方，实际 \(probe.pixel(x: 220, y: 80))"
        )
        // 蓝圆圆心 (300, 220) → 像素 x 220、距顶 300
        XCTAssertTrue(
            probe.pixel(x: 220, y: 300).isClose(to: .blue, tolerance: 40),
            "旋转后蓝圆应在下方，实际 \(probe.pixel(x: 220, y: 300))"
        )
        // 左下角区域原本是空白
        XCTAssertTrue(
            probe.pixel(x: 40, y: 360).isClose(to: .white, tolerance: 12),
            "旋转后左下角应是空白，实际 \(probe.pixel(x: 40, y: 360))"
        )
    }

    func testRotation270SwapsCanvasAndMovesContentCorrectly() throws {
        let url = try FixtureFactory.makePDF(size: CGSize(width: 400, height: 300), rotation: 270, in: directory)
        let document = try PDFRasterizer.open(url)
        let page = try XCTUnwrap(document.page(at: 1))

        let image = try PDFRasterizer.render(
            page: page, scale: 1, background: .white, format: .png, maxPixels: 10_000_000)
        XCTAssertEqual(image.width, 300)
        XCTAssertEqual(image.height, 400)
        let probe = try PixelProbe(image)

        // 逆时针 90 度：pixel_x = h - y，pixel_y(距顶) = w - x
        // 红块中心 (80, 220) → 像素 x = 300-220 = 80、距顶 = 400-80 = 320
        XCTAssertTrue(
            probe.pixel(x: 80, y: 320).isClose(to: .red, tolerance: 40),
            "270 度旋转后红块应在左下方，实际 \(probe.pixel(x: 80, y: 320))"
        )
    }

    func testRotation180KeepsCanvasSize() throws {
        let url = try FixtureFactory.makePDF(size: CGSize(width: 400, height: 300), rotation: 180, in: directory)
        let document = try PDFRasterizer.open(url)
        let page = try XCTUnwrap(document.page(at: 1))

        let image = try PDFRasterizer.render(
            page: page, scale: 1, background: .white, format: .png, maxPixels: 10_000_000)
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 300)

        let probe = try PixelProbe(image)
        // 红块 x 30…130 → 翻转后 270…370；距顶 30…130 → 170…270
        XCTAssertTrue(
            probe.pixel(x: 320, y: 220).isClose(to: .red, tolerance: 40),
            "180 度旋转后红块应在右下方，实际 \(probe.pixel(x: 320, y: 220))"
        )
    }

    // MARK: - 背景与透明

    func testTransparentBackgroundLeavesUnpaintedAreaClear() throws {
        let url = try FixtureFactory.makePDF(
            size: CGSize(width: 400, height: 300), fillBackground: false, in: directory)
        let document = try PDFRasterizer.open(url)
        let page = try XCTUnwrap(document.page(at: 1))

        let image = try PDFRasterizer.render(
            page: page, scale: 1, background: .transparent, format: .png, maxPixels: 10_000_000
        )
        let probe = try PixelProbe(image)
        XCTAssertEqual(probe.pixel(x: 300, y: 250).a, 0, "未绘制区域应完全透明")
        XCTAssertTrue(probe.pixel(x: 80, y: 80).isClose(to: .red, tolerance: 40), "红块仍应不透明")
    }

    func testWhiteBackgroundFillsUnpaintedArea() throws {
        let url = try FixtureFactory.makePDF(
            size: CGSize(width: 400, height: 300), fillBackground: false, in: directory)
        let document = try PDFRasterizer.open(url)
        let page = try XCTUnwrap(document.page(at: 1))

        let image = try PDFRasterizer.render(
            page: page, scale: 1, background: .white, format: .png, maxPixels: 10_000_000
        )
        let probe = try PixelProbe(image)
        XCTAssertTrue(probe.pixel(x: 300, y: 250).isClose(to: .white, tolerance: 12))
    }

    func testOpaqueFormatForcesBackgroundEvenWhenTransparentRequested() throws {
        let url = try FixtureFactory.makePDF(
            size: CGSize(width: 400, height: 300), fillBackground: false, in: directory)
        let document = try PDFRasterizer.open(url)
        let page = try XCTUnwrap(document.page(at: 1))

        // JPEG 不支持透明，即使请求 transparent 也必须铺白底
        let image = try PDFRasterizer.render(
            page: page, scale: 1, background: .transparent, format: .jpeg, maxPixels: 10_000_000
        )
        let probe = try PixelProbe(image)
        XCTAssertTrue(probe.pixel(x: 300, y: 250).isClose(to: .white, tolerance: 12), "JPEG 应铺白底")
    }

    func testBlackBackgroundIsUsedForOpaqueFormats() throws {
        let url = try FixtureFactory.makePDF(
            size: CGSize(width: 400, height: 300), fillBackground: false, in: directory)
        let document = try PDFRasterizer.open(url)
        let page = try XCTUnwrap(document.page(at: 1))

        let image = try PDFRasterizer.render(
            page: page, scale: 1, background: .black, format: .jpeg, maxPixels: 10_000_000
        )
        let probe = try PixelProbe(image)
        XCTAssertTrue(probe.pixel(x: 300, y: 250).isClose(to: .black, tolerance: 20))
    }

    // MARK: - 保护上限

    func testExcessiveResolutionIsRejected() throws {
        let url = try FixtureFactory.makePDF(size: CGSize(width: 400, height: 300), in: directory)
        let document = try PDFRasterizer.open(url)
        let page = try XCTUnwrap(document.page(at: 1))

        XCTAssertThrowsError(
            try PDFRasterizer.render(page: page, scale: 100, background: .white, format: .png, maxPixels: 1_000_000)
        ) { error in
            guard let conversion = error as? ConversionError else {
                return XCTFail("应抛出 ConversionError，实际 \(error)")
            }
            XCTAssertTrue(conversion.message.contains("megapixel"), "错误信息应说明像素上限，实际: \(conversion.message)")
        }
    }

    // MARK: - 打开异常文档

    func testOpeningNonPDFFails() throws {
        let url = directory.appendingPathComponent("not-a.pdf")
        try Data("definitely not a pdf".utf8).write(to: url)
        XCTAssertThrowsError(try PDFRasterizer.open(url))
    }

    func testThumbnailIsGenerated() throws {
        let url = try FixtureFactory.makePDF(size: CGSize(width: 400, height: 300), in: directory)
        let thumbnail = try XCTUnwrap(PDFRasterizer.thumbnail(for: url, maxSize: 100))
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 100)
    }
}
