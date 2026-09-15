import XCTest
@testable import FormatSmithCore

final class OutputNamingTests: XCTestCase {

    // MARK: - 模板展开

    func testDefaultPattern() {
        let name = OutputNaming.expand(
            pattern: "{name}-{page}", documentName: "report",
            page: 2, pageCount: 10, padsPageNumbers: true
        )
        XCTAssertEqual(name, "report-02")
    }

    func testPaddingFollowsTotalPageDigits() {
        XCTAssertEqual(
            OutputNaming.expand(
                pattern: "{name}-{page}", documentName: "a", page: 5, pageCount: 9, padsPageNumbers: true),
            "a-5"
        )
        XCTAssertEqual(
            OutputNaming.expand(
                pattern: "{name}-{page}", documentName: "a", page: 5, pageCount: 10, padsPageNumbers: true),
            "a-05"
        )
        XCTAssertEqual(
            OutputNaming.expand(
                pattern: "{name}-{page}", documentName: "a", page: 5, pageCount: 100, padsPageNumbers: true),
            "a-005"
        )
    }

    func testPaddingCanBeDisabled() {
        XCTAssertEqual(
            OutputNaming.expand(
                pattern: "{name}-{page}", documentName: "a", page: 5, pageCount: 100, padsPageNumbers: false),
            "a-5"
        )
    }

    func testEmptyPatternFallsBackToDefault() {
        XCTAssertEqual(
            OutputNaming.expand(pattern: "", documentName: "doc", page: 1, pageCount: 1, padsPageNumbers: false),
            "doc-1"
        )
    }

    func testTotalPlaceholder() {
        XCTAssertEqual(
            OutputNaming.expand(
                pattern: "{name}_{page}of{total}", documentName: "doc", page: 3, pageCount: 12, padsPageNumbers: true),
            "doc_03of12"
        )
    }

    func testSingleOutputHasNoPageSuffix() {
        XCTAssertEqual(
            OutputNaming.expand(
                pattern: "{name}-{page}", documentName: "pic", page: nil, pageCount: nil, padsPageNumbers: true),
            "pic"
        )
    }

    func testDateAndTimePlaceholders() {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 7
        components.hour = 9
        components.minute = 5
        components.second = 30
        let date = Calendar(identifier: .gregorian).date(from: components)!

        let name = OutputNaming.expand(
            pattern: "{name}-{date}-{time}", documentName: "doc",
            page: 1, pageCount: 1, padsPageNumbers: false, date: date
        )
        XCTAssertEqual(name, "doc-20260307-090530")
    }

    // MARK: - 非法字符

    func testSanitizeRemovesPathSeparators() {
        XCTAssertEqual(OutputNaming.sanitize("a/b"), "a_b")
        XCTAssertEqual(OutputNaming.sanitize("a:b*c?d\"e<f>g|h"), "a_b_c_d_e_f_g_h")
        XCTAssertEqual(OutputNaming.sanitize("a\\b"), "a_b")
        XCTAssertEqual(OutputNaming.sanitize("  spaced  "), "spaced")
    }

    func testPatternCannotEscapeOutputDirectory() {
        var settings = ConversionSettings()
        settings.filenamePattern = "../../etc/passwd"
        settings.padsPageNumbers = false
        settings.format = .png

        let name = OutputNaming.fileName(for: "doc", page: 1, pageCount: 1, settings: settings)
        XCTAssertFalse(name.contains("/"), "文件名里不应出现路径分隔符: \(name)")

        // 真正的性质：拼出来的路径，父目录必须还是我们指定的输出目录。
        let outputDirectory = URL(fileURLWithPath: "/tmp/output", isDirectory: true)
        let resolved = outputDirectory.appendingPathComponent(name).standardizedFileURL
        XCTAssertEqual(resolved.deletingLastPathComponent().path, outputDirectory.standardizedFileURL.path)
    }

    func testPatternOfOnlySeparatorsFallsBackToDocumentName() {
        let name = OutputNaming.expand(
            pattern: "-", documentName: "doc", page: 3, pageCount: 3, padsPageNumbers: false
        )
        XCTAssertEqual(name, "doc-3")
    }

    func testDotOnlyPatternIsNeutralized() {
        XCTAssertEqual(OutputNaming.sanitize(".."), "")
        XCTAssertEqual(OutputNaming.sanitize("."), "")
    }

    // MARK: - 完整文件名

    func testFileNameUsesFormatExtension() {
        var settings = ConversionSettings()
        settings.format = .jpeg
        settings.filenamePattern = "{name}-{page}"
        settings.padsPageNumbers = false
        XCTAssertEqual(
            OutputNaming.fileName(for: "photo", page: 1, pageCount: 4, settings: settings),
            "photo-1.jpg"
        )
    }

    func testFileNameForHEICAndAVIF() {
        var settings = ConversionSettings()
        settings.format = .heic
        settings.filenamePattern = "{name}"
        XCTAssertEqual(OutputNaming.fileName(for: "x", page: nil, pageCount: nil, settings: settings), "x.heic")

        settings.format = .avif
        XCTAssertEqual(OutputNaming.fileName(for: "x", page: nil, pageCount: nil, settings: settings), "x.avif")
    }

    // MARK: - 重名唯一化

    func testUniqueURLDoesNotOverwriteExistingFiles() throws {
        let directory = try FixtureFactory.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("shot.png")
        try Data("first".utf8).write(to: target)

        let second = OutputNaming.uniqueURL(target)
        XCTAssertEqual(second.lastPathComponent, "shot-1.png")

        try Data("second".utf8).write(to: second)
        let third = OutputNaming.uniqueURL(target)
        XCTAssertEqual(third.lastPathComponent, "shot-2.png")

        // 原文件必须原封不动
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "first")
    }

    func testUniqueURLReturnsOriginalWhenFree() throws {
        let directory = try FixtureFactory.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("free.png")
        XCTAssertEqual(OutputNaming.uniqueURL(target), target)
    }
}
