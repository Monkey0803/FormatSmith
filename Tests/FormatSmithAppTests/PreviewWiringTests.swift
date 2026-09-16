import AppKit
import FormatSmithCore
import XCTest
@testable import FormatSmith

/// 预览的接线：从「队列里有图片」到「预览图出现」这条链路容易被改断，
/// 因为它跨了 元信息异步加载 → 防抖 → 后台分析 → 回主线程 四步。
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
    private func makeImageFile(width: Int, height: Int, name: String) throws -> URL {
        let context = try BitmapContext.make(width: width, height: height, wantsAlpha: false)
        context.fill(with: .white)
        let image = try XCTUnwrap(context.makeImage())
        let url = directory.appendingPathComponent("\(name).png")
        try ImageEncoder.encode(image, format: .png, quality: 1).write(to: url)
        return url
    }

    private func makePDFFile(name: String) throws -> URL {
        let context = try BitmapContext.make(width: 300, height: 400, wantsAlpha: false)
        context.fill(with: .white)
        let image = try XCTUnwrap(context.makeImage())
        return try PDFComposer.compose(
            images: [image],
            settings: ConversionSettings(),
            to: directory.appendingPathComponent("\(name).pdf")
        )
    }

    private func waitForPreview(_ model: ConverterModel, timeout: TimeInterval = 20) async throws -> NSImage {
        let deadline = Date().addingTimeInterval(timeout)
        while model.idPhotoPreview.photo == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return try XCTUnwrap(
            model.idPhotoPreview.photo,
            "预览始终没有生成（调度=\(model.idPhotoPreview.isRendering)，失败=\(model.idPhotoPreview.failure ?? "无")）"
        )
    }

    private func makeModel(idPhoto: Bool, sheet: Bool = false) -> ConverterModel {
        let model = ConverterModel()
        model.settings.idPhotoEnabled = idPhoto
        model.settings.resolutionMode = .dpi
        model.settings.dpi = 300
        model.settings.idPhotoSize = .oneInch
        model.settings.idPhotoBackground = .blue
        model.settings.printSheetEnabled = sheet
        return model
    }

    func testPreviewAppearsForAnImageInput() async throws {
        let imageURL = try makeImageFile(width: 600, height: 800, name: "portrait")
        let model = makeModel(idPhoto: true)

        model.add(urls: [imageURL])
        let photo = try await waitForPreview(model)

        // 预览就是导出尺寸：一寸 @300 DPI
        XCTAssertEqual(Int(photo.size.width.rounded()), 295)
        XCTAssertEqual(Int(photo.size.height.rounded()), 413)
        XCTAssertTrue(model.idPhotoPreview.caption.contains("295"))
    }

    func testPreviewIsClearedWhenIDPhotoModeIsTurnedOff() async throws {
        let imageURL = try makeImageFile(width: 600, height: 800, name: "portrait")
        let model = makeModel(idPhoto: true)
        model.add(urls: [imageURL])
        _ = try await waitForPreview(model)

        model.settings.idPhotoEnabled = false

        let deadline = Date().addingTimeInterval(5)
        while !model.idPhotoPreview.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(model.idPhotoPreview.isEmpty, "关掉证件照模式后预览应当消失")
    }

    func testSheetPreviewIsProducedWhenTilingIsOn() async throws {
        let imageURL = try makeImageFile(width: 600, height: 800, name: "portrait")
        let model = makeModel(idPhoto: true, sheet: true)

        model.add(urls: [imageURL])
        let deadline = Date().addingTimeInterval(20)
        while model.idPhotoPreview.sheet == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let sheet = try XCTUnwrap(model.idPhotoPreview.sheet, "相纸预览没有生成")
        // 6 寸相纸 @300 DPI
        XCTAssertEqual(Int(sheet.size.width.rounded()), 1205)
        XCTAssertEqual(Int(sheet.size.height.rounded()), 1795)
        XCTAssertTrue(model.idPhotoPreview.caption.contains("12"), "六寸相纸应放下 12 张一寸照")
    }

    func testNoPreviewForPDFInput() async throws {
        let pdfURL = try makePDFFile(name: "doc")
        let model = makeModel(idPhoto: true)

        model.add(urls: [pdfURL])
        // 证件照只处理图片输入；给 PDF 时不该出现预览
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertTrue(model.idPhotoPreview.photo == nil, "PDF 输入不应触发证件照预览")
    }
}
