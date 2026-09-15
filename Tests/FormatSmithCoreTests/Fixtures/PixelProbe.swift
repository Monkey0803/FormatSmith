import CoreGraphics
import FormatSmithCore
import Foundation
import ImageIO

/// 把 CGImage 解到 RGBA 缓冲里按坐标取像素。
///
/// 上一轮的 `/Rotate` bug 就是靠这种方式定位的：断言「红块应该落在右上角」，
/// 比只看尺寸能不能对上更能说明问题。
struct PixelProbe {
    let width: Int
    let height: Int
    private let data: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        // 用一个 premultipliedLast 的独立上下文重绘，保证读取到的分量顺序固定。
        guard
            let readback = CGContext(
                data: &buffer,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw ProbeError.cannotCreateReadbackContext
        }
        readback.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        data = buffer
    }

    init(contentsOf url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ProbeError.cannotOpenImage }
        try self.init(image)
    }

    struct RGBA: Equatable, CustomStringConvertible {
        let r: Int
        let g: Int
        let b: Int
        let a: Int

        var description: String { "RGBA(\(r), \(g), \(b), \(a))" }

        /// 与期望颜色比较，允许编码/色彩空间带来的偏差。
        func isClose(to other: RGBA, tolerance: Int = 24) -> Bool {
            abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance
                && abs(b - other.b) <= tolerance && abs(a - other.a) <= tolerance
        }
    }

    /// 取像素，`y` 从图像顶部算起（符合看图直觉）。
    func pixel(x: Int, y: Int) -> RGBA {
        precondition(
            x >= 0 && x < width && y >= 0 && y < height, "pixel out of bounds: \(x),\(y) in \(width)×\(height)")
        let index = (y * width + x) * 4
        return RGBA(
            r: Int(data[index]),
            g: Int(data[index + 1]),
            b: Int(data[index + 2]),
            a: Int(data[index + 3])
        )
    }

    /// 统计整幅图里完全透明的像素比例。
    func transparentRatio(threshold: Int = 8) -> Double {
        var transparent = 0
        for index in stride(from: 3, to: data.count, by: 4) where Int(data[index]) <= threshold {
            transparent += 1
        }
        return Double(transparent) / Double(width * height)
    }

    /// 该 CGImage 是否真的带 alpha 通道（与像素内容无关）。
    static func hasAlphaChannel(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    enum ProbeError: Error {
        case cannotOpenImage
        case cannotCreateReadbackContext
    }
}

/// 测试里频繁使用的期望颜色，放在 RGBA 上就能写成 `.red`、`.white`。
extension PixelProbe.RGBA {
    static let white = PixelProbe.RGBA(r: 255, g: 255, b: 255, a: 255)
    static let black = PixelProbe.RGBA(r: 0, g: 0, b: 0, a: 255)
    static let red = PixelProbe.RGBA(r: 230, g: 51, b: 51, a: 255)
    static let blue = PixelProbe.RGBA(r: 26, g: 128, b: 230, a: 255)
    static let clear = PixelProbe.RGBA(r: 0, g: 0, b: 0, a: 0)
}
