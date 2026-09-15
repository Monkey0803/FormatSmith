import AppKit
import FormatSmithCore
import SwiftUI
import XCTest
@testable import FormatSmith

/// 点击区域：这些控件必须「整块都能点」，而不是只有图标和文字。
///
/// 这一组测试对应一个真实的问题：预设格子里只有图标和文字能点中，
/// 点格子空白处（包括图标与文字之间那道缝）没有任何反应。
@MainActor
final class HitAreaTests: XCTestCase {

    /// 预设格子：网格里一格大约是 104×44。
    private let cellSize = CGSize(width: 104, height: 44)

    private func makePresetTester() -> ViewHitTester {
        let preset = PresetLibrary.all[0]
        return ViewHitTester(size: cellSize) { recorder in
            PresetButton(preset: preset, isSelected: false) { recorder.record() }
        }
    }

    func testPresetButtonRespondsInTheMiddleOfTheCell() {
        let tester = makePresetTester()
        defer { tester.tearDown() }
        XCTAssertTrue(
            tester.click(at: CGPoint(x: cellSize.width / 2, y: cellSize.height / 2)),
            "点在格子正中应当触发；这里正是图标与文字之间的缝隙，曾经点不动"
        )
    }

    func testPresetButtonRespondsNearBothEdges() {
        let tester = makePresetTester()
        defer { tester.tearDown() }
        let centerY = cellSize.height / 2

        for offset in [-45.0, -35.0, 35.0, 45.0] {
            XCTAssertTrue(
                tester.click(at: CGPoint(x: cellSize.width / 2 + offset, y: centerY)),
                "距中心 \(offset) pt 处也应可点（整格可点）"
            )
        }
    }

    func testPresetButtonRespondsAboveAndBelowTheContent() {
        let tester = makePresetTester()
        defer { tester.tearDown() }
        let centerX = cellSize.width / 2

        for y in [3.0, 8.0, cellSize.height - 8, cellSize.height - 3] {
            XCTAssertTrue(
                tester.click(at: CGPoint(x: centerX, y: y)),
                "纵向 y=\(y) 处也应可点"
            )
        }
    }

    func testPresetButtonHitAreaCoversAlmostTheWholeCell() {
        let tester = makePresetTester()
        defer { tester.tearDown() }

        let range = tester.horizontalHitRange(y: cellSize.height / 2, width: cellSize.width)
        let hitRange = try? XCTUnwrap(range)
        guard let hitRange else { return XCTFail("整格都不响应点击") }

        let covered = hitRange.upperBound - hitRange.lowerBound
        XCTAssertGreaterThan(
            covered, cellSize.width * 0.9,
            "可点宽度应接近整格，实际 \(covered) / \(cellSize.width)"
        )
    }

    /// DPI / 倍数芯片：与预设格子是同一种样式，同样要整格可点。
    func testPresetChipRowRespondsAcrossTheChip() {
        let tester = ViewHitTester(size: CGSize(width: 240, height: 20)) { recorder in
            PresetChipRow(
                values: [72, 150, 300], selected: 150,
                label: { "\(Int($0))" }, onSelect: { _ in recorder.record() }
            )
        }
        defer { tester.tearDown() }

        let centerY = 10.0
        // 三枚芯片，每枚约 76pt 宽；点在第二枚的两端（不是文字正中）
        for x in [82.0, 96.0, 120.0, 150.0] {
            XCTAssertTrue(
                tester.click(at: CGPoint(x: x, y: centerY)),
                "芯片在 x=\(x) 处应可点"
            )
        }
    }

    /// 反向保险：格子外面不应该响应，免得误触到相邻控件。
    /// 反向保险：放大命中区域不能放大到越界，芯片之间的间隙必须仍然是死区。
    ///
    /// 240pt 宽放三枚芯片、间距 6pt，每枚 76pt：
    /// 第一枚 0…76，间隙 76…82，第二枚 82…158。
    func testClicksInTheGapBetweenChipsDoNotTrigger() {
        let tester = ViewHitTester(size: CGSize(width: 240, height: 20)) { recorder in
            PresetChipRow(
                values: [72, 150, 300], selected: 150,
                label: { "\(Int($0))" }, onSelect: { _ in recorder.record() }
            )
        }
        defer { tester.tearDown() }

        XCTAssertFalse(
            tester.click(at: CGPoint(x: 79, y: 10)),
            "两枚芯片之间的 6pt 间隙不应触发任何一枚"
        )
    }
}
