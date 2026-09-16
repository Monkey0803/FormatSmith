import CoreGraphics
import Foundation
import XCTest
@testable import FormatSmithCore

/// 证件照处理的几何与合成。
///
/// 真实的人像分割只认真人照片，没法用合成图验证，所以这里注入固定遮罩：
/// 裁剪位置、缩放比例、底色填充这些能算对的部分，逐像素断言。
/// 遮罩与人脸框都由测试指定。
struct FixedAnalyzer: PersonMaskProviding {
    let mask: CGImage?
    let face: CGRect?

    func personMask(for image: CGImage) throws -> CGImage? { mask }
    func faceBounds(in image: CGImage) throws -> CGRect? { face }
}

final class IDPhotoProcessorTests: XCTestCase {

    // MARK: - 尺寸与底色

    func testOutputMatchesTheRequestedSizeInPixels() throws {
        let source = try makePlainImage(width: 800, height: 1000)
        let outcome = try IDPhotoProcessor.makeIDPhoto(
            from: source,
            size: .oneInch,
            background: .white,
            dpi: 300,
            autoCrop: false,
            analyzer: FixedAnalyzer(mask: nil, face: nil)
        )

        XCTAssertEqual(outcome.image.width, 295)
        XCTAssertEqual(outcome.image.height, 413)
    }

    func testBackgroundColourFillsTheCanvasWhenNobodyIsDetected() throws {
        // 没检测到人像时不能把人抹掉，只把整张图贴上去，空白处用底色
        let source = try makePlainImage(width: 400, height: 500, colour: FixtureFactory.Palette.red)
        let outcome = try IDPhotoProcessor.makeIDPhoto(
            from: source,
            size: .oneInch,
            background: .blue,
            dpi: 300,
            autoCrop: false,
            analyzer: FixedAnalyzer(mask: nil, face: nil)
        )

        XCTAssertFalse(outcome.replacedBackground, "没有遮罩就不算换过底色")
        let probe = try PixelProbe(outcome.image)
        let blue = PixelProbe.RGBA(r: 67, g: 142, b: 219, a: 255)
        // 4:5 的图放进 295:413（约 5:7）的画面：宽度先受限，所以是上下留白
        XCTAssertTrue(
            probe.pixel(x: outcome.image.width / 2, y: 4).isClose(to: blue, tolerance: 20),
            "顶部留白应是蓝底，实际 \(probe.pixel(x: outcome.image.width / 2, y: 4))"
        )
        XCTAssertTrue(
            probe.pixel(x: outcome.image.width / 2, y: outcome.image.height / 2)
                .isClose(to: .red, tolerance: 30),
            "中间应当还是原照片"
        )
    }

    // MARK: - 抠图合成

    func testCutoutKeepsTheSubjectAndFillsTheRestWithTheChosenColour() throws {
        // 左半边是「人」（遮罩为白），右半边是背景
        let source = try makePlainImage(width: 400, height: 500, colour: FixtureFactory.Palette.red)
        let mask = try makeMask(width: 400, height: 500) { x, _ in x < 200 ? 255 : 0 }

        let outcome = try IDPhotoProcessor.makeIDPhoto(
            from: source,
            size: .oneInch,
            background: .blue,
            dpi: 300,
            autoCrop: false,
            analyzer: FixedAnalyzer(mask: mask, face: nil)
        )

        XCTAssertTrue(outcome.replacedBackground)
        let probe = try PixelProbe(outcome.image)
        let blue = PixelProbe.RGBA(r: 67, g: 142, b: 219, a: 255)

        // 原图是 4:5，缩放到 295×413 的画面后约占 295×369，居中
        let drawnWidth = 295
        let subjectX = Int(Double(drawnWidth) * 0.25)  // 左半边偏中
        let backgroundX = Int(Double(drawnWidth) * 0.75)  // 右半边

        XCTAssertTrue(
            probe.pixel(x: subjectX, y: 200).isClose(to: .red, tolerance: 40),
            "遮罩范围内应当保留原照片，实际 \(probe.pixel(x: subjectX, y: 200))"
        )
        XCTAssertTrue(
            probe.pixel(x: backgroundX, y: 200).isClose(to: blue, tolerance: 20),
            "遮罩范围外应当是蓝底，实际 \(probe.pixel(x: backgroundX, y: 200))"
        )

        // 上下留白（画面比照片高）也应当是蓝底
        XCTAssertTrue(
            probe.pixel(x: 150, y: 5).isClose(to: blue, tolerance: 20),
            "底部留白应为蓝底，实际 \(probe.pixel(x: 150, y: 5))"
        )
    }

