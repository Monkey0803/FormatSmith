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

/// 保留书写顺序的解析（重排与提取用）。
final class OrderedPageRangeTests: XCTestCase {

    func testKeepsTheWrittenOrder() {
        XCTAssertEqual(PageRangeParser.parseOrdered("3,1", pageCount: 5), [3, 1])
        XCTAssertEqual(PageRangeParser.parseOrdered("5,2,4", pageCount: 5), [5, 2, 4])
    }

    func testExpandsRangesInPlace() {
        XCTAssertEqual(PageRangeParser.parseOrdered("3,1-2", pageCount: 5), [3, 1, 2])
        XCTAssertEqual(PageRangeParser.parseOrdered("4-5,1", pageCount: 5), [4, 5, 1])
    }

    func testKeepsTheFirstOccurrenceOfDuplicates() {
        XCTAssertEqual(PageRangeParser.parseOrdered("2,2,1,2", pageCount: 3), [2, 1])
        XCTAssertEqual(PageRangeParser.parseOrdered("1-3,2", pageCount: 3), [1, 2, 3])
    }

    func testDropsOutOfRangePages() {
        XCTAssertEqual(PageRangeParser.parseOrdered("9,2", pageCount: 3), [2])
        XCTAssertEqual(PageRangeParser.parseOrdered("0,2", pageCount: 3), [2])
    }

    func testEmptyMeansEverythingInOrder() {
        XCTAssertEqual(PageRangeParser.parseOrdered("", pageCount: 3), [1, 2, 3])
        XCTAssertEqual(PageRangeParser.parseOrdered("   ", pageCount: 3), [1, 2, 3])
    }

    func testOpenEndedRanges() {
        XCTAssertEqual(PageRangeParser.parseOrdered("3-", pageCount: 4), [3, 4])
        XCTAssertEqual(PageRangeParser.parseOrdered("-2", pageCount: 4), [1, 2])
    }

    func testReverseRangeExpandsAscending() {
        // 与 parse 保持一致：8-5 当作 5-8，只是位置留在写的地方
        XCTAssertEqual(PageRangeParser.parseOrdered("4,3-1", pageCount: 5), [4, 1, 2, 3])
    }

    func testAcceptsChinesePunctuation() {
        XCTAssertEqual(PageRangeParser.parseOrdered("3，1", pageCount: 5), [3, 1])
    }

    func testZeroPageCountYieldsNothing() {
        XCTAssertEqual(PageRangeParser.parseOrdered("1,2", pageCount: 0), [])
    }

    func testSetBasedParseStillSorts() {
        // 集合语义那一份没被改动：PDF → 图片仍然按文档顺序渲染
        XCTAssertEqual(PageRangeParser.parse("3,1", pageCount: 5), [1, 3])
    }
}
