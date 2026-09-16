import CoreGraphics
import Foundation
import XCTest
@testable import FormatSmithCore

/// 证件照尺寸换算：打印店按毫米裁纸，按像素存图，两边都得对得上。
final class IDPhotoSizeTests: XCTestCase {

    func testMillimetres() {
        XCTAssertEqual(IDPhotoSize.oneInch.widthMM, 25)
        XCTAssertEqual(IDPhotoSize.oneInch.heightMM, 35)
        XCTAssertEqual(IDPhotoSize.twoInch.widthMM, 35)
        XCTAssertEqual(IDPhotoSize.twoInch.heightMM, 49)
        XCTAssertEqual(IDPhotoSize.usVisa.widthMM, 50.8, "美签是 2×2 英寸，用 50.8mm 才能正好 600px")
    }

    func testPixelSizeAt300DPI() {
        // 这三个是最常见的规格，像素值都是行业里通行的数字
        assertPixels(.oneInch, 295, 413)
        assertPixels(.twoInch, 413, 579)
        assertPixels(.largeOneInch, 390, 567)  // 小二寸 / 护照
        assertPixels(.usVisa, 600, 600)
    }

    func testPixelSizeScalesWithDPI() {
        let at300 = IDPhotoSize.oneInch.pixelSize(dpi: 300)
        let at600 = IDPhotoSize.oneInch.pixelSize(dpi: 600)
        // 毫米换算到像素要取整，翻倍允许差 1 像素
        XCTAssertEqual(at600.width, at300.width * 2, accuracy: 1)
        XCTAssertEqual(at600.height, at300.height * 2, accuracy: 1)
    }

    func testPixelSizeIsAlwaysPositive() {
        for size in IDPhotoSize.allCases {
            let pixels = size.pixelSize(dpi: 300)
            XCTAssertGreaterThan(pixels.width, 0, "\(size.displayName)")
            XCTAssertGreaterThan(pixels.height, 0, "\(size.displayName)")
            XCTAssertGreaterThan(size.widthMM, 0, "\(size.displayName)")
        }
    }

    func testAspectRatioIsPortraitExceptUsVisa() {
        for size in IDPhotoSize.allCases {
            let ratio = size.widthMM / size.heightMM
            if size == .usVisa {
                XCTAssertEqual(ratio, 1, accuracy: 0.01, "美签是正方形")
            } else {
                XCTAssertLessThan(ratio, 1, "\(size.displayName) 应该是竖版")
            }
        }
    }

    private func assertPixels(_ size: IDPhotoSize, _ width: Int, _ height: Int, line: UInt = #line) {
        let pixels = size.pixelSize(dpi: 300)
        XCTAssertEqual(pixels.width, width, "\(size.displayName) 宽", line: line)
        XCTAssertEqual(pixels.height, height, "\(size.displayName) 高", line: line)
    }
}

/// 相纸排版：算得出放几张、放得下、位置不越界。
final class PhotoSheetTilerTests: XCTestCase {

    func testOneInchPhotosOnSixInchPaper() {
        let plan = PhotoSheetTiler.layout(photo: .oneInch, sheet: .sixInch, marginMM: 2, gapMM: 1)
        XCTAssertEqual(plan.columns, 3)
        XCTAssertEqual(plan.rows, 4)
        XCTAssertEqual(plan.count, 12)
    }

    func testTwoInchPhotosFitFewerPerSheet() {
        let oneInch = PhotoSheetTiler.layout(photo: .oneInch, sheet: .sixInch, marginMM: 2, gapMM: 1)
        let twoInch = PhotoSheetTiler.layout(photo: .twoInch, sheet: .sixInch, marginMM: 2, gapMM: 1)
        XCTAssertLessThan(twoInch.count, oneInch.count, "二寸照更大，一张相纸能放的张数应更少")
        XCTAssertGreaterThan(twoInch.count, 0)
    }

