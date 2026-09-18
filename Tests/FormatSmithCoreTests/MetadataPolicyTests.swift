import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import FormatSmithCore

/// 元数据保留策略。
///
/// 起因是实测发现：源图带着相机型号、拍摄时间、GPS，转换后**全都没了**——
/// 而用户有时想留着这些信息，有时又不想把位置带出去，哪一种都不该由工具悄悄决定。
final class MetadataPolicyTests: XCTestCase {

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
        policy: MetadataPolicy,
        scale: Double = 1
    ) throws -> URL {
        var settings = ConversionSettings()
        settings.target = .image(.jpeg)
        settings.metadataPolicy = policy
        settings.scale = scale
        settings.outputDirectoryPath = output.path
        settings.perFileSubfolder = false
        settings.filenamePattern = "out"

        let result = ConversionEngine.convert(
            document: SourceDocument.make(from: url),
            target: settings.target,
            settings: settings,
            cancellation: CancellationFlag()
        )
        XCTAssertNil(result.error)
        return try XCTUnwrap(result.outputFiles.first)
    }

    /// 用 ImageIO 读，这是权威读法（`sips` 对这几个字段并不可靠）。
    private func properties(_ url: URL) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    private func model(_ props: [String: Any]) -> String? {
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        return tiff[kCGImagePropertyTIFFModel as String] as? String
    }

    private func captured(_ props: [String: Any]) -> String? {
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        return exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
    }

    private func hasLocation(_ props: [String: Any]) -> Bool {
        let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        return !gps.isEmpty
    }

    // MARK: - 三种策略

    func testKeepCarriesCameraTimeAndLocation() throws {
        let source = try FixtureFactory.makeTaggedImage(named: "tagged", in: directory)
        let props = try properties(try convert(source, policy: .keep))

        XCTAssertEqual(model(props), "iPhone 15 Pro")
        XCTAssertEqual(captured(props), "2024:03:15 10:30:00")
        XCTAssertTrue(hasLocation(props), "默认应当保留 GPS")
    }

    func testStripLocationKeepsCameraButDropsGPS() throws {
        let source = try FixtureFactory.makeTaggedImage(named: "tagged", in: directory)
        let props = try properties(try convert(source, policy: .stripLocation))

        XCTAssertEqual(model(props), "iPhone 15 Pro", "只去位置，相机信息要留着")
        XCTAssertEqual(captured(props), "2024:03:15 10:30:00")
        XCTAssertFalse(hasLocation(props), "GPS 必须去掉")
    }

    func testStripAllWritesNothing() throws {
        let source = try FixtureFactory.makeTaggedImage(named: "tagged", in: directory)
        let props = try properties(try convert(source, policy: .stripAll))

        XCTAssertNil(model(props))
        XCTAssertNil(captured(props))
        XCTAssertFalse(hasLocation(props))
    }

    // MARK: - 两个必须清掉的字段

    func testRotatedSourceIsNotRotatedTwice() throws {
        // 解码时已经按 EXIF 方向把像素摆正了。如果再把 orientation 写回去，
        // 看图软件会在已经转正的图上再转 90°，照片直接躺倒。
        let source = try FixtureFactory.makeTaggedImage(
            width: 800, height: 600, orientation: 6, named: "rotated", in: directory
        )

        let url = try convert(source, policy: .keep)
        let props = try properties(url)

        let width = props[kCGImagePropertyPixelWidth as String] as? Int
        let height = props[kCGImagePropertyPixelHeight as String] as? Int
        XCTAssertEqual(width, 600, "orientation 6 表示要转 90°，像素应当已经转正")
        XCTAssertEqual(height, 800)

        let orientation = props[kCGImagePropertyOrientation as String] as? Int ?? 1
        XCTAssertEqual(orientation, 1, "方向已经应用过了，不能再写回 6")

        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        XCTAssertNil(tiff[kCGImagePropertyTIFFOrientation as String], "TIFF 里的方向也要清掉")
    }

    func testScaledOutputDoesNotClaimTheOriginalPixelDimensions() throws {
        let source = try FixtureFactory.makeTaggedImage(width: 800, height: 600, named: "big", in: directory)
        let url = try convert(source, policy: .keep, scale: 0.5)
        let props = try properties(url)

        let width = props[kCGImagePropertyPixelWidth as String] as? Int
        XCTAssertEqual(width, 400, "缩放后报出的尺寸要与实际一致")

        // EXIF 里的像素尺寸也不能留着旧值
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        if let exifWidth = exif[kCGImagePropertyExifPixelXDimension as String] as? Int {
            XCTAssertEqual(exifWidth, 400, "EXIF 的像素尺寸不能是缩放宽之前的旧值")
        }
    }

    // MARK: - 生效范围

    func testMetadataPolicyIsInactiveForPDFOutput() {
        let image = InputKind.image(identifier: "public.png")
        var settings = ConversionSettings()
        settings.target = .pdf

        let scope = SettingsScope(
            documentKinds: [image], pageCounts: [1], target: .pdf, settings: settings
        )
        XCTAssertFalse(scope.isActive(.metadata), "PDF 输出不走图片元数据这条路")

        let imageTarget = SettingsScope(
            documentKinds: [image], pageCounts: [1], target: .image(.jpeg), settings: settings
        )
        XCTAssertTrue(imageTarget.isActive(.metadata))
    }

    func testChangingThePolicyIsTheOnlyThingThatMovesTheMetadata() throws {
        // 同一次转换只改策略，元数据的有无必须只跟着策略变
        let source = try FixtureFactory.makeTaggedImage(named: "tagged", in: directory)

        let kept = try properties(try convert(source, policy: .keep))
        let stripped = try properties(try convert(source, policy: .stripAll))

        XCTAssertNotNil(model(kept))
        XCTAssertNil(model(stripped))
    }
}