    func testEachBackgroundColourIsApplied() throws {
        let source = try makePlainImage(width: 200, height: 200, colour: FixtureFactory.Palette.red)
        let emptyMask = try makeMask(width: 200, height: 200) { _, _ in 0 }  // 全是背景

        let expectations: [(IDPhotoBackground, PixelProbe.RGBA)] = [
            (.white, .white),
            (.blue, PixelProbe.RGBA(r: 67, g: 142, b: 219, a: 255)),
            (.red, PixelProbe.RGBA(r: 255, g: 0, b: 0, a: 255)),
        ]

        for (background, expected) in expectations {
            let outcome = try IDPhotoProcessor.makeIDPhoto(
                from: source,
                size: .oneInch,
                background: background,
                dpi: 300,
                autoCrop: false,
                analyzer: FixedAnalyzer(mask: emptyMask, face: nil)
            )
            let probe = try PixelProbe(outcome.image)
            XCTAssertTrue(
                probe.pixel(x: 10, y: 10).isClose(to: expected, tolerance: 12),
                "\(background.displayName) 底色不对，实际 \(probe.pixel(x: 10, y: 10))"
            )
        }
    }

    func testKeepBackgroundDoesNotNeedAMask() throws {
        let source = try makePlainImage(width: 400, height: 500, colour: FixtureFactory.Palette.blue)
        let outcome = try IDPhotoProcessor.makeIDPhoto(
            from: source,
            size: .twoInch,
            background: .keep,
            dpi: 300,
            autoCrop: false,
            analyzer: FixedAnalyzer(mask: nil, face: nil)
        )

        XCTAssertFalse(outcome.replacedBackground)
        // 保留原背景时应当整张铺满，没有留白
        let probe = try PixelProbe(outcome.image)
        for point in [(5, 5), (outcome.image.width - 5, 5), (5, outcome.image.height - 5)] {
            XCTAssertTrue(
                probe.pixel(x: point.0, y: point.1).isClose(to: FixtureFactory.Palette.blueRGBA, tolerance: 30),
                "保留原背景时四角应当来自原图，实际 \(probe.pixel(x: point.0, y: point.1))"
            )
        }
    }

    // MARK: - 人脸构图

    func testFacePlacementPutsTheFaceWhereTheStandardWantsIt() throws {
        // 原图 1000×1000，人脸框归一化：中心 (0.5, 0.5)，宽 0.2 → 200px 宽
        let source = try makePlainImage(width: 1000, height: 1000)
        let face = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)

        let canvas = CGSize(width: 295, height: 413)
        let rect = IDPhotoProcessor.placement(
            imageSize: CGSize(width: 1000, height: 1000),
            faceBounds: face,
            canvas: canvas
        )

        // 人脸宽度应当是画面宽度的 55%
        let scale = rect.width / 1000
        let faceWidthInCanvas = 200 * scale
        XCTAssertEqual(faceWidthInCanvas, canvas.width * 0.55, accuracy: 1.0)

