import XCTest

/// 队列交互必须**真的挂到界面上**。
///
/// 起因是一次很难看的失败：多选、右键菜单、拖拽排序的模型逻辑都写好了、测试也全绿，
/// 但把这些修饰符插到行上的补丁没匹配到锚点、静默地什么都没做 ——
/// 于是 `QueueRowDropDelegate` 和 `contextMenu` 只被定义、从未被使用，界面上什么都点不出来。
/// 模型测试完全测不到这种「接线断了」，所以这里直接扫描源码，
/// 确认「定义」之外还有「使用」。
final class QueueWiringTests: XCTestCase {

    private func queueSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FormatSmithAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根目录
        return try String(
            contentsOf: root.appendingPathComponent("Sources/FormatSmithApp/Views/QueueListView.swift"),
            encoding: .utf8
        )
    }

    func testRowIsWiredForSelectionAndContextMenu() throws {
        let source = try queueSource()

        let required: [(String, String)] = [
            (".onTapGesture", "点击选中没挂上：行还是死的"),
            ("model.select(", "点击没有落到模型的选中逻辑上"),
            (".contextMenu { contextMenu }", "右键菜单定义了却没挂到行上"),
            (".onMove {", "没有挂原生拖拽排序（List 的 onMove）"),
            (".accessibilityLabel", "图标按钮缺无障碍标签"),
            ("isSelected", "选中没有视觉反馈"),
        ]

        for (needle, message) in required {
            XCTAssertTrue(source.contains(needle), "\(message)（找不到 \(needle)）")
        }
    }

    /// 队列必须是原生 List + onMove。
    ///
    /// 自己拼手势失败了两次（补丁没接线、整行手势互抢），所以这里钉死：
    /// 排序必须走系统机制，不要再回到 onDrag/onDrop 那一套。
    func testReorderingUsesTheNativeListMechanism() throws {
        let source = try queueSource()

        XCTAssertTrue(source.contains("List {"), "队列应当是原生 List")
        XCTAssertTrue(source.contains(".onMove {"), "排序必须挂 onMove")
        XCTAssertFalse(
            source.contains("QueueRowDropDelegate"),
            "自制的拖放委托应当已经移除，否则又是两套机制并存"
        )
        XCTAssertFalse(
            source.contains("private var dragHandle"),
            "自制拖拽手柄应当已经移除"
        )
    }

    /// ESC 取消全选必须挂在视图层。
    func testEscapeIsHandledOnTheViewNotTheMenu() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let content = try String(
            contentsOf: root.appendingPathComponent("Sources/FormatSmithApp/Views/ContentView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(content.contains(".onExitCommand"), "ESC 没有挂 onExitCommand")

        let app = try String(
            contentsOf: root.appendingPathComponent("Sources/FormatSmithApp/FormatSmithApp.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            app.contains(".keyboardShortcut(.escape"),
            "Escape 不该挂在菜单上：会被系统当「取消」吃掉，菜单项收不到"
        )
    }

    func testSelectionIsActuallyRendered() throws {
        let source = try queueSource()
        // 选中要有填充，否则用户看不到自己选了什么
        XCTAssertTrue(
            source.contains("isSelected") && source.contains("Color.accentColor.opacity"),
            "选中状态没有渲染成可见的样式"
        )
    }
}