    func testAllCellsStayInsideThePaper() {
        for sheet in PrintSheet.allCases {
            let plan = PhotoSheetTiler.layout(photo: .oneInch, sheet: sheet, marginMM: 2, gapMM: 1)
            // 版面单位是点
            let paper = CGSize(
                width: sheet.widthMM * IDPhotoSize.pointsPerMillimetre,
                height: sheet.heightMM * IDPhotoSize.pointsPerMillimetre
            )
            XCTAssertGreaterThan(plan.count, 0, "\(sheet.displayName) 至少应放得下一张")
            for cell in plan.cells {
                XCTAssertGreaterThanOrEqual(cell.minX, 0, "\(sheet.displayName) 越出左边界")
                XCTAssertGreaterThanOrEqual(cell.minY, 0, "\(sheet.displayName) 越出下边界")
                XCTAssertLessThanOrEqual(cell.maxX, paper.width + 0.5, "\(sheet.displayName) 越出右边界")
                XCTAssertLessThanOrEqual(cell.maxY, paper.height + 0.5, "\(sheet.displayName) 越出上边界")
            }
        }
    }

    func testCellsDoNotOverlap() {
        let plan = PhotoSheetTiler.layout(photo: .oneInch, sheet: .sixInch, marginMM: 2, gapMM: 1)
        for (index, first) in plan.cells.enumerated() {
            for second in plan.cells[(index + 1)...] {
                XCTAssertFalse(first.intersects(second), "照片之间不应重叠: \(first) / \(second)")
            }
        }
    }

    func testLayoutIsCentredOnThePaper() {
        let plan = PhotoSheetTiler.layout(photo: .oneInch, sheet: .sixInch, marginMM: 2, gapMM: 1)
        let paperWidth = PrintSheet.sixInch.widthMM * IDPhotoSize.pointsPerMillimetre

        let leftmost = plan.cells.map(\.minX).min()!
        let rightmost = plan.cells.map(\.maxX).max()!
        XCTAssertEqual(leftmost, paperWidth - rightmost, accuracy: 1.0, "左右留白应当一样宽")
    }

    func testTooBigPhotoForTinySheetYieldsNoLayout() {
        // 三寸照放到 5 寸相纸上：按尺寸算其实放得下，但边距吃掉空间后不该算出负数
        let plan = PhotoSheetTiler.layout(photo: .threeInch, sheet: .fiveInch, marginMM: 60, gapMM: 5)
        XCTAssertEqual(plan.count, 0, "边距过大时应当算出「放不下」而不是负数量")
    }

    func testRenderPlacesEveryPhotoInItsOwnCell() throws {
        // 每个格子的中心都应当是照片，格子之间的缝隙与纸张留白应当是白的。
        // 这条断言专门盯着「单位算错」——曾经整张相纸只印出一张被放大 4 倍的巨型照片，
        // 而当时那条只看尺寸的用例照样通过。
        let photo = try makeRedImage(width: 120, height: 168)
        let sheet = try PhotoSheetTiler.render(
            photo: photo,
            photoSize: .oneInch,
            sheet: .sixInch,
            dpi: 300,
            marginMM: 2,
            gapMM: 1,
            cutGuides: false
        )

        let expected = PrintSheet.sixInch.pixelSize(dpi: 300)
        XCTAssertEqual(sheet.width, expected.width)
        XCTAssertEqual(sheet.height, expected.height)

        let probe = try PixelProbe(sheet)
        let plan = PhotoSheetTiler.layout(photo: .oneInch, sheet: .sixInch, marginMM: 2, gapMM: 1)
        XCTAssertEqual(plan.count, 12)
        let scale = CGFloat(expected.width) / (CGFloat(PrintSheet.sixInch.widthMM) * IDPhotoSize.pointsPerMillimetre)

        for (index, cell) in plan.cells.enumerated() {
            let centreX = Int((cell.midX * scale).rounded())
            let centreY = sheet.height - Int((cell.midY * scale).rounded())
            let pixel = probe.pixel(x: centreX, y: centreY)
            XCTAssertTrue(
                pixel.isClose(to: .red, tolerance: 30),
                "第 \(index + 1) 张照片的中心应当是红的，实际 \(pixel)（格子 \(cell)）"
            )
        }

        // 纸张四角是留白
        for point in [(4, 4), (sheet.width - 5, 4), (4, sheet.height - 5), (sheet.width - 5, sheet.height - 5)] {
            XCTAssertTrue(
                probe.pixel(x: point.0, y: point.1).isClose(to: .white, tolerance: 12),
                "纸张角落 \(point) 应当是白的，实际 \(probe.pixel(x: point.0, y: point.1))"
            )
        }
    }

