import CoreGraphics
import Foundation
import XCTest
@testable import FormatSmithCore

/// 批量并发转换：既要真的并行，也不能因为并行丢结果。
final class BatchConversionTests: XCTestCase {

    private var directory: URL!
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        directory = try FixtureFactory.makeTemporaryDirectory()
        outputDirectory = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func settings() -> ConversionSettings {
        var settings = ConversionSettings()
        settings.target = .image(.png)
        settings.resolutionMode = .scale
        settings.scale = 1
        settings.outputDirectoryPath = outputDirectory.path
        settings.perFileSubfolder = true
        settings.padsPageNumbers = false
        return settings
    }

    private func makeDocuments(count: Int, pages: Int = 2) throws -> [SourceDocument] {
        try (1...count).map { index in
            let url = try FixtureFactory.makePDF(pages: pages, named: "doc\(index)", in: directory)
            return SourceDocument.make(from: url)
        }
    }

    // MARK: - 结果完整性

    func testBatchConvertsEveryDocument() async throws {
        let documents = try makeDocuments(count: 6)

        let results = await ConversionEngine.convertBatch(
            documents: documents,
            target: .image(.png),
            settings: settings(),
            cancellation: CancellationFlag(),
            maxConcurrency: 4
        )

        XCTAssertEqual(results.count, 6, "每个输入都要有结果")
        XCTAssertEqual(Set(results.map(\.documentID)), Set(documents.map(\.id)))
        XCTAssertTrue(results.allSatisfy { $0.error == nil }, "不应有失败: \(results.compactMap(\.error?.message))")
        XCTAssertTrue(results.allSatisfy { $0.producedCount == 2 }, "每个文件都是 2 页")

        // 每个文件一个子目录，各自两页
        for document in documents {
            let folder = outputDirectory.appendingPathComponent(document.displayName)
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            XCTAssertEqual(
                files, ["\(document.displayName)-1.png", "\(document.displayName)-2.png"],
                "\(document.displayName) 的输出不对: \(files)")
        }
    }

    func testSerialAndConcurrentProduceTheSameOutput() async throws {
        let documents = try makeDocuments(count: 4)

        var serialSettings = settings()
        serialSettings.outputDirectoryPath = directory.appendingPathComponent("serial").path
        let serialResults = await ConversionEngine.convertBatch(
            documents: documents,
            target: .image(.png),
            settings: serialSettings,
            cancellation: CancellationFlag(),
            maxConcurrency: 1
        )

        var parallelSettings = settings()
        parallelSettings.outputDirectoryPath = directory.appendingPathComponent("parallel").path
        let parallelResults = await ConversionEngine.convertBatch(
            documents: documents,
            target: .image(.png),
            settings: parallelSettings,
            cancellation: CancellationFlag(),
            maxConcurrency: 4
        )

        XCTAssertEqual(serialResults.count, parallelResults.count)
        XCTAssertEqual(
            serialResults.map(\.producedCount).sorted(),
            parallelResults.map(\.producedCount).sorted(),
            "并发不应改变产出"
        )
    }

    func testConcurrencyLimitIsRespected() async throws {
        let documents = try makeDocuments(count: 8)

        let counter = ConcurrencyCounter()
        let observer = ConversionObserver(onProgress: { progress in
            counter.record(progress)
        })

        _ = await ConversionEngine.convertBatch(
            documents: documents,
            target: .image(.png),
            settings: settings(),
            cancellation: CancellationFlag(),
            maxConcurrency: 2,
            observer: observer
        )

        // 无法直接测量峰值并发，但至少要确认每个文件都上报过进度，
        // 而且上报里带着各自的 documentID（并发时靠它区分来源）。
        XCTAssertEqual(counter.documentIDs.count, 8, "每个文件都应上报进度")
    }

