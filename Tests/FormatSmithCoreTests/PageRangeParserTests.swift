import XCTest
@testable import FormatSmithCore

final class PageRangeParserTests: XCTestCase {

    // MARK: - 全部页面

    func testEmptyTextMeansAllPages() {
        XCTAssertEqual(PageRangeParser.parse("", pageCount: 5), [1, 2, 3, 4, 5])
        XCTAssertEqual(PageRangeParser.parse("   ", pageCount: 3), [1, 2, 3])
        XCTAssertEqual(PageRangeParser.parse("\n\t", pageCount: 2), [1, 2])
    }

    func testZeroPagesYieldsEmpty() {
        XCTAssertEqual(PageRangeParser.parse("", pageCount: 0), [])
        XCTAssertEqual(PageRangeParser.parse("1-3", pageCount: 0), [])
    }

    // MARK: - 基本区间

    func testSinglePagesAndRanges() {
        XCTAssertEqual(PageRangeParser.parse("5", pageCount: 10), [5])
        XCTAssertEqual(PageRangeParser.parse("1-3", pageCount: 10), [1, 2, 3])
        XCTAssertEqual(PageRangeParser.parse("1-3,5", pageCount: 10), [1, 2, 3, 5])
        XCTAssertEqual(PageRangeParser.parse("8-10", pageCount: 10), [8, 9, 10])
    }

    func testOpenEndedRanges() {
        XCTAssertEqual(PageRangeParser.parse("3-", pageCount: 5), [3, 4, 5])
        XCTAssertEqual(PageRangeParser.parse("-3", pageCount: 5), [1, 2, 3])
        XCTAssertEqual(PageRangeParser.parse("-", pageCount: 4), [1, 2, 3, 4])
    }

    func testReversedRangeIsNormalized() {
        XCTAssertEqual(PageRangeParser.parse("8-5", pageCount: 10), [5, 6, 7, 8])
        XCTAssertEqual(PageRangeParser.parse("3-1", pageCount: 10), [1, 2, 3])
    }

    // MARK: - 排序、去重、越界

    func testResultIsSortedAndDeduplicated() {
        XCTAssertEqual(PageRangeParser.parse("5,1-3,2", pageCount: 10), [1, 2, 3, 5])
        XCTAssertEqual(PageRangeParser.parse("2-4,3-5", pageCount: 10), [2, 3, 4, 5])
    }

    func testOutOfBoundsPagesAreDropped() {
        XCTAssertEqual(PageRangeParser.parse("1,99", pageCount: 3), [1])
        XCTAssertEqual(PageRangeParser.parse("0-2", pageCount: 5), [1, 2])
        XCTAssertEqual(PageRangeParser.parse("10-20", pageCount: 3), [])
    }

    func testMalformedChunksAreIgnored() {
        XCTAssertEqual(PageRangeParser.parse("abc", pageCount: 5), [])
        XCTAssertEqual(PageRangeParser.parse("1,,3", pageCount: 5), [1, 3])
        XCTAssertEqual(PageRangeParser.parse("1-2-3", pageCount: 5), [])
        XCTAssertEqual(PageRangeParser.parse("1;3", pageCount: 5), [])
    }

    // MARK: - 输入清洗

    func testAcceptsChinesePunctuationAndWhitespace() {
        XCTAssertEqual(PageRangeParser.parse("1，3", pageCount: 5), [1, 3])
        XCTAssertEqual(PageRangeParser.parse("1、3", pageCount: 5), [1, 3])
        XCTAssertEqual(PageRangeParser.parse("1－3", pageCount: 5), [1, 2, 3])
        XCTAssertEqual(PageRangeParser.parse("1 — 3", pageCount: 5), [1, 2, 3])
        XCTAssertEqual(PageRangeParser.parse(" 1 - 3 , 5 ", pageCount: 5), [1, 2, 3, 5])
    }

    // MARK: - 校验

    func testValidate() {
        XCTAssertTrue(PageRangeParser.validate("", pageCount: 5))
        XCTAssertTrue(PageRangeParser.validate("1-3", pageCount: 5))
        XCTAssertFalse(PageRangeParser.validate("abc", pageCount: 5))
        XCTAssertFalse(PageRangeParser.validate("99", pageCount: 5))
    }
}
