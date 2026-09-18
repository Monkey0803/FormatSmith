import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import FormatSmithCore

/// 动图处理。
///
/// 起因是实测发现：3 帧的 GIF 转出来只有 1 帧，而且**没有任何提示**。
/// 转 GIF 的人通常就是想保留动画，静默压成一张图是丢数据。
final class AnimationTests: XCTestCase {

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

    private func convert(
        _ url: URL,
        format: ImageFormat,
        configure: (inout ConversionSettings) -> Void = { _ in }
    ) throws -> ConversionResult {
        var settings = ConversionSettings()
        settings.target = .image(format)
        settings.outputDirectoryPath = output.path
        settings.perFileSubfolder = false
        settings.filenamePattern = "out"
        configure(&settings)

        let result = ConversionEngine.convert(
            document: SourceDocument.make(from: url),
            target: settings.target,
            settings: settings,
            cancellation: CancellationFlag()
        )
        XCTAssertNil(result.error, "转换失败：\(result.error?.message ?? "")")
        return result
    }

    private func frameCount(of url: URL) throws -> Int {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return CGImageSourceGetCount(source)
    }

    // MARK: - 保留动画

    func testGIFToGIFKeepsEveryFrame() throws {
        let source = try FixtureFactory.makeAnimatedGIF(frames: 4, named: "anim", in: directory)
        XCTAssertEqual(try frameCount(of: source), 4, "素材本身要是 4 帧")

        let result = try convert(source, format: .gif)
        let written = try XCTUnwrap(result.outputFiles.first)
        XCTAssertEqual(try frameCount(of: written), 4, "GIF → GIF 应当保留动画")
        XCTAssertTrue(result.notes.isEmpty, "保留成功时不该有任何提示")
    }

    func testKeptAnimationCarriesFrameDelays() throws {
        let source = try FixtureFactory.makeAnimatedGIF(frames: 3, delay: 0.35, named: "anim", in: directory)
        let result = try convert(source, format: .gif)
        let written = try XCTUnwrap(result.outputFiles.first)

        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))
        let props = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]
        )
        let gif = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] ?? [:]
        let delay = gif[kCGImagePropertyGIFDelayTime as String] as? Double
        XCTAssertEqual(delay ?? 0, 0.35, accuracy: 0.01, "帧间隔要跟着走，否则动画节奏会变")
    }

    // MARK: - 无法保留时必须说清楚

    func testGIFToStillImageWarnsAboutTheFirstFrameOnly() throws {
        let source = try FixtureFactory.makeAnimatedGIF(frames: 3, named: "anim", in: directory)
        let result = try convert(source, format: .png)

        XCTAssertEqual(try frameCount(of: try XCTUnwrap(result.outputFiles.first)), 1)
        XCTAssertTrue(
            result.notes.contains { $0.contains("first frame") },
            "静默丢帧是这次要修的问题；必须给出提示，实际：\(result.notes)"
        )
    }

    func testResizedGIFAlsoWarns() throws {
        // 改了尺寸就没法原样搬运帧，只能取首帧 —— 同样要提示
        let source = try FixtureFactory.makeAnimatedGIF(frames: 3, named: "anim", in: directory)
        let result = try convert(source, format: .gif) { $0.scale = 0.5 }

        XCTAssertTrue(
            result.notes.contains { $0.contains("first frame") },
            "缩放后的动图只取首帧，必须提示，实际：\(result.notes)"
        )
    }

    func testCappingTheLongestEdgeAlsoWarns() throws {
        let source = try FixtureFactory.makeAnimatedGIF(frames: 3, named: "anim", in: directory)
        let result = try convert(source, format: .gif) { $0.maxLongEdge = 32 }

        XCTAssertTrue(result.notes.contains { $0.contains("first frame") })
    }

    // MARK: - 静态图不该有提示

    func testStaticImageGetsNoAnimationNote() throws {
        let source = try FixtureFactory.makeImage(width: 200, height: 150, named: "still", in: directory)
        let result = try convert(source, format: .png)
        XCTAssertTrue(result.notes.isEmpty, "单帧图不该提示动画相关的事")
    }

    func testSingleFrameGIFGetsNoNote() throws {
        let source = try FixtureFactory.makeAnimatedGIF(frames: 1, named: "one", in: directory)
        let result = try convert(source, format: .png)
        XCTAssertTrue(result.notes.isEmpty, "只有一帧的 GIF 不是动图")
    }

    // MARK: - 直接调用编码器

    func testWriteAnimatedRejectsASingleFrameSource() throws {
        let source = try FixtureFactory.makeImage(width: 100, height: 80, named: "still", in: directory)
        XCTAssertThrowsError(
            try ImageEncoder.writeAnimated(
                from: source, format: .gif, to: output.appendingPathComponent("x.gif")
            )
        )
    }
}