        // 人脸中心应当落在横向正中、纵向 44% 处（从顶部算）
        let faceCentreX = (0.4 + 0.1) * 1000 * scale + rect.minX
        let faceCentreY = (0.4 + 0.1) * 1000 * scale + rect.minY
        XCTAssertEqual(faceCentreX, canvas.width / 2, accuracy: 1.0)
        XCTAssertEqual(canvas.height - faceCentreY, canvas.height * 0.44, accuracy: 1.0)
    }

    func testWithoutFaceTheImageIsCentredInTheCanvas() throws {
        let rect = IDPhotoProcessor.placement(
            imageSize: CGSize(width: 400, height: 400),
            faceBounds: nil,
            canvas: CGSize(width: 295, height: 413)
        )
        // 正方形图放进竖版画面：上下留白，左右撑满
        XCTAssertEqual(rect.width, 295, accuracy: 0.5)
        XCTAssertEqual(rect.height, 295, accuracy: 0.5)
        XCTAssertEqual(rect.midX, 295 / 2, accuracy: 0.5)
        XCTAssertEqual(rect.midY, 413 / 2, accuracy: 0.5)
    }

    func testAutoCropReportsWhetherAFaceWasUsed() throws {
        let source = try makePlainImage(width: 600, height: 800)

        let withFace = try IDPhotoProcessor.makeIDPhoto(
            from: source, size: .oneInch, background: .keep, dpi: 300,
            autoCrop: true, analyzer: FixedAnalyzer(mask: nil, face: CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.2))
        )
        XCTAssertTrue(withFace.usedFace)

        let withoutFace = try IDPhotoProcessor.makeIDPhoto(
            from: source, size: .oneInch, background: .keep, dpi: 300,
            autoCrop: true, analyzer: FixedAnalyzer(mask: nil, face: nil)
        )
        XCTAssertFalse(withoutFace.usedFace, "没有人脸时要如实报告，界面会据此提示用户")
    }

    func testAutoCropDisabledIgnoresTheFace() throws {
        let source = try makePlainImage(width: 600, height: 800)
        let outcome = try IDPhotoProcessor.makeIDPhoto(
            from: source, size: .oneInch, background: .keep, dpi: 300,
            autoCrop: false, analyzer: FixedAnalyzer(mask: nil, face: CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.2))
        )
        XCTAssertFalse(outcome.usedFace, "关掉自动构图就不该去看人脸")
    }

    // MARK: - 工具

    private func makePlainImage(
        width: Int, height: Int,
        colour: (r: Double, g: Double, b: Double) = FixtureFactory.Palette.white
    ) throws -> CGImage {
        let context = try BitmapContext.make(width: width, height: height, wantsAlpha: false)
        context.setFillColor(FixtureFactory.color(colour))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    /// 造一张 DeviceGray、无 alpha 的遮罩 —— 必须是这个格式，`clip(to:mask:)` 才认。
    private func makeMask(width: Int, height: Int, value: (Int, Int) -> UInt8) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                bytes[y * width + x] = value(x, y)
            }
        }
        let data = Data(bytes)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(
            CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        )
    }
}

extension FixtureFactory.Palette {
    static var blueRGBA: PixelProbe.RGBA {
        PixelProbe.RGBA(
            r: Int(blue.r * 255), g: Int(blue.g * 255), b: Int(blue.b * 255), a: 255
        )
    }
}

/// 会话：反复调整参数时不该重复跑 Vision，而且结果必须与一次性调用一致。
final class IDPhotoSessionTests: XCTestCase {

    /// 记录分析被调用了多少次。
    private final class CountingAnalyzer: PersonMaskProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var maskCalls = 0
        private var faceCalls = 0

        let mask: CGImage?
        let face: CGRect?

        init(mask: CGImage?, face: CGRect?) {
            self.mask = mask
            self.face = face
        }

