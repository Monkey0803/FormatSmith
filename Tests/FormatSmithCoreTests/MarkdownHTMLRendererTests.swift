import XCTest
@testable import FormatSmithCore

/// 内置 Markdown 渲染器是纯函数，正好可以逐条钉死行为。
final class MarkdownHTMLRendererTests: XCTestCase {

    // MARK: - 块级

    func testHeadings() {
        let html = MarkdownHTMLRenderer.renderBody("# Title\n\n## Section\n\n### Deep")
        XCTAssertTrue(html.contains("<h1>Title</h1>"))
        XCTAssertTrue(html.contains("<h2>Section</h2>"))
        XCTAssertTrue(html.contains("<h3>Deep</h3>"))
    }

    func testHeadingWithoutSpaceIsNotAHeading() {
        // "#hashtag" 是普通文本，不是标题
        XCTAssertFalse(MarkdownHTMLRenderer.renderBody("#nope").contains("<h1>"))
    }

    func testParagraphsAreJoined() {
        let html = MarkdownHTMLRenderer.renderBody("first line\nsecond line")
        XCTAssertTrue(html.contains("<p>first line second line</p>"), "实际: \(html)")
    }

    func testParagraphsSplitOnBlankLine() {
        let html = MarkdownHTMLRenderer.renderBody("one\n\ntwo")
        XCTAssertTrue(html.contains("<p>one</p>"))
        XCTAssertTrue(html.contains("<p>two</p>"))
    }

    func testUnorderedList() {
        let html = MarkdownHTMLRenderer.renderBody("- one\n- two\n* three")
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<li>one</li>"))
        XCTAssertTrue(html.contains("<li>three</li>"))
        XCTAssertTrue(html.contains("</ul>"))
    }

    func testOrderedList() {
        let html = MarkdownHTMLRenderer.renderBody("1. first\n2. second")
        XCTAssertTrue(html.contains("<ol>"))
        XCTAssertTrue(html.contains("<li>first</li>"))
        XCTAssertTrue(html.contains("</ol>"))
    }

    func testSwitchingListTypeStartsANewList() {
        let html = MarkdownHTMLRenderer.renderBody("- bullet\n1. number")
        XCTAssertTrue(html.contains("</ul>"))
        XCTAssertTrue(html.contains("<ol>"))
    }

    func testFencedCodeBlock() {
        let html = MarkdownHTMLRenderer.renderBody("```swift\nlet x = 1 < 2\n```")
        XCTAssertTrue(html.contains("<pre><code>let x = 1 &lt; 2</code></pre>"), "实际: \(html)")
    }

    func testFencedCodeBlockKeepsBlankLines() {
        let html = MarkdownHTMLRenderer.renderBody("```\na\n\nb\n```")
        XCTAssertTrue(html.contains("a\n\nb"), "代码块内的空行不应被吞掉: \(html)")
    }

    func testCodeBlockContentIsNotTreatedAsMarkdown() {
        let html = MarkdownHTMLRenderer.renderBody("```\n# not a heading\n- not a list\n```")
        XCTAssertFalse(html.contains("<h1>"))
        XCTAssertFalse(html.contains("<ul>"))
    }