    func testRenderedPhotoAreaMatchesTheLayout() throws {
        // 红色像素的总面积应当约等于「张数 × 单张面积」。
        // 照片被放大或缩小都会让这个数字对不上。
        let photo = try makeRedImage(width: 120, height: 168)
        let sheet = try PhotoSheetTiler.render(
            photo: photo, photoSize: .oneInch, sheet: .sixInch, dpi: 300,
            marginMM: 2, gapMM: 1, cutGuides: false
        )

        let probe = try PixelProbe(sheet)
        var redPixels = 0
        for y in stride(from: 0, to: sheet.height, by: 2) {
            for x in stride(from: 0, to: sheet.width, by: 2) {
                if probe.pixel(x: x, y: y).r > 180, probe.pixel(x: x, y: y).g < 120 { redPixels += 1 }
            }
        }
        // 抽样步长是 2，所以换算回全图要乘 4
        let redArea = Double(redPixels) * 4

        let plan = PhotoSheetTiler.layout(photo: .oneInch, sheet: .sixInch, marginMM: 2, gapMM: 1)
        let scale = CGFloat(sheet.width) / (CGFloat(PrintSheet.sixInch.widthMM) * IDPhotoSize.pointsPerMillimetre)
        let expectedArea =
            Double(plan.count) * Double(plan.cellSize.width * scale) * Double(plan.cellSize.height * scale)

        XCTAssertEqual(
            redArea, expectedArea, accuracy: expectedArea * 0.06,
            "照片总面积应当接近 \(Int(expectedArea))，实际 \(Int(redArea))"
        )
    }

    func testRenderDrawsCutGuidesWhenAsked() throws {
        let photo = try makeRedImage(width: 120, height: 168)
        let without = try PhotoSheetTiler.render(
            photo: photo, photoSize: .oneInch, sheet: .sixInch, dpi: 150, cutGuides: false
        )
        let with = try PhotoSheetTiler.render(
            photo: photo, photoSize: .oneInch, sheet: .sixInch, dpi: 150, cutGuides: true
        )

        // 辅助线是灰色，会把照片边缘的像素拉离纯红
        let plan = PhotoSheetTiler.layout(photo: .oneInch, sheet: .sixInch, marginMM: 2, gapMM: 1)
        let paperPixels = PrintSheet.sixInch.pixelSize(dpi: 150)
        let scale = CGFloat(paperPixels.width) / (CGFloat(PrintSheet.sixInch.widthMM) * IDPhotoSize.pointsPerMillimetre)
        let first = plan.cells[0]
        let edgeX = Int((first.minX * scale).rounded())
        let edgeY = without.height - Int((first.midY * scale).rounded())

        let plain = try PixelProbe(without).pixel(x: edgeX, y: edgeY)
        let guided = try PixelProbe(with).pixel(x: edgeX, y: edgeY)
        XCTAssertNotEqual(plain, guided, "开启辅助线后边缘像素应当变化")
    }

    private func makeRedImage(width: Int, height: Int) throws -> CGImage {
        let context = try BitmapContext.make(width: width, height: height, wantsAlpha: false)
        context.setFillColor(FixtureFactory.color(FixtureFactory.Palette.red))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
