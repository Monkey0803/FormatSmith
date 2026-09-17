import AppKit
import FormatSmithCore
import XCTest
@testable import FormatSmith

/// 预览的接线：从「队列里有文件」到「预览图出现」这条链路容易被改断，
/// 因为它跨了 元信息异步加载 → 防抖 → 后台渲染 → 回主线程 四步。
@MainActor
final class PreviewWiringTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormatSmithPreviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removeObject(forKey: "FormatSmith.settings.v2")
    }

    /// 用 Core 的公开 API 造素材：测试目标之间不能互相 import，
    /// 所以这里不复用 Core 测试里的 FixtureFactory。
    private func makeImageFile(width: Int = 400, height: Int = 300, name: String = "image") throws -> URL {
        let context = try BitmapContext.make(width: width, height: height, wantsAlpha: false)
        context.fill(with: .white)
        let image = try XCTUnwrap(context.makeImage())
        let url = directory.appendingPathComponent("\(name).png")
        try ImageEncoder.encode(image, format: .png, quality: 1).write(to: url)
        return url
    }

    private func makePDFFile(name: String = "doc", pages: Int = 2) throws -> URL {
        let context = try BitmapContext.make(width: 300, height: 400, wantsAlpha: false)
        context.fill(with: .white)
        let image = try XCTUnwrap(context.makeImage())
        let urls = try (0..<pages).map { _ in
            let url = directory.appendingPathComponent("page-\(UUID().uuidString).png")
            try ImageEncoder.encode(image, format: .png, quality: 1).write(to: url)
            return url
        }
        let images = try urls.map { url -> CGImage in
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        return try PDFComposer.compose(
            images: images,
            settings: ConversionSettings(),
            to: directory.appendingPathComponent("\(name).pdf")
        )
    }

    private func waitForPreview(_ model: ConverterModel, timeout: TimeInterval = 20) async throws -> NSImage {
        let deadline = Date().addingTimeInterval(timeout)
        while model.outputPreview.image == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return try XCTUnwrap(
            model.outputPreview.image,
            "预览始终没有生成（渲染中=\(model.outputPreview.isRendering)，失败=\(model.outputPreview.failure ?? "无")）"
        )
    }

    private func waitForImageCount(_ model: ConverterModel, _ count: Int, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.convertibleItems.count < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func makeModel() -> ConverterModel {
        let model = ConverterModel()
        model.settings.outputDirectoryPath = directory.path
        return model
    }

    // MARK: - 图片 → 图片

    func testPreviewAppearsForAnImageInput() async throws {
        let url = try makeImageFile(width: 600, height: 800)
        let model = makeModel()

        model.add(urls: [url])
        let image = try await waitForPreview(model)

        XCTAssertEqual(Int(image.size.width.rounded()), 600)
        XCTAssertEqual(Int(image.size.height.rounded()), 800)
        XCTAssertEqual(model.outputPreview.caption, "600 × 800 px")
    }

    // MARK: - 证件照

    func testIDPhotoPreviewFollowsTheSpec() async throws {
        let url = try makeImageFile(width: 1200, height: 1600)
        let model = makeModel()
        model.settings.idPhotoEnabled = true
        model.settings.idPhotoSize = .oneInch
        model.settings.idPhotoBackground = .white
        model.settings.dpi = 300

        model.add(urls: [url])
        let image = try await waitForPreview(model)

        XCTAssertEqual(Int(image.size.width.rounded()), 295)
        XCTAssertEqual(Int(image.size.height.rounded()), 413)
    }

    // MARK: - 图片 → PDF

    func testPreviewAppearsForPDFTarget() async throws {
        let url = try makeImageFile(width: 600, height: 400)
        let model = makeModel()
        model.settings.target = .pdf
        model.settings.pdfPageSize = .fitImage
        model.settings.mergeImagesIntoOnePDF = true

        model.add(urls: [url])
        _ = try await waitForPreview(model)

        XCTAssertEqual(model.outputPreview.kind, .pdfPage)
        XCTAssertEqual(model.outputPreview.caption, "600 × 400 pt", "跟随图片时页面就是图片的磅值")
    }

    func testMergedPDFPreviewCountsPages() async throws {
        let first = try makeImageFile(width: 600, height: 400, name: "a")
        let second = try makeImageFile(width: 600, height: 400, name: "b")
        let model = makeModel()
        model.settings.target = .pdf
        model.settings.pdfLayout = .twoPerPage
        model.settings.pdfPageSize = .a4
        model.settings.mergeImagesIntoOnePDF = true

        model.add(urls: [first, second])
        try await waitForImageCount(model, 2)
        _ = try await waitForPreview(model)

        XCTAssertEqual(model.outputPreview.pageCount, 1, "两张图一页")
        XCTAssertEqual(model.outputPreview.caption, "595 × 842 pt")
    }

    // MARK: - PDF → 图片

    func testPreviewAppearsForPDFInput() async throws {
        let pdf = try makePDFFile(pages: 2)
        let model = makeModel()
        model.settings.resolutionMode = .dpi
        model.settings.dpi = 144  // 2 倍

        model.add(urls: [pdf])
        let image = try await waitForPreview(model)

        XCTAssertEqual(model.outputPreview.kind, .renderedPage)
        XCTAssertEqual(Int(image.size.width.rounded()), 600, "300pt × 2")
        XCTAssertEqual(model.outputPreview.pageCount, 2)
        XCTAssertEqual(model.outputPreview.fileCount, 2)
    }

    // MARK: - 清理

    func testPreviewIsClearedWhenTheQueueIsEmptied() async throws {
        let url = try makeImageFile()
        let model = makeModel()
        model.add(urls: [url])
        _ = try await waitForPreview(model)

        model.removeAll()

        let deadline = Date().addingTimeInterval(5)
        while !model.outputPreview.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(model.outputPreview.isEmpty, "队列清空后预览应当消失")
    }

    func testPreviewRefreshesWhenSettingsChange() async throws {
        let url = try makeImageFile(width: 600, height: 400)
        let model = makeModel()
        model.add(urls: [url])
        _ = try await waitForPreview(model)
        XCTAssertEqual(model.outputPreview.caption, "600 × 400 px")

        model.settings.scale = 0.5

        let deadline = Date().addingTimeInterval(10)
        while model.outputPreview.caption != "300 × 200 px", Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(model.outputPreview.caption, "300 × 200 px", "改了倍数之后预览应当跟着变")
    }
}
