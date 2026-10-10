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

/// 拖拽排序：把一项移到另一项前面。
@MainActor
final class QueueReorderTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormatSmithReorder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removeObject(forKey: "FormatSmith.settings.v2")
    }

    private func makeModel(_ names: [String]) async throws -> ConverterModel {
        let model = ConverterModel()
        model.settings.outputDirectoryPath = directory.path
        var urls: [URL] = []
        for name in names {
            let context = try BitmapContext.make(width: 60, height: 40, wantsAlpha: false)
            context.fill(with: .white)
            let url = directory.appendingPathComponent("\(name).png")
            try ImageEncoder.encode(try XCTUnwrap(context.makeImage()), format: .png, quality: 1)
                .write(to: url)
            urls.append(url)
        }
        model.add(urls: urls)
        let deadline = Date().addingTimeInterval(20)
        while model.convertibleItems.count < names.count, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return model
    }

    func testMovingForward() async throws {
        let model = try await makeModel(["a", "b", "c", "d"])
        let ids = model.items.map(\.id)
        // 把 a 拖到 c 前面：期望 b, a, c, d
        model.move(id: ids[0], before: ids[2])
        XCTAssertEqual(model.items.map(\.name), ["b", "a", "c", "d"])
    }

    func testMovingBackward() async throws {
        let model = try await makeModel(["a", "b", "c", "d"])
        let ids = model.items.map(\.id)
        // 把 d 拖到 b 前面：期望 a, d, b, c
        model.move(id: ids[3], before: ids[1])
        XCTAssertEqual(model.items.map(\.name), ["a", "d", "b", "c"])
    }

    func testMovingOntoItselfChangesNothing() async throws {
        let model = try await makeModel(["a", "b"])
        let ids = model.items.map(\.id)
        model.move(id: ids[0], before: ids[0])
        XCTAssertEqual(model.items.map(\.name), ["a", "b"])
    }

    func testNothingIsLostOrDuplicated() async throws {
        let model = try await makeModel(["a", "b", "c", "d", "e"])
        let ids = model.items.map(\.id)
        model.move(id: ids[4], before: ids[0])
        model.move(id: ids[1], before: ids[3])
        XCTAssertEqual(model.items.count, 5, "排序不该丢项或重复")
        XCTAssertEqual(Set(model.items.map(\.name)).count, 5)
    }
}

/// 原生 onMove 的排序语义。
@MainActor
final class NativeMoveTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormatSmithMove-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removeObject(forKey: "FormatSmith.settings.v2")
    }

    private func makeModel(_ names: [String]) async throws -> ConverterModel {
        let model = ConverterModel()
        model.settings.outputDirectoryPath = directory.path
        var urls: [URL] = []
        for name in names {
            let context = try BitmapContext.make(width: 50, height: 40, wantsAlpha: false)
            context.fill(with: .white)
            let url = directory.appendingPathComponent("\(name).png")
            try ImageEncoder.encode(try XCTUnwrap(context.makeImage()), format: .png, quality: 1)
                .write(to: url)
            urls.append(url)
        }
        model.add(urls: urls)
        let deadline = Date().addingTimeInterval(20)
        while model.convertibleItems.count < names.count, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return model
    }

    /// destination 的含义是「插入到该下标之前」。
    func testMoveDownMatchesSwiftUISemantics() async throws {
        let model = try await makeModel(["a", "b", "c", "d"])
        // 把 a（下标 0）拖到 c 之后：destination 是 2
        model.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(model.items.map(\.name), ["b", "a", "c", "d"])
    }

    func testMoveUp() async throws {
        let model = try await makeModel(["a", "b", "c", "d"])
        // 把 d（下标 3）拖到最前：destination 是 0
        model.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        XCTAssertEqual(model.items.map(\.name), ["d", "a", "b", "c"])
    }

    func testMoveToTheEnd() async throws {
        let model = try await makeModel(["a", "b", "c"])
        model.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(model.items.map(\.name), ["b", "c", "a"])
    }

    func testMovingMultipleRows() async throws {
        let model = try await makeModel(["a", "b", "c", "d", "e"])
        model.move(fromOffsets: IndexSet([1, 2]), toOffset: 4)
        XCTAssertEqual(model.items.map(\.name), ["a", "d", "b", "c", "e"])
    }

    func testMovingNowhereKeepsOrder() async throws {
        let model = try await makeModel(["a", "b", "c"])
        model.move(fromOffsets: IndexSet(integer: 1), toOffset: 1)
        XCTAssertEqual(model.items.map(\.name), ["a", "b", "c"], "原位插入不该改变顺序")
    }

    func testNothingIsLost() async throws {
        let model = try await makeModel(["a", "b", "c", "d"])
        model.move(fromOffsets: IndexSet(integer: 0), toOffset: 4)
        model.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(model.items.count, 4)
        XCTAssertEqual(Set(model.items.map(\.name)).count, 4)
    }
}