        var maskCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return maskCalls
        }

        var faceCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return faceCalls
        }

        func personMask(for image: CGImage) throws -> CGImage? {
            lock.lock()
            maskCalls += 1
            lock.unlock()
            return mask
        }

        func faceBounds(in image: CGImage) throws -> CGRect? {
            lock.lock()
            faceCalls += 1
            lock.unlock()
            return face
        }
    }

    private func makeSource(width: Int = 400, height: Int = 500) throws -> CGImage {
        let context = try BitmapContext.make(width: width, height: height, wantsAlpha: false)
        context.setFillColor(FixtureFactory.color(FixtureFactory.Palette.red))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeMask(width: Int = 400, height: Int = 500) throws -> CGImage {
        let data = Data([UInt8](repeating: 255, count: width * height))
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        )
    }

    func testAnalysisRunsOnceEvenWhenParametersChange() throws {
        let analyzer = CountingAnalyzer(mask: try makeMask(), face: CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.2))
        let session = IDPhotoSession(image: try makeSource(), analyzer: analyzer)

        // 模拟用户连续调整：换尺寸、换底色、开关构图
        _ = try session.render(size: .oneInch, background: .blue, dpi: 300, autoCrop: true)
        _ = try session.render(size: .twoInch, background: .white, dpi: 300, autoCrop: true)
        _ = try session.render(size: .oneInch, background: .red, dpi: 300, autoCrop: true)
        _ = try session.render(size: .usVisa, background: .blue, dpi: 600, autoCrop: true)

        XCTAssertEqual(analyzer.maskCallCount, 1, "遮罩只该算一次")
        XCTAssertEqual(analyzer.faceCallCount, 1, "人脸只该检测一次")
    }

    func testSessionResultMatchesOneShotAPI() throws {
        let source = try makeSource()
        let mask = try makeMask()
        let face = CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.2)

        let session = IDPhotoSession(image: source, analyzer: FixedAnalyzer(mask: mask, face: face))
        let viaSession = try session.render(size: .oneInch, background: .blue, dpi: 300, autoCrop: true)
        let oneShot = try IDPhotoProcessor.makeIDPhoto(
            from: source, size: .oneInch, background: .blue, dpi: 300,
            autoCrop: true, analyzer: FixedAnalyzer(mask: mask, face: face)
        )

        XCTAssertEqual(viaSession.image.width, oneShot.image.width)
        XCTAssertEqual(viaSession.image.height, oneShot.image.height)
        XCTAssertEqual(viaSession.replacedBackground, oneShot.replacedBackground)
        XCTAssertEqual(viaSession.usedFace, oneShot.usedFace)
        XCTAssertEqual(viaSession.notes, oneShot.notes)

        // 逐像素确认两条路径画出来的东西一样
        let a = try PixelProbe(viaSession.image)
        let b = try PixelProbe(oneShot.image)
        for point in [(10, 10), (a.width / 2, a.height / 2), (a.width - 10, a.height - 10)] {
            XCTAssertEqual(a.pixel(x: point.0, y: point.1), b.pixel(x: point.0, y: point.1))
        }
    }

    func testSessionCachesAMissingMaskToo() throws {
        // 没人像时也应当只算一次，别每次重试
        let analyzer = CountingAnalyzer(mask: nil, face: nil)
        let session = IDPhotoSession(image: try makeSource(), analyzer: analyzer)

        let first = try session.render(size: .oneInch, background: .blue, dpi: 300)
        let second = try session.render(size: .twoInch, background: .blue, dpi: 300)

        XCTAssertEqual(analyzer.maskCallCount, 1)
        XCTAssertFalse(first.replacedBackground)
        XCTAssertFalse(second.replacedBackground)
        XCTAssertTrue(first.notes.contains { $0.contains("person") || $0.contains("人像") })
    }

    func testMaskIsNotRequestedWhenTheBackgroundIsKept() throws {
        let analyzer = CountingAnalyzer(mask: try makeMask(), face: nil)
        let session = IDPhotoSession(image: try makeSource(), analyzer: analyzer)

        _ = try session.render(size: .oneInch, background: .keep, dpi: 300, autoCrop: false)
        XCTAssertEqual(analyzer.maskCallCount, 0, "保留原背景就不该去抠图")
    }

    func testSourceSizeIsReported() throws {
        let session = IDPhotoSession(
            image: try makeSource(width: 300, height: 400), analyzer: FixedAnalyzer(mask: nil, face: nil))
        XCTAssertEqual(session.sourceSize, CGSize(width: 300, height: 400))
    }
}

/// 「有遮罩但里面没有人」的处理。
///
/// 这一组直接对应一个真实故障：把一张普通照片当证件照转成 PDF，结果是**整页纯蓝、照片消失**。
/// 原因是 Vision 找不到人时仍然返回一张全黑遮罩，代码只判断「有没有遮罩」，
/// 于是把人像以外的一切都裁掉了。
final class EmptyPersonMaskTests: XCTestCase {

