import Foundation
import XCTest
@testable import FormatSmithCore

/// 输出名必须**原子地**占住，否则并发转换会互相覆盖。
///
/// 这是压力测试量出来的真问题：500 个文件用固定模板转换，
/// 每一次都报告成功，磁盘上却只有 322 个 —— 其余被并发任务悄悄覆盖掉了。
/// 根因是 `uniqueURL` 采用「查一下不存在就返回」，多个任务同时算出同一个空位。
final class OutputNamingRaceTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormatSmithNaming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        OutputNaming.resetReservations()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        OutputNaming.resetReservations()
    }

    /// 并发抢同一个基名：必须人人不同，且每个名字都真的能写。
    func testConcurrentReservationsAllGetDistinctPaths() async throws {
        let base = directory.appendingPathComponent("out.jpg")
        let count = 200

        let urls = await withTaskGroup(of: URL.self) { group in
            for _ in 0..<count {
                group.addTask {
                    OutputNaming.uniqueURL(base)
                }
            }
            var collected: [URL] = []
            for await url in group { collected.append(url) }
            return collected
        }

        XCTAssertEqual(urls.count, count)
        let distinct = Set(urls.map(\.lastPathComponent))
        XCTAssertEqual(
            distinct.count, count,
            "并发占位出现了重名：\(count) 次只拿到 \(distinct.count) 个不同名字 —— 会互相覆盖"
        )

        // 每个名字都要能被真正写入（占位留下的空文件应当可写）
        for url in urls {
            try Data("x".utf8).write(to: url)
            let size = try XCTUnwrap(
                (try FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
            ).intValue
            XCTAssertEqual(size, 1, "\(url.lastPathComponent) 没有被真正写入")
        }
    }

    /// 不冲突时保持原名，不无端加后缀。
    func testFreeNameIsKeptAsIs() {
        let url = directory.appendingPathComponent("fresh.png")
        XCTAssertEqual(OutputNaming.uniqueURL(url).lastPathComponent, "fresh.png")
    }

    /// 已有文件绝不被覆盖 —— 这是这个函数存在的理由。
    func testExistingFileIsNeverReused() throws {
        let existing = directory.appendingPathComponent("taken.png")
        try Data("original".utf8).write(to: existing)

        let chosen = OutputNaming.uniqueURL(existing)
        XCTAssertNotEqual(chosen.lastPathComponent, "taken.png")
        XCTAssertEqual(
            try String(contentsOf: existing, encoding: .utf8), "original",
            "原有文件被改动了"
        )
    }

    func testSuffixesIncrease() throws {
        let base = directory.appendingPathComponent("dup.png")
        try Data().write(to: base)
        try Data().write(to: directory.appendingPathComponent("dup-1.png"))

        let chosen = OutputNaming.uniqueURL(base)
        XCTAssertEqual(chosen.lastPathComponent, "dup-2.png")
    }
}
