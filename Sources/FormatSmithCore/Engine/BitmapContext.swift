import CoreGraphics

/// 位图上下文构造与背景填充。
public enum BitmapContext {

    /// 创建一个 8 位 sRGB 位图上下文。
    ///
    /// - Parameter wantsAlpha: true 时保留 alpha 通道（BGRA premultiplied）；
    ///   false 时用 `noneSkipFirst`，避免 JPEG 之类的格式拿到无意义的不透明像素。
    public static func make(width: Int, height: Int, wantsAlpha: Bool) throws -> CGContext {
        let bitmapInfo: UInt32 =
            wantsAlpha
            ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            : CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            )
        else {
            throw ConversionError(Localized.text("Could not create a drawing context."))
        }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        return context
    }
}

public extension CGImage {
    /// 该图像是否带 alpha 通道（与像素内容无关）。
    var hasAlphaChannel: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }
}

public extension CGContext {
    /// 铺满背景色。`.transparent` 表示不填充（由调用方保证上下文本身允许 alpha）。
    func fill(with background: ImageBackground, in rect: CGRect? = nil) {
        let color: CGColor
        switch background {
        case .white:
            color = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        case .black:
            color = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        case .transparent:
            return
        }
        setFillColor(color)
        fill(rect ?? CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// 把一个 CGImage 画满整个上下文（用于图片缩放/重采样）。
    func draw(_ image: CGImage, fillingRect rect: CGRect) {
        draw(image, in: rect)
    }
}
