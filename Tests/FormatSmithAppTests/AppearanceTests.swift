import AppKit
import SwiftUI
import XCTest
@testable import FormatSmith

/// 外观偏好。
///
/// 对应一次真实反馈：设成深色之后再点「跟随系统」没有反应（当时系统是浅色）。
/// 根因是当时用的是 SwiftUI 的 `preferredColorScheme` ——它能切到深色，
/// 但改回 `.system`（传 `nil`）时不会撤销已设过的方案。
/// 现在改用 `NSApp.appearance`，`.system` 就是把它置空，因此会真的回到跟随系统。
@MainActor
final class AppearanceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 让 NSApp 存在；测试进程里它默认可能还没被创建
        _ = NSApplication.shared
    }

    override func tearDown() {
        // 别把外观留给后面的测试
        NSApp?.appearance = nil
        super.tearDown()
    }

    // MARK: - 映射

    func testSystemMeansNoAppearanceAtAll() {
        XCTAssertNil(
            AppAppearance.system.appKitAppearance,
            "「跟随系统」必须是「不设方案」，而不是显式设成浅色或深色"
        )
        XCTAssertEqual(AppAppearance.light.appKitAppearance?.name, .aqua)
        XCTAssertEqual(AppAppearance.dark.appKitAppearance?.name, .darkAqua)
    }

    // MARK: - 真落到应用上

    func testDarkPinsTheAppearance() {
        AppearanceController.apply(.dark)
        XCTAssertFalse(AppearanceController.isFollowingSystem, "选了深色就该钉住")
        XCTAssertEqual(NSApp?.appearance?.name, .darkAqua)
    }

    func testGoingBackToSystemReleasesThePin() {
        // 就是这次反馈的路径：先深色，再跟随系统
        AppearanceController.apply(.dark)
        XCTAssertEqual(NSApp?.appearance?.name, .darkAqua)

        AppearanceController.apply(.system)
        XCTAssertTrue(
            AppearanceController.isFollowingSystem,
            "改回「跟随系统」必须解除钉住，否则界面会一直停在深色"
        )
        XCTAssertNil(NSApp?.appearance)
    }

    func testLightThenSystemAlsoReleases() {
        AppearanceController.apply(.light)
        XCTAssertEqual(NSApp?.appearance?.name, .aqua)

        AppearanceController.apply(.system)
        XCTAssertNil(NSApp?.appearance)
    }

    // MARK: - 偏好持久化

    func testChoiceSurvivesARelaunch() {
        UserDefaults.standard.set(AppAppearance.dark.rawValue, forKey: ConverterModel.appearanceKey)
        defer { UserDefaults.standard.removeObject(forKey: ConverterModel.appearanceKey) }

        let model = ConverterModel()
        XCTAssertEqual(model.appearance, .dark)
        XCTAssertEqual(NSApp?.appearance?.name, .darkAqua, "启动时就该套用上次的选择")
    }

    func testDefaultIsFollowingTheSystem() {
        UserDefaults.standard.removeObject(forKey: ConverterModel.appearanceKey)
        let model = ConverterModel()
        XCTAssertEqual(model.appearance, .system)
        XCTAssertNil(NSApp?.appearance)
    }
}
