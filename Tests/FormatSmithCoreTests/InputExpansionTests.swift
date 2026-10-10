import CoreGraphics
import Foundation
import XCTest
@testable import FormatSmithCore

/// 文件夹展开：子目录必须被看到。
///
/// 这里锁住一个**更早就存在**的 bug：原来的写法是
/// `while let child = enumerator?.nextObject() as? URL, isSupported(child)`——
/// 条件为假时整个循环就结束了，于是枚举到子目录本身（不是支持的文件）时循环终止，
/// **子目录里的文件永远看不到**。界面里拖入文件夹因此也一直忽略子目录。
final class InputExpansionTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Expand-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func writeImage(_ name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = try BitmapContext.make(width: 40, height: 40, wantsAlpha: false)
        context.fill(with: .white)
        let url = folder.appendingPathComponent(name)
        try ImageEncoder.encode(try XCTUnwrap(context.makeImage()), format: .png, quality: 1)
            .write(to: url)
        return url
    }

    func testSubdirectoriesAreEnumerated() throws {
        try writeImage("top.png", in: directory)
        try writeImage("deep.png", in: directory.appendingPathComponent("sub", isDirectory: true))
        try writeImage(
            "deeper.png",
            in: directory.appendingPathComponent("sub/again", isDirectory: true)
        )

        let found = InputExpansion.contents(of: directory).map(\.lastPathComponent).sorted()
        XCTAssertEqual(
            found, ["deep.png", "deeper.png", "top.png"],
            "子目录（含多层）里的文件都应当被枚举到，实际：\(found)"
        )
    }

    func testUnsupportedFilesAreSkippedWithoutStoppingTheWalk() throws {
        try writeImage("photo.png", in: directory)
        try "not an image".write(
            to: directory.appendingPathComponent("notes.xyz"), atomically: true, encoding: .utf8
        )
        try writeImage("after.png", in: directory)

        let found = InputExpansion.contents(of: directory).map(\.lastPathComponent).sorted()
        XCTAssertTrue(found.contains("photo.png"))
        XCTAssertTrue(
            found.contains("after.png"),
            "遇到不认识的文件应当跳过并继续，而不是就此停下：\(found)"
        )
        XCTAssertFalse(found.contains("notes.xyz"))
    }

    func testFolderContentsAreSortedByName() throws {
        for name in ["c.png", "a.png", "b.png"] {
            try writeImage(name, in: directory)
        }
        let found = InputExpansion.contents(of: directory).map(\.lastPathComponent)
        XCTAssertEqual(found, ["a.png", "b.png", "c.png"], "文件夹里的顺序按名字排，不能听文件系统的")
    }

    /// 显式给出的文件保持用户顺序 —— 正反面顺序靠这个。
    func testExplicitFilesKeepTheGivenOrder() throws {
        let first = try writeImage("b.png", in: directory)
        let second = try writeImage("a.png", in: directory)

        let outcome = InputExpansion.expand([first, second])
        XCTAssertEqual(
            outcome.files.map(\.lastPathComponent), ["b.png", "a.png"],
            "显式给出的顺序不能被改"
        )
    }

    func testExpandMixesFoldersAndFiles() throws {
        try writeImage("inside.png", in: directory.appendingPathComponent("pack", isDirectory: true))
        let loose = try writeImage("loose.png", in: directory)

        let outcome = InputExpansion.expand([directory.appendingPathComponent("pack"), loose])
        XCTAssertEqual(
            outcome.files.map(\.lastPathComponent), ["inside.png", "loose.png"],
            "文件夹里的排在前面，显式文件按给定顺序跟在后面"
        )
    }

    func testMissingPathsAreReportedAsSkipped() throws {
        let missing = directory.appendingPathComponent("nope.png")
        let outcome = InputExpansion.expand([missing])
        XCTAssertTrue(outcome.files.isEmpty)
        XCTAssertEqual(outcome.skipped.count, 1)
    }
}
