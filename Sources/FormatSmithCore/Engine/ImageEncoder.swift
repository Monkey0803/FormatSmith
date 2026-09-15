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
    public static func encode(_ image: CGImage, format: ImageFormat, quality: Double) throws -> Data {
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

        var properties: [CFString: Any] = [:]
        if format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0.0), 1.0)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError(Localized.text("Failed to encode %@.", format.displayName))
        }
        return data as Data
    }

    /// 编码并原子写入磁盘；目录不存在时自动创建。
    @discardableResult
    public static func write(
        _ image: CGImage,
        format: ImageFormat,
        quality: Double,
        to url: URL
    ) throws -> URL {
        let data = try encode(image, format: format, quality: quality)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = OutputNaming.uniqueURL(url)
        try data.write(to: target, options: .atomic)
        return target
    }
}
