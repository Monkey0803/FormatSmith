import AppKit
import FormatSmithCore
import XCTest
@testable import FormatSmith

/// 批次结果汇总与失败重试。
///
/// 批量转换里失败常常只是个例，用户需要知道「哪几个、为什么」，并且能只重跑那几个。
@MainActor
final class BatchSummaryTests: XCTestCase {

    private var directory: URL!
    private var output: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormatSmithSummaryTests-\(UUID().uuidString)", isDirectory: true)
        output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removeObject(forKey: "FormatSmith.settings.v2")
    }

    private func makeImageFile(name: String, width: Int = 200, height: Int = 150) throws -> URL {
        let context = try BitmapContext.make(width: width, height: height, wantsAlpha: false)
        context.fill(with: .white)
        let image = try XCTUnwrap(context.makeImage())
        let url = directory.appendingPathComponent("\(name).png")
        try ImageEncoder.encode(image, format: .png, quality: 1).write(to: url)
        return url
    }

    private func makeModel() -> ConverterModel {
        let model = ConverterModel()
        model.settings.outputDirectoryPath = output.path
        model.settings.perFileSubfolder = false
        model.settings.filenamePattern = "{name}"
        return model
    }

    private func load(_ model: ConverterModel, _ count: Int, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.convertibleItems.count < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(model.convertibleItems.count, count, "文件没有被识别为可转换")
    }

    private func run(_ model: ConverterModel, timeout: TimeInterval = 40) async throws {
        model.startConversion()
        let deadline = Date().addingTimeInterval(timeout)
        while model.isConverting, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(model.isConverting, "转换没有在预期时间内结束")
    }

    // MARK: - 汇总

    func testSummaryReportsSuccessesAndOutputCount() async throws {
        let first = try makeImageFile(name: "a")
        let second = try makeImageFile(name: "b")
        let model = makeModel()

        model.add(urls: [first, second])
        try await load(model, 2)
        try await run(model)

        let summary = try XCTUnwrap(model.batchSummary, "跑完应当有汇总")
        XCTAssertEqual(summary.succeeded, 2)
        XCTAssertEqual(summary.outputCount, 2)
        XCTAssertFalse(summary.hasFailures)
        XCTAssertEqual(summary.outputFolder?.path, output.path)
    }

    func testSummaryNamesTheFailingFileAndItsReason() async throws {
        // 探测通过之后再删文件，这样失败会发生在转换阶段而不是入队阶段
        let good = try makeImageFile(name: "good")
        let doomed = try makeImageFile(name: "doomed")
        let model = makeModel()

        model.add(urls: [good, doomed])
        try await load(model, 2)
        try FileManager.default.removeItem(at: doomed)
        try await run(model)

        let summary = try XCTUnwrap(model.batchSummary)
        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertEqual(summary.failures.count, 1)

        let failure = try XCTUnwrap(summary.failures.first)
        XCTAssertEqual(failure.name, "doomed", "汇总里要写出是哪个文件")
        XCTAssertFalse(failure.message.isEmpty, "汇总里要给出失败原因")
    }

    func testSummaryClearedWhenANewRunStarts() async throws {
        let url = try makeImageFile(name: "a")
        let model = makeModel()
        model.add(urls: [url])
        try await load(model, 1)
        try await run(model)
        XCTAssertNotNil(model.batchSummary)

        model.startConversion()
        // 开跑瞬间就该清掉上一轮的汇总，避免用户以为那是这次的结果
        XCTAssertNil(model.batchSummary, "新一轮开始时上一轮汇总应当消失")
    }

    func testDismissClearsTheSummary() async throws {
        let url = try makeImageFile(name: "a")
        let model = makeModel()
        model.add(urls: [url])
        try await load(model, 1)
        try await run(model)

        model.dismissBatchSummary()
        XCTAssertNil(model.batchSummary)
    }

    // MARK: - 重试

    func testRetryRerunsOnlyTheFailedItem() async throws {
        let good = try makeImageFile(name: "good")
        let doomed = try makeImageFile(name: "doomed")
        let model = makeModel()

        model.add(urls: [good, doomed])
        try await load(model, 2)
        try FileManager.default.removeItem(at: doomed)
        try await run(model)
        XCTAssertEqual(model.batchSummary?.failures.count, 1)

        // 判断「只重跑了失败项」的办法：把已经成功的那个文件也删掉。
        // 如果重试又把 good 跑了一遍，它会失败；只跑 doomed 的话 good 保持成功状态不动。
        try FileManager.default.removeItem(at: good)
        _ = try makeImageFile(name: "doomed")

        model.retryFailedItems()
        try await run(model)

        let summary = try XCTUnwrap(model.batchSummary)
        XCTAssertFalse(summary.hasFailures, "补回文件后重试应当成功；若 good 被重跑会再次失败")
        XCTAssertEqual(summary.succeeded, 2, "队列里两项现在都是成功的")

        let written = try FileManager.default.contentsOfDirectory(atPath: output.path)
        XCTAssertTrue(written.contains { $0.hasPrefix("good") })
        XCTAssertTrue(written.contains { $0.hasPrefix("doomed") })
    }

    func testRetryDoesNothingWithoutFailures() async throws {
        let url = try makeImageFile(name: "a")
        let model = makeModel()
        model.add(urls: [url])
        try await load(model, 1)
        try await run(model)

        model.retryFailedItems()
        XCTAssertFalse(model.isConverting, "没有失败项时重试应当什么都不做")
        XCTAssertEqual(model.batchSummary?.succeeded, 1)
    }

    // MARK: - 拖拽

    func testFinishedItemCarriesItsOutputFilesForDragging() async throws {
        let url = try makeImageFile(name: "a")
        let model = makeModel()
        model.add(urls: [url])
        try await load(model, 1)
        try await run(model)

        let item = try XCTUnwrap(model.items.first)
        guard case let .finished(files, _, outputs, _) = item.status else {
            return XCTFail("完成状态应当记录产出文件，否则没法把结果拖出去")
        }
        XCTAssertEqual(files, 1)
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs.first?.pathExtension, "png")
    }
}

