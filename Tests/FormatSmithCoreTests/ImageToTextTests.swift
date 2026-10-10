import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import XCTest
@testable import FormatSmithCore

/// 图片 → 纯文本。
///
/// 之前只有 PDF 能出文字（工具箱里的「导出纯文本」）。拍照、截图这些图片输入
/// 要出文字，得先转成 PDF 再抽——绕一圈而且多一次有损栅格化。
/// 现在图片有直接的通路：识别一次，写成 .txt。
final class ImageToTextTests: XCTestCase {

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

    private func settings() -> ConversionSettings {
        var settings = ConversionSettings()
        settings.target = .text
        settings.outputDirectoryPath = output.path
        settings.perFileSubfolder = false
        settings.filenamePattern = "out"
        return settings
    }

    /// 真的跑一遍引擎，而不是只调底层函数。
    private func run(_ document: SourceDocument) -> ConversionResult {
        ConversionEngine.convert(
            document: document, target: .text, settings: settings(), cancellation: CancellationFlag()
        )
    }

    private func text(of result: ConversionResult) throws -> String {
        XCTAssertNil(result.error, "不该失败：\(result.error?.message ?? "")")
        let url = try XCTUnwrap(result.outputFiles.first)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 图片

    func testImageBecomesText() throws {
        // 造一张「拍下来的纸」：白底黑字
        let url = try FixtureFactory.makeTextImage("Receipt 2024-0315", named: "photo", in: directory)

        let result = run(SourceDocument.make(from: url))
        let text = try text(of: result)

        XCTAssertTrue(text.contains("2024-0315"), "应当识别出发票号，实际：\(text)")
    }

    func testOutputIsATxtFileNamedByThePattern() throws {
        let url = try FixtureFactory.makeTextImage("Plain text here", named: "note", in: directory)
        let result = run(SourceDocument.make(from: url))

        let outputFile = try XCTUnwrap(result.outputFiles.first)
        XCTAssertEqual(outputFile.pathExtension, "txt")
        XCTAssertEqual(outputFile.lastPathComponent, "out.txt")
        XCTAssertEqual(result.producedCount, 1)
    }

    func testImageWithoutTextStillProducesAFileAndSaysSo() throws {
        // 画面里没有字：不该算失败，但必须讲清楚
        let context = try BitmapContext.make(width: 400, height: 300, wantsAlpha: false)
        context.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let url = directory.appendingPathComponent("plain.png")
        try ImageEncoder.encode(try XCTUnwrap(context.makeImage()), format: .png, quality: 1)
            .write(to: url)

        let result = run(SourceDocument.make(from: url))

        XCTAssertNil(result.error)
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(result.outputFiles.first), encoding: .utf8), "\n")
        XCTAssertTrue(
            result.notes.contains { $0.contains("No text") },
            "没认出字必须有话说明，实际说明：\(result.notes)"
        )
    }

    func testAnimationUsesTheFirstFrame() throws {
        // 动图取第一帧，与本项目其它地方对动图的处理一致
        let url = try FixtureFactory.makeTextImage("First frame words", named: "frame", in: directory)
        let result = run(SourceDocument.make(from: url))
        XCTAssertTrue(try text(of: result).contains("First"))
    }

    // MARK: - PDF 也走同一个目标

    func testPDFBecomesTextThroughTheSameTarget() throws {
        // 有文字层的 PDF：不该去 OCR
        let pdf = try FixtureFactory.makeTextPDF(pages: [["Native paragraph"]], named: "native", in: directory)

        let result = run(SourceDocument.make(from: pdf))
        XCTAssertTrue(try text(of: result).contains("Native paragraph"))
        XCTAssertTrue(result.notes.isEmpty, "有文字层就不该报告「识别了几页」，实际：\(result.notes)")
    }

    func testScannedPDFIsRecognisedAndReported() throws {
        let image = try FixtureFactory.makeTextImage("Scanned 88", named: "scan", in: directory)
        let cgImage = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(
                try XCTUnwrap(CGImageSourceCreateWithURL(image as CFURL, nil)), 0, nil
            )
        )
        let pdf = try PDFComposer.compose(
            images: [cgImage],
            settings: ConversionSettings(),
            to: directory.appendingPathComponent("scan.pdf")
        )

        let result = run(SourceDocument.make(from: pdf))
        XCTAssertTrue(try text(of: result).contains("88"))
        XCTAssertTrue(
            result.notes.contains { $0.contains("recognised") },
            "扫描页应当如实报告做了识别，实际：\(result.notes)"
        )
    }

    // MARK: - 路由与设置生效

    func testRoutingSaysReadyForImagesAndPDFs() {
        XCTAssertTrue(ConversionRouter.plan(input: .image(identifier: "public.png"), target: .text).isReady)
        XCTAssertTrue(ConversionRouter.plan(input: .pdf, target: .text).isReady)
        XCTAssertEqual(ConversionRouter.plan(input: .pdf, target: .text).kind, .toText)
        XCTAssertEqual(ConversionRouter.plan(input: .image(identifier: "public.png"), target: .text).kind, .toText)
    }

    func testDocumentsExplainTheyNeedToGoThroughPDF() {
        let plan = ConversionRouter.plan(input: .plainText, target: .text)
        XCTAssertFalse(plan.isReady)
        XCTAssertEqual(plan.kind, .documentToPDF)
        XCTAssertTrue(
            plan.unavailableReason?.contains("PDF") == true,
            "应当说清楚先转 PDF，实际：\(plan.unavailableReason ?? "无")"
        )
    }

    /// 纯文本目标下，绝大多数设置本就不该生效——否则用户改了半天却毫无变化。
    func testOnlyRelevantSettingsAreActiveForText() {
        let imageScope = SettingsScope(documentKinds: [.image(identifier: "public.png")], target: .text)
        XCTAssertFalse(imageScope.isActive(.quality), "产出是文字，压缩质量无从谈起")
        XCTAssertFalse(imageScope.isActive(.background))
        XCTAssertFalse(imageScope.isActive(.maxLongEdge))
        XCTAssertFalse(imageScope.isActive(.metadata))
        XCTAssertFalse(imageScope.isActive(.idPhoto))
        XCTAssertFalse(imageScope.isActive(.resolution), "图片是按原像素识别的，DPI 不参与")

        let pdfScope = SettingsScope(
            documentKinds: [.pdf], pageCounts: [3], target: .text,
            settings: ConversionSettings()
        )
        XCTAssertTrue(pdfScope.isActive(.resolution), "PDF 要先栅格化，DPI 影响识别质量")
        XCTAssertFalse(pdfScope.isActive(.pageRange), "导出文字处理整份文件，不按页码挑")
        XCTAssertFalse(pdfScope.isActive(.pdfTool), "走的是新目标，不是工具箱")
    }

    func testTargetRoundTripsThroughSettingsPersistence() throws {
        var settings = ConversionSettings()
        settings.target = .text
        XCTAssertTrue(settings.producesText)
        XCTAssertEqual(settings.target, .text)

        // 存了再读回来还得是文字
        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(ConversionSettings.self, from: data)
        XCTAssertEqual(restored.target, .text)

        // 切回图片目标时不能还留着文字标志
        settings.target = .image(.jpeg)
        XCTAssertFalse(settings.producesText)
        XCTAssertEqual(settings.target, .image(.jpeg))
    }

    func testOldSavedSettingsWithoutTheTextKeyStillDecode() throws {
        // 老版本存下来的 JSON 里没有 producesText 这个键。
        // 不去手写 JSON（猜格式容易猜错），而是拿真实编码结果删掉这个键 ——
        // 这正是升级后第一次启动时磁盘上那份文件的样子。
        var settings = ConversionSettings()
        settings.target = .image(.jpeg)

        let data = try JSONEncoder().encode(settings)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(object["producesText"], "前提：新版本确实会写出这个键")
        object.removeValue(forKey: "producesText")

        let legacy = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(ConversionSettings.self, from: legacy)

        XCTAssertFalse(restored.producesText, "缺这个键时应当是「不是文字目标」")
        XCTAssertEqual(restored.target, .image(.jpeg), "老设置的图片格式必须原样恢复")
    }
}
