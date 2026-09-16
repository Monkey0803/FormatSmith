import CoreGraphics
import Foundation
import XCTest
@testable import FormatSmithCore

/// 预设之间不能互相残留。
///
/// 真实反馈：先前用过证件照（蓝底），后来点「打印」预设、把图片转成 PDF，
/// 结果 PDF 是一块蓝色。原因是预设采用「打补丁」式应用，
/// 它没提到的 `idPhotoEnabled` / `idPhotoBackground` 原样留着，于是继续生效。
final class PresetIsolationTests: XCTestCase {

    private func preset(_ id: String) throws -> Preset {
        try XCTUnwrap(PresetLibrary.all.first { $0.id == id }, "找不到预设 \(id)")
    }

    // MARK: - 残留

    func testPrintPresetClearsAnEarlierIDPhotoMode() throws {
        var settings = ConversionSettings()
        try preset("idPhoto").apply(to: &settings)
        XCTAssertTrue(settings.idPhotoEnabled)
        XCTAssertEqual(settings.idPhotoBackground, .blue)

        try preset("print").apply(to: &settings)

        XCTAssertFalse(settings.idPhotoEnabled, "「打印」预设必须关掉证件照模式")
        XCTAssertFalse(settings.printSheetEnabled)
    }

    func testEveryPresetClearsEveryOtherPresetsSignature() throws {
        // 逐个验证：应用任何一个预设之后，其它预设独有的开关都不能还开着
        let idPhotoIDs = ["idPhoto", "photoSheet", "idScan"]

        for sourceID in PresetLibrary.all.map(\.id) {
            var settings = ConversionSettings()
            try preset(sourceID).apply(to: &settings)

            for targetID in PresetLibrary.all.map(\.id) where targetID != sourceID {
                var after = settings
                try preset(targetID).apply(to: &after)
                // 把「应用 target 的结果」与「以默认值为底应用 target」对比，两者必须一致
                var fromScratch = ConversionSettings()
                try preset(targetID).apply(to: &fromScratch)
                XCTAssertEqual(
                    after, fromScratch,
                    "先应用 \(sourceID) 再应用 \(targetID)，结果应当与直接应用 \(targetID) 完全相同"
                )
            }
            _ = idPhotoIDs
        }
    }

    func testApplyingAPresetTwiceChangesNothing() throws {
        for id in PresetLibrary.all.map(\.id) {
            var settings = ConversionSettings()
            try preset(id).apply(to: &settings)
            let once = settings

            try preset(id).apply(to: &settings)
            XCTAssertEqual(settings, once, "重复应用同一个预设应当得到相同结果（\(id)）")
        }
    }

    // MARK: - 该保留的个人偏好

    func testOutputPreferencesSurviveAPreset() throws {
        var settings = ConversionSettings()
        settings.outputDirectoryPath = "/tmp/somewhere"
        settings.filenamePattern = "{name}-custom"
        settings.perFileSubfolder = false
        settings.padsPageNumbers = false
        settings.openFolderWhenFinished = true
        settings.maxConcurrentFiles = 3
        settings.maxPixels = 40_000_000

        let applied = try preset("web").applied(to: settings)

        XCTAssertEqual(applied.outputDirectoryPath, "/tmp/somewhere", "输出位置不该被预设改掉")
        XCTAssertEqual(applied.filenamePattern, "{name}-custom", "命名规则不该被预设改掉")
        XCTAssertFalse(applied.perFileSubfolder)
        XCTAssertFalse(applied.padsPageNumbers)
        XCTAssertTrue(applied.openFolderWhenFinished)
        XCTAssertEqual(applied.maxConcurrentFiles, 3)
        XCTAssertEqual(applied.maxPixels, 40_000_000)
    }

    func testPresetStillSetsWhatItDeclares() throws {
        let applied = try preset("print").applied(to: ConversionSettings())
        XCTAssertEqual(applied.target, .image(.tiff))
        XCTAssertEqual(applied.dpi, 300)
        XCTAssertEqual(applied.scale, 1)
    }

    // MARK: - 用户实际遇到的那条路

    func testIDPhotoThenPrintThenPDFProducesNoBlueOverlay() throws {
        let directory = try FixtureFactory.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 一张纯色照片，用白色以外的颜色以便分辨「照片」和「证件照蓝底」
        let photo = try FixtureFactory.makeSilhouette(
            width: 800, height: 600, colour: (r: 0.15, g: 0.6, b: 0.25), named: "photo", in: directory
        )

        var settings = ConversionSettings()
        try preset("idPhoto").apply(to: &settings)  // 蓝底证件照
        try preset("print").apply(to: &settings)  // 再点「打印」
        settings.target = .pdf  // 用户把输出改成 PDF
        settings.pdfPageSize = .a4
        settings.outputDirectoryPath = directory.path
        settings.perFileSubfolder = false
        settings.filenamePattern = "result"

        let result = ConversionEngine.convert(
            document: SourceDocument.make(from: photo),
            target: .pdf,
            settings: settings,
            cancellation: CancellationFlag()
        )
        XCTAssertNil(result.error)

        let document = try XCTUnwrap(PDFRasterizer.open(try XCTUnwrap(result.outputFiles.first)))
        let page = try XCTUnwrap(document.page(at: 1))
        let rendered = try PDFRasterizer.render(
            page: page, scale: 1, background: .white, keepsAlpha: false, maxPixels: 40_000_000
        )
        let probe = try PixelProbe(rendered)

        // 页面中间应当是照片本身（绿），而不是证件照的蓝底
        let centre = probe.pixel(x: rendered.width / 2, y: rendered.height / 2)
        let expected = PixelProbe.RGBA(r: 38, g: 153, b: 64, a: 255)
        XCTAssertTrue(centre.isClose(to: expected, tolerance: 45), "中间应当是照片本身，实际 \(centre)")

        // 整页都不该出现那块蓝
        let idPhotoBlue = PixelProbe.RGBA(r: 67, g: 142, b: 219, a: 255)
        var blueSamples = 0
        for y in stride(from: 0, to: rendered.height, by: 7) {
            for x in stride(from: 0, to: rendered.width, by: 7) {
                if probe.pixel(x: x, y: y).isClose(to: idPhotoBlue, tolerance: 18) { blueSamples += 1 }
            }
        }
        XCTAssertEqual(blueSamples, 0, "页面上不该出现证件照蓝底")
    }
}
