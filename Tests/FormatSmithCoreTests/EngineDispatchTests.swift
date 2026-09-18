import CoreGraphics
import Foundation
import XCTest
@testable import FormatSmithCore

/// `ConversionEngine.run` 是唯一的分派入口。
///
/// 合并成一个 PDF、整批走 PDF 工具箱、还是逐个转换，以前在界面和命令行里各判断一遍；
/// 两处一旦分叉，同一组文件在两个入口就会得到不同结果。这一组把分派契约钉死。
final class EngineDispatchTests: XCTestCase {

    private var directory: URL!
    private var output: URL!

    override func setUpWithError() throws {
        directory = try FixtureFactory.makeTemporaryDirectory()
        output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func settings(_ configure: (inout ConversionSettings) -> Void = { _ in }) -> ConversionSettings {
        var settings = ConversionSettings()
        settings.outputDirectoryPath = output.path
        settings.perFileSubfolder = false
        settings.filenamePattern = "{name}"
        configure(&settings)
        return settings
    }

    private func images(_ count: Int) throws -> [SourceDocument] {
        try (1...count).map { index in
            SourceDocument.make(
                from: try FixtureFactory.makeImage(
                    width: 200, height: 150, named: "img\(index)", in: directory
                )
            )
        }
    }

    private func documents(_ count: Int) throws -> [SourceDocument] {
        try (1...count).map { index in
            SourceDocument.make(
                from: try FixtureFactory.makePDF(pages: 2, named: "doc\(index)", in: directory)
            )
        }
    }

    // MARK: - 合并

    func testSeveralImagesWithMergeBecomeOneResult() async throws {
        let settings = settings {
            $0.target = .pdf
            $0.mergeImagesIntoOnePDF = true
            $0.pdfPageSize = .fitImage
        }

        let documents = try images(3)
        let results = await ConversionEngine.run(
            documents: documents, target: settings.target, settings: settings, cancellation: CancellationFlag()
        )

        XCTAssertEqual(results.count, 1, "合并之后只有一份产出")
        XCTAssertEqual(results[0].includedDocumentIDs.count, 3, "结果要记住参与的三个输入")

        let pdf = try PDFRasterizer.open(try XCTUnwrap(results[0].outputFiles.first))
        XCTAssertEqual(pdf.numberOfPages, 3, "三张图三页")
    }

    func testSeveralImagesWithoutMergeStaySeparate() async throws {
        let settings = settings {
            $0.target = .pdf
            $0.mergeImagesIntoOnePDF = false
        }

        let results = await ConversionEngine.run(
            documents: try images(3), target: settings.target, settings: settings,
            cancellation: CancellationFlag()
        )

        XCTAssertEqual(results.count, 3, "关掉合并就是每个文件一份")
        for result in results {
            XCTAssertEqual(result.includedDocumentIDs.count, 1)
        }
    }

    func testSingleImageIsNotTreatedAsAMerge() async throws {
        let settings = settings { $0.target = .pdf }

        let results = await ConversionEngine.run(
            documents: try images(1), target: settings.target, settings: settings,
            cancellation: CancellationFlag()
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].includedDocumentIDs.count, 1, "一张图不算合并")
    }

    // MARK: - PDF 工具箱

    func testWholeBatchToolProducesOneResult() async throws {
        // 合并 PDF：整批当一件事做（工具箱要求进 PDF、出 PDF）
        let settings = settings {
            $0.target = .pdf
            $0.pdfTool = .merge
        }

        let documents = try documents(2)
        let results = await ConversionEngine.run(
            documents: documents, target: settings.target, settings: settings, cancellation: CancellationFlag()
        )

        XCTAssertEqual(results.count, 1, "合并 PDF 应当只有一份产出")
        XCTAssertEqual(results[0].includedDocumentIDs.count, 2)
    }

    func testPerFileToolProducesOneResultPerDocument() async throws {
        // 旋转是逐个文件做的
        let settings = settings {
            $0.target = .pdf
            $0.pdfTool = .rotate
            $0.rotationAngle = .clockwise90
        }

        let results = await ConversionEngine.run(
            documents: try documents(2), target: settings.target, settings: settings,
            cancellation: CancellationFlag()
        )

        XCTAssertEqual(results.count, 2, "旋转应当每个文件一份")

        var pages = 0
        for result in results {
            XCTAssertEqual(result.includedDocumentIDs.count, 1)
            pages += try PDFRasterizer.open(try XCTUnwrap(result.outputFiles.first)).numberOfPages
        }
        XCTAssertEqual(pages, 4, "两个两页的 PDF 旋转后还是四页")
    }

    // MARK: - 逐个转换

    func testImagesToImagesProducesOneResultPerImage() async throws {
        let settings = settings { $0.target = .image(.jpeg) }

        let results = await ConversionEngine.run(
            documents: try images(4), target: settings.target, settings: settings,
            cancellation: CancellationFlag()
        )

        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results.filter { $0.error == nil }.count, 4)
    }

    func testMixedInputsFallBackToPerFile() async throws {
        // 一批里既有 PDF 又有图片，无法用单一管线描述，应当逐个处理
        var all = try images(1)
        all.append(contentsOf: try documents(1))

        let settings = settings { $0.target = .pdf }
        let results = await ConversionEngine.run(
            documents: all, target: settings.target, settings: settings, cancellation: CancellationFlag()
        )

        XCTAssertEqual(results.count, 2, "混合输入逐个转换")
    }

    // MARK: - 空输入与观察者

    func testEmptyInputProducesNothing() async throws {
        let settings = settings()
        let results = await ConversionEngine.run(
            documents: [], target: settings.target, settings: settings, cancellation: CancellationFlag()
        )
        XCTAssertTrue(results.isEmpty)
    }

    func testObserverSeesEveryResult() async throws {
        // 关掉合并，让三个文件各自产出一条结果
        let settings = settings {
            $0.target = .pdf
            $0.mergeImagesIntoOnePDF = false
        }

        let counter = ResultCounter()
        let observer = ConversionObserver(onFileFinished: { _ in counter.increment() })

        let results = await ConversionEngine.run(
            documents: try images(3), target: settings.target, settings: settings,
            cancellation: CancellationFlag(), observer: observer
        )

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(counter.count, 3, "每条结果都应当通知观察者")
    }

    func testCancellationIsReportedAsFailure() async throws {
        let settings = settings { $0.target = .pdf }
        let flag = CancellationFlag()
        flag.cancel()

        let results = await ConversionEngine.run(
            documents: try images(2), target: settings.target, settings: settings, cancellation: flag
        )
        XCTAssertTrue(results.allSatisfy { $0.error != nil }, "取消后不应当报成功")
    }

    private final class ResultCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }
}
