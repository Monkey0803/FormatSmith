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
    /// 扫描源码里所有「最终会被用户看到」的文案 key。
    ///
    /// 只认 `Localized.text("…")` 是不够的 —— 状态栏文案走的是 `StatusMessage("…")`，
    /// 于是十几条运行时消息（已添加 N 个文件、正在转换…）长期没有翻译，
    /// 界面切成中文之后底部还是英文。这个漏网就是那次事故留下的教训：
    /// **凡是通往界面的入口都要在这里列上**。
    static func localizedKeys(in source: String) -> Set<String> {
        let patterns = [
            #"Localized\.text\(\s*"((?:[^"\\]|\\.)*)""#,
            #"StatusMessage\(\s*"((?:[^"\\]|\\.)*)""#,
        ]

        var keys = Set<String>()
        let range = NSRange(source.startIndex..., in: source)
        for raw in patterns {
            guard
                let pattern = try? NSRegularExpression(
                    pattern: raw, options: [.dotMatchesLineSeparators]
                )
            else { continue }
            for match in pattern.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                keys.insert(String(source[keyRange]))
            }
        }
        // 纯格式占位（例如 "%@"）只是转交参数，没有可翻译的内容
        return keys.filter { !Self.isPureFormatPlaceholder($0) }
    }

    /// `"%@ %d"` 这种整串都是占位符的 key 不需要翻译。
    static func isPureFormatPlaceholder(_ key: String) -> Bool {
        key.range(of: #"^\s*(%[@dfsxu]|\s)+$"#, options: .regularExpression) != nil
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

/// 启动意图的判断：判错会把 GUI 也锁成英文。
final class LaunchModeTests: XCTestCase {

    func testNoArgumentsMeansTheGraphicalApp() {
        XCTAssertEqual(LaunchMode.intent(arguments: []), .graphical)
    }

    func testFinderStyleArgumentsStayGraphical() {
        // Finder 用「打开方式」启动时会带上文件路径，没有我们认识的开关
        XCTAssertEqual(LaunchMode.intent(arguments: ["/Users/me/report.pdf"]), .graphical)
        XCTAssertEqual(LaunchMode.intent(arguments: ["-NSDocumentRevisionsDebugMode", "YES"]), .graphical)
    }

    func testEveryCommandLineFlagIsRecognized() {
        for flag in LaunchMode.commandLineFlags {
            XCTAssertEqual(
                LaunchMode.intent(arguments: [flag]), .commandLine,
                "\(flag) 应当被识别为命令行模式"
            )
        }
    }

    func testRealCommandLineInvocations() {
        XCTAssertEqual(
            LaunchMode.intent(arguments: ["--convert", "a.pdf", "--to", "png"]), .commandLine
        )
        XCTAssertEqual(LaunchMode.intent(arguments: ["--check-localization"]), .commandLine)
    }

    func testGraphicalLaunchMustNotForceEnglish() {
        // 这条断言直接对应曾经的 bug：GUI 启动时绝不能打开 forcesBaseLanguage，
        // 否则语言开关会完全失效（文案永远取英文原文）。
        Localized.forcesBaseLanguage = false
        Localized.language = .simplifiedChinese
        defer {
            Localized.forcesBaseLanguage = false
            Localized.language = .system
        }

        let intent = LaunchMode.intent(arguments: [])
        XCTAssertEqual(intent, .graphical)
        XCTAssertFalse(Localized.forcesBaseLanguage, "图形界面不应强制英文")
    }
}

/// 状态文案的解析：切语言后必须换成新语言，而不是停在旧语言。
final class StatusMessageTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Localized.forcesBaseLanguage = false
        Localized.language = .english
    }

    override func tearDown() {
        Localized.forcesBaseLanguage = false
        Localized.language = .system
        super.tearDown()
    }

    func testResolvesWithoutArguments() {
        let message = StatusMessage("Cancelled.")
        XCTAssertEqual(message.resolved(), "Cancelled.")
    }

    func testFormatsTextAndNumberArguments() {
        let message = StatusMessage("Finished: %d file(s) → %@", 3, "/tmp/out")
        XCTAssertEqual(message.resolved(), "Finished: 3 file(s) → /tmp/out")
    }

    func testArgumentsAreTypeCheckedNotStringified() {
        // %d 必须拿到 Int，传字符串会崩，所以参数保留类型
        let message = StatusMessage("Added %d file(s).", 7)
        XCTAssertEqual(message.resolved(), "Added 7 file(s).")
    }

    func testSwitchingLanguageReresolvesTheSameMessage() {
        let message = StatusMessage("Cancelled.")
        let english = message.resolved()

        Localized.language = .simplifiedChinese
        let chinese = message.resolved()

        if Localized.bundle(for: .simplifiedChinese) != nil {
            XCTAssertNotEqual(english, chinese, "同一条状态在不同语言下应当解析出不同文案")
        }
    }

    func testSuccessDetectionFollowsTheKeyNotTheLanguage() {
        // 图标判断不能依赖渲染后的文案，否则切语言就失效了
        XCTAssertTrue(StatusMessage("Finished: %d file(s) → %@", 1, "/tmp").isSuccess)
        XCTAssertTrue(StatusMessage("Merged %d images → %@", 2, "/tmp").isSuccess)
        XCTAssertFalse(StatusMessage("Cancelled.").isSuccess)
    }
}

