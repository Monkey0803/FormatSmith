import Foundation
import XCTest
@testable import FormatSmithCore

/// 预设的名字与说明必须跟着界面语言走。
///
/// 对应一次真实反馈：界面切成中文之后，预设框里十个名字**还是英文**。
/// 根因是 `PresetLibrary.all` 是 `static let`，而名字当初是用
/// `Localized.text("Web")` 在**构造时**解析的 —— 静态常量只初始化一次，
/// 于是第一次取用时语言就被定死了。改成存 key、读取时解析才修好。
final class PresetLocalizationTests: XCTestCase {

    override func tearDown() {
        Localized.language = .system
        super.tearDown()
    }

    private func preset(_ id: String) throws -> Preset {
        try XCTUnwrap(PresetLibrary.all.first { $0.id == id }, "找不到预设 \(id)")
    }

    /// 预设名必须是**读取时**解析的，不能在构造时把语言定死。
    ///
    /// 运行时解析在测试进程里验不了：`Localized.text` 需要一个 `.lproj` 子包，
    /// 而测试环境里拿不到（其它本地化用例也是直接读 .strings 文件，绕开这一点）。
    /// 所以这里直接盯住源码结构 —— 当初出问题的地方正是「构造时解析 + static let」。
    func testNamesAreResolvedAtReadTime() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/FormatSmithCore/Model/Preset.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("public var name: String { Localized.text(nameKey) }"),
            "名字应当由 nameKey 在读取时解析"
        )
        XCTAssertTrue(
            source.contains("public var detail: String { Localized.text(detailKey) }"),
            "说明应当由 detailKey 在读取时解析"
        )
        XCTAssertFalse(
            source.contains("name: Localized.text("),
            "构造时就解析名字会让 static let 的预设把语言定死（这正是中文界面下预设名仍是英文的原因）"
        )
        XCTAssertFalse(
            source.contains("detail: Localized.text("),
            "说明同理"
        )
    }

    func testPresetsStoreTheEnglishKeyNotTheResolvedText() throws {
        // key 就是英文原文，也是翻译表里的键
        let web = try preset("web")
        XCTAssertEqual(web.nameKey, "Web")
        XCTAssertFalse(web.detailKey.isEmpty)
    }

    /// 每个预设的名字与说明都必须在中文表里有译文，否则又是「界面变成中英混杂」。
    func testEveryPresetHasAChineseTranslation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let table = try XCTUnwrap(
            NSDictionary(
                contentsOf: root.appendingPathComponent(
                    "Resources/i18n/zh-Hans.lproj/Localizable.strings"
                )
            ) as? [String: String]
        )

        Localized.language = .english
        for preset in PresetLibrary.all {
            XCTAssertNotNil(table[preset.name], "预设「\(preset.name)」的名字缺中文")
            XCTAssertNotNil(table[preset.detail], "预设「\(preset.name)」的说明缺中文")
        }
    }

    func testPresetIDsStayEnglishForTheCLI() throws {
        // 名字可以翻译，但 id 是命令行的接口，必须稳定且是英文
        for preset in PresetLibrary.all {
            XCTAssertTrue(
                preset.id.allSatisfy { $0.isLetter && $0.isLowercase || $0.isUppercase },
                "id 应当是不含空格的英文标识：\(preset.id)"
            )
        }
    }
}
