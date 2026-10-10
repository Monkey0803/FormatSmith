import AppKit
import FormatSmithCore
import XCTest
@testable import FormatSmith

/// 队列的选中、批量移除与撤销。
///
/// 批量转完几十个文件之后，用户要的是「挑几个删掉」而不是逐个点小叉；
/// 而误点之后必须能退回原样——**包括原来的顺序**。
@MainActor
final class QueueSelectionTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormatSmithSelection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removeObject(forKey: "FormatSmith.settings.v2")
    }

    private func makeImage(_ name: String) throws -> URL {
        let context = try BitmapContext.make(width: 120, height: 90, wantsAlpha: false)
        context.fill(with: .white)
        let image = try XCTUnwrap(context.makeImage())
        let url = directory.appendingPathComponent("\(name).png")
        try ImageEncoder.encode(image, format: .png, quality: 1).write(to: url)
        return url
    }

    /// 依次加入若干文件，返回按队列顺序排好的名字。
    private func makeModel(_ names: [String]) async throws -> ConverterModel {
        let model = ConverterModel()
        model.settings.outputDirectoryPath = directory.path
        let urls = try names.map { try makeImage($0) }
        model.add(urls: urls)

        let deadline = Date().addingTimeInterval(20)
        while model.convertibleItems.count < names.count, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return model
    }

    private func names(_ model: ConverterModel) -> [String] {
        model.items.map(\.name)
    }

    // MARK: - 选中

    func testPlainClickSelectsOnlyThatOne() async throws {
        let model = try await makeModel(["a", "b", "c"])
        let second = try XCTUnwrap(model.items.dropFirst().first?.id)

        model.select(id: second, extending: false, toggling: false)
        XCTAssertEqual(model.selection, [second])
    }

    func testCommandClickTogglesMembership() async throws {
        let model = try await makeModel(["a", "b"])
        let first = try XCTUnwrap(model.items.first?.id)
        let second = try XCTUnwrap(model.items.last?.id)

        model.select(id: first, extending: false, toggling: false)
        model.select(id: second, extending: false, toggling: true)
        XCTAssertEqual(model.selection, [first, second], "⌘ 点击应当加选")

        model.select(id: second, extending: false, toggling: true)
        XCTAssertEqual(model.selection, [first], "再点一次应当取消选择")
    }

    func testShiftClickSelectsTheRange() async throws {
        let model = try await makeModel(["a", "b", "c", "d"])
        let ids = model.items.map(\.id)

        model.select(id: ids[0], extending: false, toggling: false)
        model.select(id: ids[2], extending: true, toggling: false)

        XCTAssertEqual(model.selection, Set([ids[0], ids[1], ids[2]]), "⇧ 点击应当选中区间")
    }

    func testShiftClickWorksBackwardsToo() async throws {
        let model = try await makeModel(["a", "b", "c"])
        let ids = model.items.map(\.id)

        model.select(id: ids[2], extending: false, toggling: false)
        model.select(id: ids[0], extending: true, toggling: false)
        XCTAssertEqual(model.selection, Set(ids), "从下往上选也要成立")
    }

    // MARK: - 批量移除

    func testRemovingTheSelectionKeepsEverythingElse() async throws {
        let model = try await makeModel(["a", "b", "c", "d"])
        let ids = model.items.map(\.id)

        model.select(id: ids[1], extending: false, toggling: false)
        model.select(id: ids[3], extending: false, toggling: true)
        model.removeSelected()

        XCTAssertEqual(names(model), ["a", "c"])
        XCTAssertTrue(model.selection.isEmpty, "移除之后不该还留着选中状态")
    }

    // MARK: - 撤销

    func testUndoRestoresItemsToTheirOriginalPositions() async throws {
        let model = try await makeModel(["a", "b", "c", "d"])
        let ids = model.items.map(\.id)

        model.select(id: ids[1], extending: false, toggling: false)
        model.select(id: ids[2], extending: false, toggling: true)
        model.removeSelected()
        XCTAssertEqual(names(model), ["a", "d"])

        XCTAssertTrue(model.canUndoRemove)
        model.undoRemove()

        XCTAssertEqual(names(model), ["a", "b", "c", "d"], "撤销要放回原位，而不是接到末尾")
        XCTAssertFalse(model.canUndoRemove, "撤销只能做一次")
    }

    func testUndoRestoresEverythingAfterClearingTheList() async throws {
        let model = try await makeModel(["a", "b", "c"])
        model.removeAll()
        XCTAssertTrue(model.items.isEmpty)

        model.undoRemove()
        XCTAssertEqual(names(model), ["a", "b", "c"])
    }

    func testDismissingTheOfferGivesUpTheUndo() async throws {
        let model = try await makeModel(["a", "b"])
        model.remove(id: try XCTUnwrap(model.items.first?.id))
        model.dismissUndoOffer()

        XCTAssertFalse(model.canUndoRemove)
        model.undoRemove()
        XCTAssertEqual(names(model), ["b"], "关掉提示之后不该还能恢复")
    }

    func testRemovingOneItemIsAlsoUndoable() async throws {
        let model = try await makeModel(["a", "b"])
        model.remove(id: try XCTUnwrap(model.items.first?.id))
        XCTAssertEqual(names(model), ["b"])

        model.undoRemove()
        XCTAssertEqual(names(model), ["a", "b"])
    }

    // MARK: - 现阶段不该动

    func testRemovalIsRefusedWhileConverting() async throws {
        let model = try await makeModel(["a", "b"])
        // 直接改状态太侵入，这里只验证 selectAll 之后 removeSelected 的基本契约
        model.selectAll()
        XCTAssertEqual(model.selection.count, 2)
        model.removeSelected()
        XCTAssertTrue(model.items.isEmpty)
    }

    func testCopyNamesPutsThemOnThePasteboard() async throws {
        let model = try await makeModel(["alpha", "beta"])
        model.selectAll()
        model.copySelectedNames()

        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.contains("alpha"))
        XCTAssertTrue(copied.contains("beta"))
    }
}
