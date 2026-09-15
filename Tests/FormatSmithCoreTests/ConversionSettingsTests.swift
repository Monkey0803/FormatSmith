import XCTest
@testable import FormatSmithCore

final class ConversionSettingsTests: XCTestCase {

    // MARK: - 缩放换算

    func testEffectiveScaleFromDPI() {
        var settings = ConversionSettings()
        settings.resolutionMode = .dpi
        settings.dpi = 72
        XCTAssertEqual(settings.effectiveScale, 1.0, accuracy: 0.0001)

        settings.dpi = 144
        XCTAssertEqual(settings.effectiveScale, 2.0, accuracy: 0.0001)

        settings.dpi = 300
        XCTAssertEqual(settings.effectiveScale, 300.0 / 72.0, accuracy: 0.0001)
    }

    func testEffectiveScaleFromScaleMode() {
        var settings = ConversionSettings()
        settings.resolutionMode = .scale
        settings.scale = 3
        XCTAssertEqual(settings.effectiveScale, 3.0, accuracy: 0.0001)
    }

    func testEffectiveScaleIsClampedToAvoidZeroSizedOutput() {
        var settings = ConversionSettings()
        settings.resolutionMode = .dpi
        settings.dpi = 0
        XCTAssertGreaterThan(settings.effectiveScale, 0)
    }

    // MARK: - 页码

    func testPagesForAllMode() {
        var settings = ConversionSettings()
        settings.pageRangeMode = .all
        XCTAssertEqual(settings.pages(outOf: 3), [1, 2, 3])
        XCTAssertEqual(settings.pages(outOf: 0), [])
    }

    func testPagesForCustomMode() {
        var settings = ConversionSettings()
        settings.pageRangeMode = .custom
        settings.pageRangeText = "2-4"
        XCTAssertEqual(settings.pages(outOf: 10), [2, 3, 4])
    }

    func testCustomRangeIgnoredInAllMode() {
        var settings = ConversionSettings()
        settings.pageRangeMode = .all
        settings.pageRangeText = "99"
        XCTAssertEqual(settings.pages(outOf: 2), [1, 2])
    }

    // MARK: - 背景归一化

    func testTransparentBackgroundIsResetForOpaqueFormats() {
        var settings = ConversionSettings()
        settings.background = .transparent
        settings.format = .jpeg
        settings.normalizeForFormat()
        XCTAssertEqual(settings.background, .white)
    }

    func testTransparentBackgroundKeptForAlphaCapableFormats() {
        var settings = ConversionSettings()
        settings.background = .transparent
        settings.format = .png
        settings.normalizeForFormat()
        XCTAssertEqual(settings.background, .transparent)
    }

    func testBlackBackgroundSurvivesNormalization() {
        var settings = ConversionSettings()
        settings.background = .black
        settings.format = .jpeg
        settings.normalizeForFormat()
        XCTAssertEqual(settings.background, .black)
    }

    // MARK: - 输出目录

    func testOutputDirectoryDefaultsToDesktop() {
        let settings = ConversionSettings()
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        XCTAssertEqual(settings.resolvedOutputDirectory, desktop)
    }

    func testOutputDirectoryExpandsTilde() {
        var settings = ConversionSettings()
        settings.outputDirectoryPath = "~/Pictures/out"
        XCTAssertFalse(settings.resolvedOutputDirectory.path.contains("~"))
        XCTAssertTrue(settings.resolvedOutputDirectory.path.hasSuffix("/Pictures/out"))
    }

    // MARK: - 持久化

    func testCodableRoundTrip() throws {
        var original = ConversionSettings()
        original.format = .avif
        original.quality = 0.42
        original.resolutionMode = .scale
        original.scale = 3
        original.background = .transparent
        original.pageRangeMode = .custom
        original.pageRangeText = "1-3,7"
        original.outputDirectoryPath = "/tmp/out"
        original.perFileSubfolder = false
        original.filenamePattern = "{name}_{page}"
        original.padsPageNumbers = false
        original.openFolderWhenFinished = true

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConversionSettings.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testDecodingKeepsFormatIdentity() throws {
        var original = ConversionSettings()
        original.format = .heic
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConversionSettings.self, from: data)
        XCTAssertEqual(decoded.format, ImageFormat.heic)
        XCTAssertEqual(decoded.format.displayName, "HEIC")
        XCTAssertEqual(decoded.format.fileExtension, "heic")
    }

    func testImageFormatEncodesAsItsIdentifier() throws {
        let data = try JSONEncoder().encode(ImageFormat.png)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("public.png"), "格式应以其 UTType 标识符持久化，实际: \(text)")
    }
}
