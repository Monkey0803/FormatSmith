import AppKit
import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import FormatSmithCore

/// OCR 中途取消要多久才停。
///
/// 几百页扫描件的识别要跑几分钟，用户按取消之后不能干等。
/// 取消检查点在**每一页**开头，所以响应时间约等于一页的识别耗时 ——
/// 这里把这件事量出来并钉住上限，避免以后有人在页内加了大循环却忘了检查。
final class CancellationResponsivenessTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = try FixtureFactory.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 造一份多页「扫描件」：每页只有像素，没有文字层，必须真识别。
    private func makeScannedPDF(pages: Int) throws -> URL {
        var images: [CGImage] = []
        for index in 0..<pages {
            let url = try FixtureFactory.makeTextImage(
                "Scanned page \(index)", width: 900, height: 300,
                named: "scan\(index)", in: directory
            )
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            images.append(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        }
        return try PDFComposer.compose(
            images: images, settings: ConversionSettings(),
            to: directory.appendingPathComponent("scan.pdf")
        )
    }

    /// 每页「识别」固定花这么久，把时序变成确定的。
    ///
    /// 真跑 Vision 的话 12 页只要 0.75 秒就跑完了 —— 我第一版测试在 1.5 秒才按取消，
    /// 那时任务早已正常结束，于是测出来的「半成品」其实是完整产出。
    /// 用会睡觉的识别器，取消点才落在文档中间。
    private struct SlowRecognizer: TextRecognizing {
        let perPage: UInt64
        func lines(in image: CGImage) throws -> [RecognizedLine] {
            Thread.sleep(forTimeInterval: Double(perPage) / 1_000_000_000)
            return [RecognizedLine(text: "text", bounds: CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.1))]
        }
    }

    func testCancelStopsInsteadOfFinishingTheWholeDocument() async throws {
        let pages = 12
        let perPage: UInt64 = 300_000_000  // 300ms/页 → 整份约 3.6 秒
        let source = try makeScannedPDF(pages: pages)
        var settings = ConversionSettings()
        settings.target = .text
        settings.filenamePattern = "out"

        let flag = CancellationFlag()
        let started = Date()
        let task = Task.detached {
            try PDFToolkit.extractText(
                url: source,
                settings: settings,
                recognizer: SlowRecognizer(perPage: perPage),
                to: self.directory.appendingPathComponent("partial.txt"),
                cancellation: flag
            )
        }

        try await Task.sleep(nanoseconds: 500_000_000)  // 跑到第 1~2 页时按停
        flag.cancel()

        var threw = false
        do {
            _ = try await task.value
        } catch {
            threw = true
        }
        let elapsed = Date().timeIntervalSince(started)

        print(
            "CANCEL 整份约 \(String(format: "%.1f", Double(pages) * Double(perPage) / 1e9))s；实测 \(String(format: "%.2f", elapsed))s 停止"
        )

        XCTAssertTrue(threw, "取消之后不该正常返回")
        XCTAssertLessThan(
            elapsed, 1.5,
            "取消响应过慢（\(String(format: "%.2f", elapsed))s）：检查点应当每一页都过一遍"
        )
    }

    /// 取消之后不该留下半成品文件。
    func testCancelLeavesNoPartialOutput() async throws {
        let source = try makeScannedPDF(pages: 12)
        var settings = ConversionSettings()
        settings.target = .text
        settings.filenamePattern = "out"

        let flag = CancellationFlag()
        let target = directory.appendingPathComponent("partial.txt")

        let task = Task.detached {
            try PDFToolkit.extractText(
                url: source,
                settings: settings,
                recognizer: SlowRecognizer(perPage: 300_000_000),
                to: target,
                cancellation: flag
            )
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        flag.cancel()
        _ = try? await task.value

        // 文字是在全部页跑完之后一次性写出的，所以半途取消不该留下任何文件
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: target.path),
            "取消后留下了半成品文件 —— 用户会以为那是一份完整的文本"
        )
    }
}
