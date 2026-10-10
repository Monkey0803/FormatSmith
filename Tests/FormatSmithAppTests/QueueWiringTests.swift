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
            ("List(selection:", "选中没有交给 List 原生机制"),
            (".onMove {", "没有挂 onMove"),
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

        XCTAssertTrue(source.contains("List(selection:"), "队列应当是原生 List，并接管选中")
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
    /// 行上绝不能有 onTapGesture：它会和 .onMove 抢同一次按下，拖拽就起不来。
    func testRowHasNoTapGestureCompetingWithDrag() throws {
        let source = try queueSource()
        XCTAssertFalse(
            source.contains(".onTapGesture"),
            "行上还有 onTapGesture，会和拖拽抢手势（这正是三轮拖不动的原因）"
        )
    }

    func testEscapeIsHandledByALocalMonitorNotByFocus() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let content = try String(
            contentsOf: root.appendingPathComponent("Sources/FormatSmithApp/Views/ContentView.swift"),
            encoding: .utf8
        )
        // ESC 走本地事件监听：不依赖焦点（onExitCommand 需要焦点、菜单的 escape 会被系统吃掉）
        let model = try String(
            contentsOf: root.appendingPathComponent("Sources/FormatSmithApp/ConverterModel.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            model.contains("addLocalMonitorForEvents"),
            "ESC 没有本地事件监听，焦点不在队列上时按了不会有反应"
        )
        XCTAssertTrue(model.contains("keyCode == 53"), "监听里没有判断 ESC 键码")

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

/// 输出目标的选择器里必须真的能选到「纯文本」。
///
/// 这一条是这次会话的教训：模型、引擎、路由都通了、测试也绿，
/// 但界面没接线 —— 用户根本选不到，功能等于不存在。
final class TargetPickerWiringTests: XCTestCase {

    private func panelSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(
                "Sources/FormatSmithApp/Views/Panels/ConversionSettingsPanel.swift"
            ),
            encoding: .utf8
        )
    }

    func testTextTargetIsOfferedInThePicker() throws {
        let source = try panelSource()
        XCTAssertTrue(
            source.contains("OutputTarget.text"),
            "选择器里没有纯文本目标，用户选不到这个功能"
        )
        XCTAssertTrue(source.contains("OutputTarget.pdf"), "PDF 目标不该被挤掉")
    }
}
