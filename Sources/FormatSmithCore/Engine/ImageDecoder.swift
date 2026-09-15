import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 图片文件 → CGImage。
///
/// 统一走 `CGImageSourceCreateThumbnailAtIndex`：它一次完成「按需缩放 + 应用 EXIF 方向」，
/// 比先解码再自己转方向更省内存，也不会踩到方向丢失的坑。
public enum ImageDecoder {

    /// 像素尺寸（不含 EXIF 旋转；旋转后的显示尺寸见 `displaySize(of:)`）。
    public static func pixelSize(of url: URL) -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return .zero }

        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        return CGSize(width: width, height: height)
    }

    /// 应用 EXIF 方向后的显示尺寸。
    public static func displaySize(of url: URL) -> CGSize {
        let size = pixelSize(of: url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        else { return size }

        // 5–8 表示旋转 90/270 度，宽高互换。
        return (5...8).contains(orientation) ? CGSize(width: size.height, height: size.width) : size
    }

    /// 解码并按 `scale` 缩放。
    ///
    /// - Parameter scale: 1.0 表示保持原始像素尺寸。
    public static func decode(url: URL, scale: Double, maxPixels: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ConversionError.unsupportedInput(url.lastPathComponent)
        }
        let size = displaySize(of: url)
        guard size.width > 0, size.height > 0 else {
            throw ConversionError.unsupportedInput(url.lastPathComponent)
        }

        return try decode(source: source, scale: scale, maxPixels: maxPixels, fallbackSize: size)
    }

    /// 从已打开的 image source 解码。
    public static func decode(
        source: CGImageSource,
        scale: Double,
        maxPixels: Int,
        fallbackSize: CGSize
    ) throws -> CGImage {
        let size = fallbackSize.width > 0 ? fallbackSize : pixelSize(of: source)
        let targetWidth = Int((size.width * scale).rounded())
        let targetHeight = Int((size.height * scale).rounded())

        guard targetWidth > 0, targetHeight > 0 else {
            throw ConversionError(Localized.text("The computed output size is invalid. Lower the resolution."))
        }
        guard targetWidth * targetHeight <= maxPixels else {
            throw ConversionError.tooManyPixels(targetWidth, targetHeight, limit: maxPixels)
        }

        let maxDimension = max(targetWidth, targetHeight)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]

        // 某些格式（例如部分 RAW）不支持缩略图路径，退回完整解码。
        guard
            let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ConversionError(Localized.text("Could not decode this image."))
        }

        // 缩略图 API 只会缩小、不会放大：目标比原图大时必须自己重采样，
        // 否则「2×」会静默地输出原始尺寸。
        if decoded.width < targetWidth || decoded.height < targetHeight {
            return try resample(decoded, width: targetWidth, height: targetHeight)
        }
        return decoded
    }

    /// 重采样到指定像素尺寸（放大或缩小）。
    public static func resample(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        let wantsAlpha = image.hasAlphaChannel
        let context = try BitmapContext.make(width: width, height: height, wantsAlpha: wantsAlpha)
        if !wantsAlpha { context.fill(with: .white) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else {
            throw ConversionError(Localized.text("Rendering failed."))
        }
        return result
    }

    /// 队列预览用的小图。失败返回 nil，不影响转换流程。
    public static func thumbnail(url: URL, maxSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 多帧图片（GIF、MPO、HEIC 连拍）的帧数。
    public static func frameCount(of url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    private static func pixelSize(of source: CGImageSource) -> CGSize {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return .zero
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        return CGSize(width: width, height: height)
    }
}