    private func makeSource(width: Int = 400, height: Int = 300) throws -> CGImage {
        let context = try BitmapContext.make(width: width, height: height, wantsAlpha: false)
        context.setFillColor(FixtureFactory.color(FixtureFactory.Palette.red))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeMask(width: Int = 400, height: Int = 300, value: (Int, Int) -> UInt8) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { bytes[y * width + x] = value(x, y) }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        )
    }

    // MARK: - 覆盖率判定

    func testCoverageOfAFullyBlackMaskIsZero() throws {
        let mask = try makeMask { _, _ in 0 }
        XCTAssertEqual(IDPhotoProcessor.coverage(of: mask), 0, accuracy: 0.001)
        XCTAssertNil(IDPhotoProcessor.usableMask(from: mask), "全黑遮罩应当被当成「没找到人」")
    }

    func testCoverageOfAFullyWhiteMaskIsOne() throws {
        let mask = try makeMask { _, _ in 255 }
        XCTAssertEqual(IDPhotoProcessor.coverage(of: mask), 1, accuracy: 0.01)
        XCTAssertNotNil(IDPhotoProcessor.usableMask(from: mask))
    }

    func testTinyStraySpecksAreNotAPerson() throws {
        // 只有左上角几个像素是白的：当成没人，别为了几个噪点把整张图裁掉
        let mask = try makeMask { x, y in (x < 3 && y < 3) ? 255 : 0 }
        XCTAssertLessThan(IDPhotoProcessor.coverage(of: mask), IDPhotoProcessor.minimumPersonCoverage)
        XCTAssertNil(IDPhotoProcessor.usableMask(from: mask))
    }

    func testNilMaskStaysNil() {
        XCTAssertNil(IDPhotoProcessor.usableMask(from: nil))
    }

    // MARK: - 空遮罩不能吃掉照片

    func testEmptyMaskKeepsThePhotoInsteadOfFillingWithTheBackground() throws {
        let emptyMask = try makeMask { _, _ in 0 }
        let outcome = try IDPhotoProcessor.makeIDPhoto(
            from: try makeSource(),
            size: .oneInch,
            background: .blue,
            dpi: 300,
            autoCrop: false,
            analyzer: FixedAnalyzer(mask: emptyMask, face: nil)
        )

        XCTAssertFalse(outcome.replacedBackground, "根本没抠出人来，不该声称换过底色")
        XCTAssertTrue(
            outcome.notes.contains { $0.contains("person") || $0.contains("人像") },
            "应当提示用户没检测到人像，实际提示：\(outcome.notes)"
        )

        // 画面中间必须还是原照片，而不是一片底色
        let probe = try PixelProbe(outcome.image)
        let centre = probe.pixel(x: outcome.image.width / 2, y: outcome.image.height / 2)
        XCTAssertTrue(centre.isClose(to: .red, tolerance: 40), "中间应当还是照片，实际 \(centre)")
    }

    func testEmptyMaskDoesNotLeaveTheWholePageInTheBackgroundColour() throws {
        // 这是「转 PDF 多了一层蓝色」的直接复现：整页都是底色就说明照片被裁没了
        let emptyMask = try makeMask { _, _ in 0 }
        let outcome = try IDPhotoProcessor.makeIDPhoto(
            from: try makeSource(),
            size: .oneInch,
            background: .blue,
            dpi: 300,
            autoCrop: false,
            analyzer: FixedAnalyzer(mask: emptyMask, face: nil)
        )

        let probe = try PixelProbe(outcome.image)
        var photoPixels = 0
        for y in stride(from: 0, to: outcome.image.height, by: 3) {
            for x in stride(from: 0, to: outcome.image.width, by: 3) {
                if probe.pixel(x: x, y: y).isClose(to: .red, tolerance: 45) { photoPixels += 1 }
            }
        }
        XCTAssertGreaterThan(photoPixels, 500, "照片应当大面积保留，实际只有 \(photoPixels) 个采样点是照片")
    }

    func testRealVisionRunWithNoPersonKeepsThePhoto() throws {
        // 真跑一次 Vision：这才是最初出问题的路径（注入的遮罩都「有内容」，测不到这一条）。
        // 用纯蓝图：Vision 对它返回全黑遮罩（实测前景 0%），
        // 而纯红会被误判成人像（前景 8.5%、置信度 250），不适合做这个断言。
        let context = try BitmapContext.make(width: 600, height: 400, wantsAlpha: false)
        context.setFillColor(FixtureFactory.color(FixtureFactory.Palette.blue))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        let source = try XCTUnwrap(context.makeImage())

        let outcome = try IDPhotoProcessor.makeIDPhoto(
            from: source,
            size: .oneInch,
            background: .red,
            dpi: 300,
            autoCrop: false
        )

        XCTAssertFalse(outcome.replacedBackground, "没有检测到人，不该声称换过底色")
        XCTAssertTrue(
            outcome.notes.contains { $0.contains("person") || $0.contains("人像") },
            "应当提示没检测到人像，实际：\(outcome.notes)"
        )

        let probe = try PixelProbe(outcome.image)
        let centre = probe.pixel(x: outcome.image.width / 2, y: outcome.image.height / 2)
        XCTAssertTrue(centre.isClose(to: .blue, tolerance: 45), "原图必须留下来，实际 \(centre)")
    }
}