/// 状态栏文案的本地化。
///
/// 这组对应一次真实事故：界面切成中文之后，底部状态栏仍然是英文
/// （截图里明晃晃的 “Drop files here, or click “Choose Files” to start.”）。
/// 原因是状态消息走 `StatusMessage`，而完整性扫描只认 `Localized.text`，
/// 于是 15 条运行时消息长期没有翻译，测试却一直是绿的。
final class StatusMessageLocalizationTests: XCTestCase {

    private func table() throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Resources/i18n/zh-Hans.lproj/Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    /// 状态消息的每一条都必须有中文；漏了就会在中文界面下露出英文。
    func testEveryStatusMessageUsedInCodeHasAChineseValue() throws {
        let table = try table()

        let messages: [StatusMessage] = [
            .idle,
            StatusMessage("Added %d file(s).", 1),
            StatusMessage("Applied preset: %@", "x"),
            StatusMessage("Cancelling…"),
            StatusMessage("Converting %d file(s)…", 1),
            StatusMessage("Converting %d file(s), %d at a time…", 2, 1),
            StatusMessage("Copied %d name(s).", 1),
            StatusMessage("Finished with %d failure(s).", 1),
            StatusMessage("Finished: %d file(s) → %@", 1, "/tmp"),
            StatusMessage("Ignored unsupported file: %@", "x"),
            StatusMessage("Merged %d file(s) → %@", 1, "/tmp"),
            StatusMessage("Output folder does not exist: %@", "/tmp"),
            StatusMessage("Output folder is not writable: %@", "/tmp"),
            StatusMessage("Restored %d file(s).", 1),
        ]

        for message in messages {
            let value = table[message.key]
            XCTAssertNotNil(value, "状态文案缺中文：\(message.key)")
            XCTAssertNotEqual(value, message.key, "中文与英文原文相同，等于没翻译：\(message.key)")
        }
    }

    func testTheIdleMessageSpecificallyIsChinese() throws {
        // 屏幕上最先出现、也最显眼的一条
        let value = try XCTUnwrap(try table()[StatusMessage.idle.key])
        XCTAssertFalse(value.contains("Drop files here"), "实际：\(value)")
        XCTAssertTrue(value.contains("选择文件") || value.contains("拖"), "实际：\(value)")
    }

    func testStatusKeysSurviveArgumentSubstitution() {
        // key 里带占位符时，替换之后仍应保留数字与路径
        let message = StatusMessage("Finished: %d file(s) → %@", 2, "/tmp/out")
        XCTAssertTrue(message.key.contains("%d"))
        XCTAssertTrue(message.key.contains("%@"))
    }
}
