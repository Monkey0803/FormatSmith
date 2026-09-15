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
