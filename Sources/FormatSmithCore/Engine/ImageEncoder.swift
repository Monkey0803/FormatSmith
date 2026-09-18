import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// CGImage → 图片数据。
public enum ImageEncoder {

    /// 校验输出尺寸是否满足格式的硬性要求（例如 ICO 必须是 16–256 的正方形）。
    public static func validate(_ image: CGImage, for format: ImageFormat) throws {
        let constraint = format.pixelConstraint
        guard !constraint.allows(width: image.width, height: image.height) else { return }
        throw ConversionError.sizeNotAllowed(
            format: format.displayName,
            width: image.width,
            height: image.height,
            requirement: constraint.requirementDescription
        )
    }

    /// 让图像满足目标格式的通道要求。
    ///
    /// 带透明通道的图要写进不支持 alpha 的格式时，必须先铺一层背景，
    /// 否则透明区域会变成黑色 —— 这是用户最容易察觉、也最难自己解释的一类差异。
    public static func prepare(
        _ image: CGImage,
        for format: ImageFormat,
        background: ImageBackground
    ) throws -> CGImage {
        guard image.hasAlphaChannel, !format.supportsAlpha else { return image }

        let context = try BitmapContext.make(width: image.width, height: image.height, wantsAlpha: false)
        context.fill(with: background == .black ? .black : .white)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flattened = context.makeImage() else {
            throw ConversionError(Localized.text("Rendering failed."))
        }
        return flattened
    }

    /// 编码为指定格式。
    /// 从源文件取元数据，并清理掉**已经处理过的**字段。
    ///
    /// 两个必须清掉的：
    /// - **方向**：解码时已经按 EXIF 方向把像素摆正了。再把 orientation 写回去，
    ///   看图软件会再转 90° —— 照片就直接躺倒了。
    /// - **像素尺寸**：缩放之后旧尺寸是错的，留着会让某些软件按错的尺寸显示。
    public static func metadata(from source: URL, policy: MetadataPolicy) -> [CFString: Any] {
        guard policy != .stripAll,
            let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        else { return [:] }

        var result = properties

        for key in [
            kCGImagePropertyOrientation,
            kCGImagePropertyPixelWidth,
            kCGImagePropertyPixelHeight,
            kCGImagePropertyDepth,
            // 色彩配置由图像本身携带，显式写名字反而可能和实际不一致
            kCGImagePropertyProfileName,
            kCGImagePropertyColorModel,
        ] {
            result.removeValue(forKey: key)
        }

        if var exif = result[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            result[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = result[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
            result[kCGImagePropertyTIFFDictionary] = tiff
        }

        if policy == .stripLocation {
            result.removeValue(forKey: kCGImagePropertyGPSDictionary)
        }

        return result
    }

    public static func encode(
        _ image: CGImage,
        format: ImageFormat,
        quality: Double,
        metadata: [CFString: Any] = [:]
    ) throws -> Data {
        try validate(image, for: format)

        guard let type = format.utType else {
            throw ConversionError.unsupportedOutput(format.displayName)
        }
        guard format.isWritableBySystem else {
            throw ConversionError.unsupportedOutput(format.displayName)
        }

        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, type.identifier as CFString, 1, nil
            )
        else {
            throw ConversionError.unsupportedOutput(format.displayName)
        }

        var properties = metadata
        // 质量必须最后写，覆盖源图里的任何压缩参数
        if format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0.0), 1.0)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError(Localized.text("Failed to encode %@.", format.displayName))
        }
        return data as Data
    }

    /// 把动图的每一帧原样写出去，保留帧间隔与循环次数。
    ///
    /// 只做容器层面的重写，不重绘。目标格式必须自己支持动画（目前系统可写的只有 GIF）。
    @discardableResult
    public static func writeAnimated(
        from source: URL,
        format: ImageFormat,
        metadata: [CFString: Any] = [:],
        to url: URL
    ) throws -> URL {
        guard let type = format.utType, format.isWritableBySystem else {
            throw ConversionError.unsupportedOutput(format.displayName)
        }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
            CGImageSourceGetCount(imageSource) > 1
        else {
            throw ConversionError(Localized.text("This image has only one frame."))
        }

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = OutputNaming.uniqueURL(url)

        let frameCount = CGImageSourceGetCount(imageSource)
        guard
            let destination = CGImageDestinationCreateWithURL(
                target as CFURL, type.identifier as CFString, frameCount, nil
            )
        else {
            throw ConversionError.unsupportedOutput(format.displayName)
        }

        // 循环次数记在第一帧上
        let container = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        let gifDictionary = container[kCGImagePropertyGIFDictionary] as? [CFString: Any] ?? [:]
        let loopCount = gifDictionary[kCGImagePropertyGIFLoopCount] as? Int ?? 0

        for index in 0..<frameCount {
            guard let frame = CGImageSourceCreateImageAtIndex(imageSource, index, nil) else { continue }
            let frameProperties =
                CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil)
                as? [CFString: Any] ?? [:]
            let frameGIF = frameProperties[kCGImagePropertyGIFDictionary] as? [CFString: Any] ?? [:]
            let delay =
                frameGIF[kCGImagePropertyGIFDelayTime] as? Double
                ?? frameGIF[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? 0.1

            var properties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay] as [CFString: Any]
            ]
            if index == 0 {
                properties[kCGImagePropertyGIFDictionary] = [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFLoopCount: loopCount,
                ]
                properties.merge(metadata) { _, new in new }
            }
            CGImageDestinationAddImage(destination, frame, properties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError(Localized.text("Failed to encode %@.", format.displayName))
        }
        return target
    }

    /// 编码并原子写入磁盘；目录不存在时自动创建。
    @discardableResult
    public static func write(
        _ image: CGImage,
        format: ImageFormat,
        quality: Double,
        metadata: [CFString: Any] = [:],
        to url: URL
    ) throws -> URL {
        let data = try encode(image, format: format, quality: quality, metadata: metadata)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = OutputNaming.uniqueURL(url)
        try data.write(to: target, options: .atomic)
        return target
    }
}
