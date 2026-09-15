import CoreGraphics
import XCTest
@testable import FormatSmithCore

/// `/Rotate` 是上一轮真实踩过的坑：`CGContext.drawPDFPage` 不会应用页面自身的旋转，
/// 必须自己乘矩阵。这里把矩阵抽成纯函数逐一锁死，任何回归都会立刻失败。
final class PageTransformTests: XCTestCase {

    private let box = CGRect(x: 0, y: 0, width: 400, height: 300)

    private func mapped(_ point: CGPoint, rotation: Int, box: CGRect) -> CGPoint {
        point.applying(PDFRasterizer.pageTransform(rotation: rotation, box: box))
    }

    // MARK: - 0 度

    func testIdentityKeepsCoordinates() {
        let transform = PDFRasterizer.pageTransform(rotation: 0, box: box)
        XCTAssertEqual(CGPoint(x: 10, y: 20).applying(transform), CGPoint(x: 10, y: 20))
        XCTAssertEqual(CGPoint(x: 400, y: 300).applying(transform), CGPoint(x: 400, y: 300))
    }

    // MARK: - 90 度（顺时针）

    func testRotate90MapsCornersToExpectedPlaces() {
        // (x, y) → (y, w - x)；画布变成 h × w = 300 × 400
        assertPoint(mapped(CGPoint(x: 0, y: 0), rotation: 90, box: box), equals: CGPoint(x: 0, y: 400))
        assertPoint(mapped(CGPoint(x: 400, y: 0), rotation: 90, box: box), equals: CGPoint(x: 0, y: 0))
        assertPoint(mapped(CGPoint(x: 400, y: 300), rotation: 90, box: box), equals: CGPoint(x: 300, y: 0))
        assertPoint(mapped(CGPoint(x: 0, y: 300), rotation: 90, box: box), equals: CGPoint(x: 300, y: 400))
    }

    func testRotate90FillsExactlyTheSwappedCanvas() {
        let canvas = canvasRect(rotation: 90)
        XCTAssertEqual(canvas, CGRect(x: 0, y: 0, width: 300, height: 400))
        assertBoxMapsExactlyOntoCanvas(rotation: 90, expected: canvas)
    }

    // MARK: - 180 度

    func testRotate180MapsCornersToExpectedPlaces() {
        // (x, y) → (w - x, h - y)；画布仍是 w × h
        assertPoint(mapped(CGPoint(x: 0, y: 0), rotation: 180, box: box), equals: CGPoint(x: 400, y: 300))
        assertPoint(mapped(CGPoint(x: 400, y: 300), rotation: 180, box: box), equals: CGPoint(x: 0, y: 0))
    }

    func testRotate180KeepsCanvasSize() {
        XCTAssertEqual(canvasRect(rotation: 180), box)
    }

    // MARK: - 270 度

    func testRotate270MapsCornersToExpectedPlaces() {
        // (x, y) → (h - y, x)；画布变成 h × w
        assertPoint(mapped(CGPoint(x: 0, y: 0), rotation: 270, box: box), equals: CGPoint(x: 300, y: 0))
        assertPoint(mapped(CGPoint(x: 400, y: 300), rotation: 270, box: box), equals: CGPoint(x: 0, y: 400))
    }

    func testRotate270FillsExactlyTheSwappedCanvas() {
        let canvas = canvasRect(rotation: 270)
        XCTAssertEqual(canvas, CGRect(x: 0, y: 0, width: 300, height: 400))
        assertBoxMapsExactlyOntoCanvas(rotation: 270, expected: canvas)
    }

    // MARK: - 非零原点

    func testOffsetOriginIsAccountedFor() {
        let offset = CGRect(x: 50, y: 80, width: 400, height: 300)
        // 旋转后画布仍从 (0,0) 开始
        let canvas = CGRect(x: 0, y: 0, width: 300, height: 400)
        assertBoxMapsExactlyOntoCanvas(rotation: 90, box: offset, expected: canvas, tolerance: 0.001)
        assertBoxMapsExactlyOntoCanvas(rotation: 0, box: offset, expected: CGRect(origin: .zero, size: offset.size))
    }

    // MARK: - 属性

    func testTransformIsARotationWithoutScalingOrMirroring() {
        for rotation in [0, 90, 180, 270] {
            let transform = PDFRasterizer.pageTransform(rotation: rotation, box: box)
            let determinant = transform.a * transform.d - transform.b * transform.c
            XCTAssertEqual(determinant, 1.0, accuracy: 0.0001, "rotation \(rotation) 改变了面积或发生了镜像")

            // 只检查线性部分：矩阵里带着平移量，直接作用到点上会把这部分算进去。
            XCTAssertEqual(hypot(transform.a, transform.b), 1.0, accuracy: 0.0001)
            XCTAssertEqual(hypot(transform.c, transform.d), 1.0, accuracy: 0.0001)
            // 两个基向量仍然正交
            XCTAssertEqual(transform.a * transform.c + transform.b * transform.d, 0, accuracy: 0.0001)
        }
    }

    func testNegativeAndOversizedAnglesAreNormalized() {
        XCTAssertEqual(
            PDFRasterizer.pageTransform(rotation: -90, box: box),
            PDFRasterizer.pageTransform(rotation: 270, box: box)
        )
        XCTAssertEqual(
            PDFRasterizer.pageTransform(rotation: 450, box: box),
            PDFRasterizer.pageTransform(rotation: 90, box: box)
        )
        XCTAssertEqual(
            PDFRasterizer.pageTransform(rotation: 360, box: box),
            PDFRasterizer.pageTransform(rotation: 0, box: box)
        )
    }

    // MARK: - 辅助

    /// 与渲染实现保持一致的目标画布尺寸。
    private func canvasRect(rotation: Int, box: CGRect? = nil) -> CGRect {
        let box = box ?? self.box
        let swapped = rotation == 90 || rotation == 270
        return swapped
            ? CGRect(x: 0, y: 0, width: box.height, height: box.width)
            : CGRect(x: 0, y: 0, width: box.width, height: box.height)
    }

    /// 检查 box 的四个角经过变换后，正好落在目标画布的四角上（不裁切、不偏移）。
    private func assertBoxMapsExactlyOntoCanvas(
        rotation: Int,
        box: CGRect? = nil,
        expected: CGRect,
        tolerance: CGFloat = 0.0001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let box = box ?? self.box
        let corners = [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY),
        ].map { $0.applying(PDFRasterizer.pageTransform(rotation: rotation, box: box)) }

        let mappedMinX = corners.map(\.x).min()!
        let mappedMaxX = corners.map(\.x).max()!
        let mappedMinY = corners.map(\.y).min()!
        let mappedMaxY = corners.map(\.y).max()!

        XCTAssertEqual(mappedMinX, expected.minX, accuracy: tolerance, "左边界不对", file: file, line: line)
        XCTAssertEqual(mappedMaxX, expected.maxX, accuracy: tolerance, "右边界不对", file: file, line: line)
        XCTAssertEqual(mappedMinY, expected.minY, accuracy: tolerance, "下边界不对", file: file, line: line)
        XCTAssertEqual(mappedMaxY, expected.maxY, accuracy: tolerance, "上边界不对", file: file, line: line)
    }

    private func assertPoint(
        _ actual: CGPoint,
        equals expected: CGPoint,
        accuracy: CGFloat = 0.0001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
    }
}
