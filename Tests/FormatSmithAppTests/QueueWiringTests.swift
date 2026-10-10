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

    func testRowIsWiredForSelectionContextMenuAndDragging() throws {
        let source = try queueSource()

        let required: [(String, String)] = [
            (".onTapGesture", "点击选中没挂上：行还是死的"),
            ("model.select(", "点击没有落到模型的选中逻辑上"),
            (".contextMenu { contextMenu }", "右键菜单定义了却没挂到行上"),
            ("QueueRowDropDelegate(target:", "拖拽排序的委托定义了却没挂上"),
            (".onDrag {", "没有拖拽来源"),
            ("dragHandle", "拖拽手柄定义了却没挂到行上"),
            (".accessibilityLabel", "图标按钮缺无障碍标签"),
            ("isSelected", "选中没有视觉反馈"),
        ]

        for (needle, message) in required {
            XCTAssertTrue(source.contains(needle), "\(message)（找不到 \(needle)）")
        }
    }

    /// 只有定义没有使用的名字，说明接线断了。
    func testHelpersAreUsedNotJustDeclared() throws {
        let source = try queueSource()

        // `contextMenu` 必须出现两次：一次定义、一次作为修饰符的参数
        let contextMenuCount = source.components(separatedBy: "contextMenu").count - 1
        XCTAssertGreaterThanOrEqual(
            contextMenuCount, 2,
            "contextMenu 只出现 \(contextMenuCount) 次，多半是只定义没使用"
        )

        let delegateCount = source.components(separatedBy: "QueueRowDropDelegate").count - 1
        XCTAssertGreaterThanOrEqual(
            delegateCount, 2,
            "QueueRowDropDelegate 只出现 \(delegateCount) 次，多半是只定义没使用"
        )
    }

    /// 拖拽必须挂在没有点击手势的地方，否则两个手势抢同一次按下，拖不起来。
    func testDragLivesOnTheHandleNotTheWholeRow() throws {
        let source = try queueSource()

        let handleCount = source.components(separatedBy: "dragHandle").count - 1
        XCTAssertGreaterThanOrEqual(
            handleCount, 2, "手柄只出现 \(handleCount) 次，多半是只定义没使用"
        )

        // 行本身不该再有 onDrag：会和点击选中抢手势
        let rowEnd = source.range(of: "private var dragHandle")?.lowerBound ?? source.endIndex
        let rowBody = String(source[source.startIndex..<rowEnd])
        XCTAssertFalse(
            rowBody.contains(".onDrag {"),
            "行主体上还挂着 onDrag，会和 onTapGesture 抢手势（这正是拖不动的原因）"
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