/// 队列在完成后要能报出「产出多大」。
///
/// 用户最关心的往往就是压缩效果：源文件多大、产出多大。
@MainActor
final class OutputSizeTests: XCTestCase {

    func testFinishedItemCarriesTheOutputSize() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormatSmithSize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.removeObject(forKey: "FormatSmith.settings.v2")
        }

        // 造一张有内容的图，保证产出不是 0 字节
        let context = try BitmapContext.make(width: 800, height: 600, wantsAlpha: false)
        for index in stride(from: 0, to: 800, by: 40) {
            context.setFillColor(
                CGColor(red: Double(index) / 800.0, green: 0.4, blue: 0.6, alpha: 1)
            )
            context.fill(CGRect(x: index, y: 0, width: 20, height: 600))
        }
        let image = try XCTUnwrap(context.makeImage())
        let source = directory.appendingPathComponent("stripes.png")
        try ImageEncoder.encode(image, format: .png, quality: 1).write(to: source)

        let model = ConverterModel()
        model.settings.outputDirectoryPath = directory.appendingPathComponent("out").path
        model.settings.format = .jpeg
        model.settings.quality = 0.5
        model.add(urls: [source])

        let ready = Date().addingTimeInterval(20)
        while model.convertibleItems.isEmpty, Date() < ready {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        model.startConversion()
        let deadline = Date().addingTimeInterval(60)
        while model.isConverting, Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        let item = try XCTUnwrap(model.items.first)
        guard case let .finished(_, _, outputs, bytes) = item.status else {
            return XCTFail("应当是完成状态，实际 \(item.status)")
        }
        XCTAssertFalse(outputs.isEmpty, "应当记录产出文件")
        XCTAssertGreaterThan(bytes, 0, "应当记录产出的实际字节数")

        // 与磁盘上的真实大小一致
        let onDisk = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: outputs[0].path)[.size]) as? NSNumber
        ).int64Value
        XCTAssertEqual(bytes, onDisk, "报出来的大小必须等于磁盘上的真实大小")
    }
}
