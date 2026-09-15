import XCTest
@testable import FormatSmithCore

final class InputKindTests: XCTestCase {

    func testPDF() {
        XCTAssertEqual(InputKind.classify(identifier: "com.adobe.pdf", fileExtension: "pdf"), .pdf)
        XCTAssertEqual(InputKind.classify(identifier: nil, fileExtension: "pdf"), .pdf)
        XCTAssertEqual(InputKind.classify(identifier: nil, fileExtension: "PDF"), .pdf)
    }

    func testImages() {
        XCTAssertEqual(
            InputKind.classify(identifier: "public.png", fileExtension: "png"), .image(identifier: "public.png"))
        XCTAssertEqual(
            InputKind.classify(identifier: "public.jpeg", fileExtension: "jpg"), .image(identifier: "public.jpeg"))
        // 扩展名判定兜底
        XCTAssertEqual(InputKind.classify(identifier: nil, fileExtension: "png"), .image(identifier: "public.png"))
    }

    func testReadOnlyImageFormatsAreStillRecognizedAsImages() {
        // WebP / JPEG XL 只读不写，但仍然应该被识别成图片输入。
        for identifier in ["org.webmproject.webp", "public.jpeg-xl"] {
            guard FormatRegistry.readableIdentifiers.contains(identifier) else { continue }
            let kind = InputKind.classify(identifier: identifier, fileExtension: "")
            XCTAssertTrue(kind.isImage, "\(identifier) 应被识别为图片")
        }
    }

    func testOfficeDocuments() {
        let docx = InputKind.classify(identifier: "org.openxmlformats.wordprocessingml.document", fileExtension: "docx")
        guard case .office = docx else { return XCTFail("docx 应为 office，实际 \(docx)") }

        XCTAssertEqual(
            InputKind.classify(identifier: nil, fileExtension: "xlsx"),
            .office(identifier: "unknown")
        )
        for ext in ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf"] {
            guard case .office = InputKind.classify(identifier: nil, fileExtension: ext) else {
                return XCTFail("\(ext) 应被识别为 office 文档")
            }
        }
    }

    func testMarkupAndText() {
        XCTAssertEqual(InputKind.classify(identifier: "public.html", fileExtension: "html"), .html)
        XCTAssertEqual(InputKind.classify(identifier: nil, fileExtension: "htm"), .html)
        XCTAssertEqual(InputKind.classify(identifier: "net.daringfireball.markdown", fileExtension: "md"), .markdown)
        XCTAssertEqual(InputKind.classify(identifier: nil, fileExtension: "markdown"), .markdown)
        XCTAssertEqual(InputKind.classify(identifier: "public.plain-text", fileExtension: "txt"), .plainText)
    }

    func testUnknown() {
        let kind = InputKind.classify(identifier: "com.example.mystery", fileExtension: "mystery")
        guard case .unknown = kind else { return XCTFail("应为 unknown，实际 \(kind)") }
        XCTAssertFalse(kind.isImage)
    }

    func testIconsGroupFamilies() {
        XCTAssertEqual(InputKind.pdf.icon, .pdf)
        XCTAssertEqual(InputKind.classify(identifier: "public.png", fileExtension: "png").icon, .image)
        XCTAssertEqual(InputKind.classify(identifier: nil, fileExtension: "docx").icon, .document)
        XCTAssertEqual(InputKind.classify(identifier: nil, fileExtension: "md").icon, .document)
    }

    func testDisplayNames() {
        XCTAssertEqual(InputKind.pdf.displayName, "PDF")
        XCTAssertEqual(InputKind.classify(identifier: "public.png", fileExtension: "png").displayName, "PNG")
        XCTAssertEqual(InputKind.classify(identifier: nil, fileExtension: "md").displayName, "Markdown")
        XCTAssertEqual(InputKind.classify(identifier: nil, fileExtension: "html").displayName, "HTML")
    }

    // MARK: - 真实文件探测

    func testDetectOnRealFiles() throws {
        let directory = try FixtureFactory.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pdf = try FixtureFactory.makePDF(in: directory)
        XCTAssertEqual(InputKind.detect(url: pdf), .pdf)

        let png = try FixtureFactory.makeImage(in: directory)
        XCTAssertTrue(InputKind.detect(url: png).isImage)

        let text = directory.appendingPathComponent("notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertEqual(InputKind.detect(url: text), .plainText)
    }
}