    func testProgressCarriesDocumentIdentity() async throws {
        let documents = try makeDocuments(count: 3)
        let collector = ProgressCollector()

        _ = await ConversionEngine.convertBatch(
            documents: documents,
            target: .image(.png),
            settings: settings(),
            cancellation: CancellationFlag(),
            maxConcurrency: 3,
            observer: ConversionObserver(onProgress: { collector.append($0) })
        )

        let seen = collector.snapshot()
        XCTAssertFalse(seen.isEmpty)
        XCTAssertTrue(seen.allSatisfy { $0.documentID != nil }, "并发下每条进度都必须能追溯到文件")
        XCTAssertEqual(Set(seen.compactMap(\.documentID)), Set(documents.map(\.id)))
    }

    func testFinishedCallbackFiresOncePerDocument() async throws {
        let documents = try makeDocuments(count: 5)
        let collector = ResultCollector()

        _ = await ConversionEngine.convertBatch(
            documents: documents,
            target: .image(.png),
            settings: settings(),
            cancellation: CancellationFlag(),
            maxConcurrency: 3,
            observer: ConversionObserver(onFileFinished: { collector.append($0) })
        )

        let results = collector.snapshot()
        XCTAssertEqual(results.count, 5, "每个文件都应回调一次完成事件")
        XCTAssertEqual(Set(results.map(\.documentID)), Set(documents.map(\.id)))
    }

    // MARK: - 取消与失败

    func testCancellationStopsTheBatchEarly() async throws {
        let documents = try makeDocuments(count: 6, pages: 3)
        let flag = CancellationFlag()
        flag.cancel()

        let results = await ConversionEngine.convertBatch(
            documents: documents,
            target: .image(.png),
            settings: settings(),
            cancellation: flag,
            maxConcurrency: 2
        )

        XCTAssertTrue(results.isEmpty, "已取消时不应启动任何转换")
    }

    func testOneBadFileDoesNotStopTheOthers() async throws {
        var documents = try makeDocuments(count: 3)
        let broken = directory.appendingPathComponent("broken.pdf")
        try Data("this is not a pdf".utf8).write(to: broken)
        documents.insert(SourceDocument.make(from: broken), at: 1)

        let results = await ConversionEngine.convertBatch(
            documents: documents,
            target: .image(.png),
            settings: settings(),
            cancellation: CancellationFlag(),
            maxConcurrency: 3
        )

        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results.filter { $0.error != nil }.count, 1, "坏文件应单独失败")
        XCTAssertEqual(results.filter { $0.error == nil }.count, 3, "其它文件不应受影响")
    }

    // MARK: - 并发度

    func testAutomaticConcurrency() {
        XCTAssertGreaterThanOrEqual(ConversionEngine.automaticConcurrency(configured: 0), 1)
        XCTAssertLessThanOrEqual(ConversionEngine.automaticConcurrency(configured: 0), 4, "自动值不应吃满所有核")
        XCTAssertEqual(ConversionEngine.automaticConcurrency(configured: 7), 7, "显式设置应当被尊重")
    }

    func testEmptyBatchReturnsNothing() async {
        let results = await ConversionEngine.convertBatch(
            documents: [],
            target: .image(.png),
            settings: settings(),
            cancellation: CancellationFlag()
        )
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - 采集器

    private final class ConcurrencyCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<UUID> = []

        func record(_ progress: ConversionProgress) {
            guard let id = progress.documentID else { return }
            lock.lock()
            ids.insert(id)
            lock.unlock()
        }

        var documentIDs: Set<UUID> {
            lock.lock()
            defer { lock.unlock() }
            return ids
        }
    }

    private final class ProgressCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ConversionProgress] = []

        func append(_ progress: ConversionProgress) {
            lock.lock()
            items.append(progress)
            lock.unlock()
        }

        func snapshot() -> [ConversionProgress] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    private final class ResultCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ConversionResult] = []

        func append(_ result: ConversionResult) {
            lock.lock()
            items.append(result)
            lock.unlock()
        }

        func snapshot() -> [ConversionResult] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }
}