    func testBlockquote() {
        let html = MarkdownHTMLRenderer.renderBody("> quoted\n> more")
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("quoted"))
    }

    func testHorizontalRule() {
        XCTAssertTrue(MarkdownHTMLRenderer.renderBody("---").contains("<hr>"))
        XCTAssertTrue(MarkdownHTMLRenderer.renderBody("* * *").contains("<hr>"))
    }

    func testTableDelimiterIsNotRenderedAsText() {
        let html = MarkdownHTMLRenderer.renderBody("| a | b |\n| --- | --- |\n| 1 | 2 |")
        XCTAssertFalse(html.contains("<p>| --- | --- |</p>"), "表格分隔行不应变成段落: \(html)")
    }

    // MARK: - 行内

    func testEmphasis() {
        let html = MarkdownHTMLRenderer.renderInline("a **bold** and *italic* and `code`")
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
        XCTAssertTrue(html.contains("<code>code</code>"))
    }

    func testUnderscoreEmphasis() {
        XCTAssertTrue(MarkdownHTMLRenderer.renderInline("_italic_").contains("<em>italic</em>"))
        XCTAssertTrue(MarkdownHTMLRenderer.renderInline("__bold__").contains("<strong>bold</strong>"))
    }

    func testUnderscoresInsideWordsAreLeftAlone() {
        // snake_case_name 不应该被当成斜体
        XCTAssertEqual(MarkdownHTMLRenderer.renderInline("snake_case_name"), "snake_case_name")
    }

    func testLinks() {
        let html = MarkdownHTMLRenderer.renderInline("[docs](https://example.com)")
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">docs</a>"), "实际: \(html)")
    }

    func testImagesBecomePlaceholderText() {
        // PDF 里放不了外部图片，用占位文字比丢一个坏图标好
        let html = MarkdownHTMLRenderer.renderInline("![alt text](pic.png)")
        XCTAssertTrue(html.contains("[alt text]"))
        XCTAssertFalse(html.contains("<img"), "不应生成无法解析的 img 标签: \(html)")
    }

    func testStrikethrough() {
        XCTAssertTrue(MarkdownHTMLRenderer.renderInline("~~gone~~").contains("<del>gone</del>"))
    }

    func testAsterisksInsideCodeAreNotEmphasis() {
        let html = MarkdownHTMLRenderer.renderInline("`a * b * c`")
        XCTAssertTrue(html.contains("<code>a * b * c</code>"), "实际: \(html)")
    }

    // MARK: - 转义（生成的是 HTML，注入必须挡住）

    func testRawHTMLIsEscaped() {
        let html = MarkdownHTMLRenderer.renderInline("<script>alert(1)</script>")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testAmpersandsAreEscapedOnce() {
        XCTAssertEqual(MarkdownHTMLRenderer.renderInline("a & b"), "a &amp; b")
        XCTAssertEqual(MarkdownHTMLRenderer.renderInline("&amp;"), "&amp;amp;")
    }

    func testDocumentHasTitleAndBody() {
        let document = MarkdownHTMLRenderer.renderDocument(markdown: "# Hi", title: "notes")
        XCTAssertTrue(document.contains("<title>notes</title>"))
        XCTAssertTrue(document.contains("<h1>Hi</h1>"))
        XCTAssertTrue(document.contains("<!DOCTYPE html>"))
    }

    func testEmptyInputProducesEmptyBody() {
        XCTAssertEqual(MarkdownHTMLRenderer.renderBody("").trimmingCharacters(in: .whitespacesAndNewlines), "")
    }
}

final class DocumentConverterTests: XCTestCase {

    func testPrintStyleIsInjectedBeforeHeadEnd() {
        let html = "<html><head><title>x</title></head><body>hi</body></html>"
        let result = DocumentConverter.injectPrintStyle(into: html)
        let styleIndex = try? XCTUnwrap(result.range(of: "<style>"))
        let headEndIndex = try? XCTUnwrap(result.range(of: "</head>"))
        XCTAssertNotNil(styleIndex)
        XCTAssertNotNil(headEndIndex)
        if let styleIndex, let headEndIndex {
            XCTAssertLessThan(styleIndex.lowerBound, headEndIndex.lowerBound, "样式必须插在 </head> 之前")
        }
        XCTAssertTrue(result.contains("</head>"), "不能把 </head> 弄丢")
    }

    func testPrintStyleIsPrependedWhenThereIsNoHead() {
        let result = DocumentConverter.injectPrintStyle(into: "<p>bare</p>")
        XCTAssertTrue(result.hasPrefix("<style>"))
        XCTAssertTrue(result.contains("<p>bare</p>"))
    }

    func testPrintStyleHandlesUppercaseTags() {
        let result = DocumentConverter.injectPrintStyle(into: "<HTML><HEAD></HEAD><BODY></BODY></HTML>")
        XCTAssertTrue(result.contains("<style>"))
        XCTAssertTrue(result.uppercased().contains("</HEAD>"))
    }
}
