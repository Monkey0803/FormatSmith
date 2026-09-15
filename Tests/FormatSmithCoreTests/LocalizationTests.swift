import Foundation
import XCTest
@testable import FormatSmithCore

/// 本地化：语言切换的解析规则，以及「文案有没有漏翻」。
final class LocalizationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 命令行之外的地方不该带着这个开关跑测试。
        Localized.forcesBaseLanguage = false
        Localized.language = .system
    }

    override func tearDown() {
        Localized.forcesBaseLanguage = false
        Localized.language = .system
        super.tearDown()
    }

    // MARK: - 语言模型

    func testLanguageCodes() {
        XCTAssertNil(AppLanguage.system.languageCode, "跟随系统没有固定语言代码")
        XCTAssertEqual(AppLanguage.english.languageCode, "en")
        XCTAssertEqual(AppLanguage.simplifiedChinese.languageCode, "zh-Hans")
    }

    func testLanguageNamesAreWrittenInTheirOwnLanguage() {
        // 切成看不懂的语言后还得能找回来，所以中文名必须是中文
        XCTAssertEqual(AppLanguage.english.displayName, "English")
        XCTAssertEqual(AppLanguage.simplifiedChinese.displayName, "简体中文")
    }

    func testAllCasesAreListedForThePicker() {
        XCTAssertEqual(AppLanguage.allCases.count, 3)
        XCTAssertTrue(AppLanguage.allCases.contains(.system))
    }

    // MARK: - 取词规则

    func testExplicitEnglishFallsBackToTheKey() {
        Localized.language = .english
        // 本项目没有 en.lproj，英文原文就是 key，因此应当原样返回
        XCTAssertEqual(Localized.text("Output format"), "Output format")
        XCTAssertEqual(
            Localized.resolve("Missing tools", in: .english), "Missing tools",
            "英文应当回退到 key，而不是回退到系统语言"
        )
    }

    func testUnknownKeyFallsBackToItself() {
        Localized.language = .english
        XCTAssertEqual(Localized.text("This key does not exist anywhere"), "This key does not exist anywhere")
    }

    func testFormatArgumentsAreApplied() {
        Localized.language = .english
        XCTAssertEqual(Localized.text("Added %d file(s).", 3), "Added 3 file(s).")
    }

    func testForcedBaseLanguageIgnoresTheSelection() {
        Localized.language = .simplifiedChinese
        Localized.forcesBaseLanguage = true
        defer { Localized.forcesBaseLanguage = false }

        // 命令行模式必须稳定输出英文，否则脚本的 grep 会随系统语言失效
        XCTAssertEqual(Localized.text("Merge"), "Merge")
    }

    func testResolveIgnoresForcedBaseLanguage() {
        // --check-localization 是显式的诊断请求，不该被命令行的英文开关影响
        Localized.forcesBaseLanguage = true
        defer { Localized.forcesBaseLanguage = false }

        let english = Localized.resolve("Merge", in: .english)
        XCTAssertEqual(english, "Merge")
    }

    func testSwitchingLanguageIsReflectedImmediately() {
        Localized.language = .english
        let before = Localized.text("Merge")
        Localized.language = .simplifiedChinese
        let after = Localized.text("Merge")

        if Localized.bundle(for: .simplifiedChinese) != nil {
            XCTAssertNotEqual(before, after, "指定中文后应立刻取到中文文案")
        } else {
            // 测试进程里没有语言包时，两边都会回退到英文原文
            XCTAssertEqual(after, before)
        }
    }

    func testBundleLookupOnlyResolvesBundledLanguages() {
        // 这个测试进程里没有 .lproj，所以应当拿不到
        XCTAssertNil(Localized.bundle(for: .system), "跟随系统不该有独立语言包")
        if Localized.bundle(for: .simplifiedChinese) == nil {
            XCTAssertEqual(Localized.text("Merge"), "Merge", "没有语言包时退回英文原文")
        }
    }

    // MARK: - 文案完整性

    func testEveryKeyUsedInSourceHasAChineseTranslation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FormatSmithCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根目录
        let stringsURL = root.appendingPathComponent("Resources/i18n/zh-Hans.lproj/Localizable.strings")

        let table = try XCTUnwrap(
            NSDictionary(contentsOf: stringsURL) as? [String: String],
            "无法读取 \(stringsURL.path)"
        )
        XCTAssertFalse(table.isEmpty)

        let sources = try FileManager.default.subpaths(atPath: root.appendingPathComponent("Sources").path) ?? []
        var used = Set<String>()
        for relative in sources where relative.hasSuffix(".swift") {
            let text = try String(
                contentsOf: root.appendingPathComponent("Sources").appendingPathComponent(relative),
                encoding: .utf8
            )
            used.formUnion(Self.localizedKeys(in: text))
        }

        XCTAssertGreaterThan(used.count, 100, "应当能扫出大量 key，扫描逻辑可能失效了")

        let missing = used.subtracting(table.keys).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            "以下文案在 zh-Hans 里缺翻译，界面会露出英文：\n  " + missing.joined(separator: "\n  ")
        )
    }

    func testNoDuplicateKeysInTheStringsFile() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let stringsURL = root.appendingPathComponent("Resources/i18n/zh-Hans.lproj/Localizable.strings")
        let text = try String(contentsOf: stringsURL, encoding: .utf8)

        var seen = Set<String>()
        var duplicates: [String] = []
        for line in text.components(separatedBy: "\n") {
            guard let key = Self.key(inStringsLine: line) else { continue }
            if !seen.insert(key).inserted { duplicates.append(key) }
        }
        XCTAssertTrue(duplicates.isEmpty, "zh-Hans 里有重复的 key：\(duplicates)")
    }

    func testDeclaredLanguagesHaveBundlesOrNeedNone() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        for language in AppLanguage.allCases {
            guard let code = language.languageCode else { continue }
            let path = root.appendingPathComponent("Resources/i18n/\(code).lproj/Localizable.strings")
            if language == .english {
                // 英文原文就是 key，允许没有 en.lproj
                continue
            }
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: path.path),
                "\(language.displayName) 声明了语言代码 \(code)，却没有 \(path.lastPathComponent)"
            )
        }
    }

    // MARK: - 扫描工具

    /// 从源码里扫出 `Localized.text("…")` 的 key（含跨行调用）。
    static func localizedKeys(in source: String) -> Set<String> {
        let pattern = try? NSRegularExpression(
            pattern: #"Localized\.text\(\s*"((?:[^"\\]|\\.)*)""#,
            options: [.dotMatchesLineSeparators]
        )
        guard let pattern else { return [] }

        var keys = Set<String>()
        let range = NSRange(source.startIndex..., in: source)
        for match in pattern.matches(in: source, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
            keys.insert(String(source[keyRange]))
        }
        return keys
    }

    /// 从 `"key" = "value";` 这样的行里取出 key。
    static func key(inStringsLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\"") else { return nil }
        let pattern = try? NSRegularExpression(pattern: #"^"((?:[^"\\]|\\.)*)"\s*="#)
        guard let pattern,
            let match = pattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
            let keyRange = Range(match.range(at: 1), in: trimmed)
        else { return nil }
        return String(trimmed[keyRange])
    }
}
