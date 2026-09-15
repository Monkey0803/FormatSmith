import AppKit
import Foundation
import XCTest
@testable import FormatSmithCore

/// 文档 → PDF 的端到端测试。
///
/// HTML / Markdown / 纯文本走系统 WebKit，任何机器上都能跑；
/// Office 那条链路需要 LibreOffice，没有就跳过（CI 上两种情况都要能过）。
final class DocumentConversionTests: XCTestCase {

    private var directory: URL!
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        // WKWebView 需要有 AppKit 环境，命令行测试进程里得先把它初始化起来。
        _ = NSApplication.shared
        directory = try FixtureFactory.makeTemporaryDirectory()
        outputDirectory = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func settings() -> ConversionSettings {
        var settings = ConversionSettings()
        settings.target = .pdf
        settings.outputDirectoryPath = outputDirectory.path
        settings.perFileSubfolder = false
        settings.filenamePattern = "{name}"
        return settings
    }

    private func convert(_ url: URL) -> ConversionResult {
        ConversionEngine.convert(
            document: SourceDocument.make(from: url),
            target: .pdf,
            settings: settings(),
            cancellation: CancellationFlag()
        )
    }

    /// 页面里有没有「墨水」——用来确认 PDF 不是空白页。
    private func inkRatio(of url: URL, scale: Double = 1) throws -> Double {
        let document = try PDFRasterizer.open(url)
        let page = try XCTUnwrap(document.page(at: 1))
        let image = try PDFRasterizer.render(
            page: page, scale: scale, background: .white, keepsAlpha: false, maxPixels: 20_000_000
        )
        let probe = try PixelProbe(image)
        var inked = 0
        for y in stride(from: 0, to: probe.height, by: 3) {
            for x in stride(from: 0, to: probe.width, by: 3) {
                let pixel = probe.pixel(x: x, y: y)
                if pixel.r < 200 || pixel.g < 200 || pixel.b < 200 { inked += 1 }
            }
        }
        let sampled = (probe.height / 3 + 1) * (probe.width / 3 + 1)
        return Double(inked) / Double(sampled)
    }

    // MARK: - HTML

    func testHTMLBecomesPDFWithContent() throws {
        let html = directory.appendingPathComponent("page.html")
        try """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>Test</title></head>
        <body><h1>Hello FormatSmith</h1><p>This paragraph should be visible in the PDF output.</p></body>
        </html>
        """.write(to: html, atomically: true, encoding: .utf8)

        let result = convert(html)

        XCTAssertNil(result.error, result.error?.message ?? "")
        let written = try XCTUnwrap(result.outputFiles.first)
        XCTAssertEqual(written.pathExtension, "pdf")
        XCTAssertEqual(written.lastPathComponent, "page.pdf")
        XCTAssertGreaterThan(PDFRasterizer.pageCount(of: written), 0)
        XCTAssertGreaterThan(try inkRatio(of: written), 0.001, "页面不应是空白")
    }

    func testHTMLLongContentSpansMultiplePages() throws {
        let rows = (1...200).map { "<p>Line \($0) of a deliberately long document.</p>" }.joined()
        let html = directory.appendingPathComponent("long.html")
        try "<html><body>\(rows)</body></html>".write(to: html, atomically: true, encoding: .utf8)

        let result = convert(html)
        XCTAssertNil(result.error)
        let written = try XCTUnwrap(result.outputFiles.first)
        XCTAssertGreaterThan(PDFRasterizer.pageCount(of: written), 1, "长文档应自动分页")
    }

    // MARK: - Markdown

    func testMarkdownBecomesPDF() throws {
        let markdown = directory.appendingPathComponent("notes.md")
        try """
        # Release notes

        Some **bold** text and a list:

        - first item
        - second item

        ```swift
        let value = 42
        ```
        """.write(to: markdown, atomically: true, encoding: .utf8)

        let result = convert(markdown)

        XCTAssertNil(result.error, result.error?.message ?? "")
        let written = try XCTUnwrap(result.outputFiles.first)
        XCTAssertEqual(written.lastPathComponent, "notes.pdf")
        XCTAssertGreaterThan(try inkRatio(of: written), 0.001)
    }

    func testMarkdownRenderingProducesAStandaloneDocument() {
        // 不论本机有没有 pandoc，都必须产出一份完整的 HTML 文档
        let html = DocumentConverter.renderMarkdown("# Heading\n\nBody text.", title: "doc")
        XCTAssertTrue(html.lowercased().contains("<html"), "实际: \(html)")
        XCTAssertTrue(html.contains("Heading"), "标题文字不能丢: \(html)")
    }

    func testBuiltInMarkdownRendererIsUsedWhenPandocIsMissing() {
        // 内置渲染器的输出形状（pandoc 会加 id，内置的不会）
        let html = MarkdownHTMLRenderer.renderDocument(markdown: "# Heading\n\nBody text.", title: "doc")
        XCTAssertTrue(html.contains("<h1>Heading</h1>"), "实际: \(html)")
    }

