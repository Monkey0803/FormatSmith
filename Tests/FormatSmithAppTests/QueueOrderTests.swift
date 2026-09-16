import AppKit
import FormatSmithCore
import XCTest
@testable import FormatSmith

/// 队列顺序：身份证正反面谁在上面，完全由列表顺序决定，所以顺序必须能改、也必须真的生效。
@MainActor
final class QueueOrderTests: XCTestCase {

    private var directory: URL!
    private var output: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormatSmithOrderTests-\(UUID().uuidString)", isDirectory: true)
        output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removeObject(forKey: "FormatSmith.settings.v2")
    }

    private func makeImage(_ colour: (r: Double, g: Double, b: Double), name: String) throws -> URL {
        let context = try BitmapContext.make(width: 600, height: 380, wantsAlpha: false)
        context.setFillColor(
            CGColor(
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [colour.r, colour.g, colour.b, 1]
            )!
        )
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 380))
        let image = try XCTUnwrap(context.makeImage())
        let url = directory.appendingPathComponent("\(name).png")
        try ImageEncoder.encode(image, format: .png, quality: 1).write(to: url)
        return url
    }

    private func makeModel(with urls: [URL]) async throws -> ConverterModel {
        let model = ConverterModel()
        model.settings.target = .pdf
        model.settings.pdfLayout = .twoPerPage
        model.settings.pdfPageSize = .a4
        model.settings.mergeImagesIntoOnePDF = true
        model.settings.outputDirectoryPath = output.path
        model.settings.perFileSubfolder = false
        model.settings.filenamePattern = "scan"
        model.add(urls: urls)

        // 等元信息读完，否则转换会跳过这些文件
        let deadline = Date().addingTimeInterval(20)
        while model.convertibleItems.count < urls.count, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return model
    }

    private func convert(_ model: ConverterModel) async throws -> URL {
        model.startConversion()
        let deadline = Date().addingTimeInterval(30)
        while model.isConverting, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let pdf = output.appendingPathComponent("scan.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path), "没有产出 PDF")
        return pdf
    }

    /// 取一点的颜色（y 从上往下数）。测试目标之间不能互相 import，所以自己读像素。
    private func colour(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard
            let context = CGContext(
                data: &data, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return (0, 0, 0) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let index = (y * image.width + x) * 4
        return (Int(data[index]), Int(data[index + 1]), Int(data[index + 2]))
    }

    private func isRed(_ c: (r: Int, g: Int, b: Int)) -> Bool {
        c.r > 170 && c.g < 130 && c.b < 130
    }

    private func isBlue(_ c: (r: Int, g: Int, b: Int)) -> Bool {
        c.b > 170 && c.r < 120
    }

    /// 把 PDF 渲染出来，取上下两半的中心颜色。
    private func halves(of pdf: URL) throws -> (top: (r: Int, g: Int, b: Int), bottom: (r: Int, g: Int, b: Int)) {
        let document = try XCTUnwrap(PDFRasterizer.open(pdf))
        let page = try XCTUnwrap(document.page(at: 1))
        let image = try PDFRasterizer.render(
            page: page, scale: 1, background: .white, keepsAlpha: false, maxPixels: 40_000_000
        )
        return (
            colour(image, x: image.width / 2, y: image.height / 4),
            colour(image, x: image.width / 2, y: image.height * 3 / 4)
        )
    }

    func testFirstFileInTheListGoesOnTop() async throws {
        let red = try makeImage((0.9, 0.2, 0.2), name: "front")
        let blue = try makeImage((0.1, 0.4, 0.9), name: "back")
        let model = try await makeModel(with: [red, blue])

        let pdf = try await convert(model)
        let (top, bottom) = try halves(of: pdf)

        XCTAssertTrue(isRed(top), "第一张（正）应在上半页，实际 \(top)")
        XCTAssertTrue(isBlue(bottom), "第二张（反）应在下半页，实际 \(bottom)")
    }

    func testMovingAnItemUpSwapsTheOrderInTheOutput() async throws {
        let red = try makeImage((0.9, 0.2, 0.2), name: "front")
        let blue = try makeImage((0.1, 0.4, 0.9), name: "back")
        let model = try await makeModel(with: [red, blue])

        // 加反了：把第二张（反）挪到前面
        let backID = try XCTUnwrap(model.items.last?.id)
        XCTAssertTrue(model.canMoveUp(id: backID))
        model.moveUp(id: backID)
        XCTAssertEqual(model.items.first?.name, "back", "上移后列表顺序应改变")

        let pdf = try await convert(model)
        let (top, bottom) = try halves(of: pdf)

        XCTAssertTrue(isBlue(top), "上移之后反应该在上面，实际 \(top)")
        XCTAssertTrue(isRed(bottom), "正应该在下面，实际 \(bottom)")
    }

    func testMoveBoundaries() async throws {
        let first = try makeImage((0.9, 0.2, 0.2), name: "a")
        let second = try makeImage((0.1, 0.4, 0.9), name: "b")
        let model = try await makeModel(with: [first, second])

        let firstID = try XCTUnwrap(model.items.first?.id)
        let lastID = try XCTUnwrap(model.items.last?.id)

        XCTAssertFalse(model.canMoveUp(id: firstID), "第一项不能再上移")
        XCTAssertFalse(model.canMoveDown(id: lastID), "最后一项不能再下移")
        XCTAssertTrue(model.canMoveUp(id: lastID))
        XCTAssertTrue(model.canMoveDown(id: firstID))

        // 越界调用应当是无操作，而不是崩溃或打乱顺序
        model.moveUp(id: firstID)
        model.moveDown(id: lastID)
        XCTAssertEqual(model.items.map(\.name), ["a", "b"])
    }
}
