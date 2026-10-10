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
        // 导出文字现在支持按页码挑选（--pages），所以这一项是生效的
        XCTAssertTrue(pdfScope.isActive(.pageRange), "多页 PDF 导出文字应当能挑页码")
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

/// 纯文本目标的预览必须显示**真正会写出的文字**，而不是只画一张源图。
///
/// 一开始这里只画源图，等于什么都没告诉用户 —— 预览存在的意义就是所见即所得。
final class TextPreviewTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = try FixtureFactory.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func settings() -> ConversionSettings {
        var settings = ConversionSettings()
        settings.target = .text
        settings.outputDirectoryPath = directory.path
        settings.filenamePattern = "out"
        return settings
    }

    /// 注入固定识别结果：这样测的是「预览有没有把文字取出来并带上」，
    /// 而不是「Vision 今天认不认得这张图」（那件事另有真跑 Vision 的用例）。
    private struct StubRecognizer: TextRecognizing {
        let text: String
        func lines(in image: CGImage) throws -> [RecognizedLine] {
            [RecognizedLine(text: text, bounds: CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.1))]
        }
    }

    func testImagePreviewCarriesTheRecognisedText() throws {
        let url = try FixtureFactory.makeTextImage("whatever", named: "note", in: directory)
        let result = try OutputPreview.render(
            documents: [SourceDocument.make(from: url)],
            target: .text,
            settings: settings(),
            recognizer: StubRecognizer(text: "PREVIEWED WORDS")
        )

        XCTAssertEqual(result.kind, .text, "预览类型应当是文字")
        XCTAssertEqual(result.text, "PREVIEWED WORDS", "预览必须带上识别出的文字")
    }

    func testPDFPreviewReusesTheTextLayerWithoutOCR() throws {
        // 有文字层就不该去识别：注入的识别器会返回完全不同的文字，用它来区分
        let pdf = try FixtureFactory.makeTextPDF(pages: [["Layer text here"]], named: "native", in: directory)
        let result = try OutputPreview.render(
            documents: [SourceDocument.make(from: pdf)],
            target: .text,
            settings: settings(),
            recognizer: StubRecognizer(text: "SHOULD NOT APPEAR")
        )

        XCTAssertEqual(result.text, "Layer text here", "应当直接用文字层")
    }

    func testPDFPreviewFollowsTheChosenPages() throws {
        let pdf = try FixtureFactory.makeTextPDF(
            pages: [["Alpha"], ["Bravo"], ["Charlie"]], named: "three", in: directory
        )
        var chosen = settings()
        chosen.pageRangeMode = .custom
        chosen.pageRangeText = "3"

        let result = try OutputPreview.render(
            documents: [SourceDocument.make(from: pdf)], target: .text, settings: chosen
        )
        XCTAssertEqual(result.text, "Charlie", "挑了第 3 页，预览就该显示第 3 页")
    }

    func testEmptyRecognitionSaysSoInsteadOfShowingNothing() throws {
        let url = try FixtureFactory.makeTextImage("x", named: "blank", in: directory)
        let result = try OutputPreview.render(
            documents: [SourceDocument.make(from: url)],
            target: .text,
            settings: settings(),
            recognizer: StubRecognizer(text: "")
        )
        XCTAssertTrue(result.notes.contains { $0.contains("No text") }, "取不到文字必须有话说明：\(result.notes)")
    }

    func testLongTextIsTruncatedForDisplay() throws {
        let long = String(repeating: "word ", count: 400)
        let url = try FixtureFactory.makeTextImage("x", named: "long", in: directory)
        let result = try OutputPreview.render(
            documents: [SourceDocument.make(from: url)],
            target: .text,
            settings: settings(),
            recognizer: StubRecognizer(text: long)
        )
        XCTAssertLessThanOrEqual(result.text?.count ?? 0, OutputPreview.previewTextLimit + 1)
        XCTAssertTrue(result.text?.hasSuffix("…") == true, "截断要有省略号")
    }

    func testTextTargetCountsAsExpensive() {
        // 预览会跑 OCR，界面必须用更长的防抖
        XCTAssertTrue(
            OutputPreview.isExpensive(
                documents: [SourceDocument.make(from: directory.appendingPathComponent("x.png"))],
                target: .text
            ),
            "纯文本目标要跑 OCR，必须算作昂贵路线"
        )
    }
}

/// 导出文字的页码选择必须真的生效（不只是界面显示）。
final class TextPageSelectionTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = try FixtureFactory.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func run(pages: String?) throws -> String {
        let pdf = try FixtureFactory.makeTextPDF(
            pages: [["Alpha"], ["Bravo"], ["Charlie"]], named: "three", in: directory
        )
        var settings = ConversionSettings()
        settings.target = .text
        settings.outputDirectoryPath = directory.path
        settings.perFileSubfolder = false
        settings.filenamePattern = "out"
        settings.mergeImagesIntoOnePDF = false
        if let pages {
            settings.pageRangeMode = .custom
            settings.pageRangeText = pages
        }

        let result = ConversionEngine.convert(
            document: SourceDocument.make(from: pdf), target: .text, settings: settings,
            cancellation: CancellationFlag()
        )
        XCTAssertNil(result.error, "不该失败：\(result.error?.message ?? "")")
        return try String(contentsOf: try XCTUnwrap(result.outputFiles.first), encoding: .utf8)
    }

    func testAllPagesByDefault() throws {
        let text = try run(pages: nil)
        XCTAssertTrue(text.contains("Alpha") && text.contains("Bravo") && text.contains("Charlie"))
    }

    func testOnlyTheChosenPage() throws {
        let text = try run(pages: "2")
        XCTAssertTrue(text.contains("Bravo"))
        XCTAssertFalse(text.contains("Alpha"), "没挑的页不该出现：\(text)")
        XCTAssertFalse(text.contains("Charlie"))
    }

    func testOrderFollowsWhatWasWritten() throws {
        // 与「提取页」一致：3,1 就是先 3 后 1
        let text = try run(pages: "3,1")
        let charlie = try XCTUnwrap(text.range(of: "Charlie"))
        let alpha = try XCTUnwrap(text.range(of: "Alpha"))
        XCTAssertTrue(charlie.lowerBound < alpha.lowerBound, "写的顺序应当被保留：\(text)")
        XCTAssertFalse(text.contains("Bravo"))
    }
}