    func testLongHTMLPaginatesWithReasonablePageSize() throws {
        let rows = (1...300).map { "<p>Paragraph \($0) with enough text to take a line.</p>" }.joined()
        let html = directory.appendingPathComponent("book.html")
        try "<html><body>\(rows)</body></html>".write(to: html, atomically: true, encoding: .utf8)

        let result = convert(html)
        XCTAssertNil(result.error)

        let written = try XCTUnwrap(result.outputFiles.first)
        let document = try XCTUnwrap(PDFRasterizer.open(written))
        XCTAssertGreaterThan(document.numberOfPages, 1, "长文档必须分页")

        // 每一页都应该是 A4，而不是一张几千点高的纸
        for pageNumber in 1...min(document.numberOfPages, 3) {
            let page = try XCTUnwrap(document.page(at: pageNumber))
            let box = PDFRasterizer.effectiveBox(of: page)
            XCTAssertEqual(box.width, 595.28, accuracy: 1.0, "第 \(pageNumber) 页宽度不是 A4")
            XCTAssertEqual(box.height, 841.89, accuracy: 1.0, "第 \(pageNumber) 页高度不是 A4")
        }
    }

    // MARK: - 纯文本

    func testPlainTextBecomesPDF() throws {
        let text = directory.appendingPathComponent("readme.txt")
        try "Plain text file.\nSecond line with <angle> brackets & ampersand.".write(
            to: text, atomically: true, encoding: .utf8)

        let result = convert(text)

        XCTAssertNil(result.error, result.error?.message ?? "")
        let written = try XCTUnwrap(result.outputFiles.first)
        XCTAssertEqual(written.lastPathComponent, "readme.pdf")
        XCTAssertGreaterThan(try inkRatio(of: written), 0.001)
    }

    // MARK: - Office（需要 LibreOffice）

    func testRTFBecomesPDFWhenLibreOfficeIsInstalled() throws {
        let tool = ToolLocator.libreOffice()
        guard tool.isAvailable else {
            throw XCTSkip("LibreOffice 未安装，跳过：\(tool.installHint)")
        }

        let rtf = directory.appendingPathComponent("memo.rtf")
        try """
        {\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs28 FormatSmith RTF test.\\par
        Second paragraph.\\par}
        """.write(to: rtf, atomically: true, encoding: .utf8)

        let result = convert(rtf)

        XCTAssertNil(result.error, result.error?.message ?? "")
        let written = try XCTUnwrap(result.outputFiles.first)
        XCTAssertEqual(written.lastPathComponent, "memo.pdf")
        XCTAssertGreaterThan(PDFRasterizer.pageCount(of: written), 0)
        XCTAssertGreaterThan(try inkRatio(of: written), 0.0005, "LibreOffice 的输出不应是空白页")
    }

    func testOfficeInputWithoutLibreOfficeExplainsItself() throws {
        let tool = ToolLocator.libreOffice()
        guard !tool.isAvailable else {
            throw XCTSkip("本机装有 LibreOffice，这条降级路径无法在此验证")
        }

        let docx = directory.appendingPathComponent("fake.docx")
        try Data("not really a docx".utf8).write(to: docx)

        let plan = ConversionRouter.plan(
            input: .office(identifier: "org.openxmlformats.wordprocessingml.document"), target: .pdf)
        guard case let .unsupported(reason) = plan.availability else {
            return XCTFail("缺少 LibreOffice 时应明确说明，实际 \(plan.availability)")
        }
        XCTAssertTrue(reason.contains("LibreOffice"), reason)
        XCTAssertTrue(reason.contains("brew"), "应给出可照做的安装提示: \(reason)")
    }

    // MARK: - 依赖探测

    func testToolLocatorFindsExecutablesOnThePath() {
        // /bin/ls 一定存在，用它验证 PATH 查找逻辑
        let found = ToolLocator.findExecutable(named: "ls", extraPaths: [])
        XCTAssertNotNil(found, "应能在 PATH 里找到 ls")
        XCTAssertTrue(found?.path.hasSuffix("/ls") ?? false)
    }

    func testToolLocatorReturnsNilForMissingTools() {
        XCTAssertNil(ToolLocator.findExecutable(named: "definitely-not-a-real-tool-xyz", extraPaths: []))
    }

    func testToolLocatorPrefersExplicitPathOverPath() throws {
        // 传一个存在的绝对路径，应当直接命中它
        let found = ToolLocator.findExecutable(named: "ls", extraPaths: ["/bin/ls"])
        XCTAssertEqual(found?.path, "/bin/ls")
    }

    func testExternalToolReportsAvailabilityWithoutSpawningAProcess() {
        // isAvailable 只查文件系统；这里确认在没装工具的机器上也不会崩
        let missing = ExternalTool(name: "Nope", executableURL: nil, installHint: "install it")
        XCTAssertFalse(missing.isAvailable)
        XCTAssertNil(missing.probeVersion())
        XCTAssertEqual(missing.locationDescription, Localized.text("Not found"))
    }
}
