import Foundation

/// 转换过程中可预期的错误。
///
/// 所有面向用户的失败都经由这个类型，这样 CLI 与 GUI 共用同一套文案，
/// 也只需要在一处做本地化。
public struct ConversionError: LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }

    public init(_ message: String) {
        self.message = message
    }

    // MARK: - 常用错误

    public static func unreadablePDF() -> ConversionError {
        ConversionError(Localized.text("Cannot read this PDF (the file may be damaged or password protected)."))
    }

    public static func encryptedPDF() -> ConversionError {
        ConversionError(Localized.text("This PDF is encrypted and needs a password."))
    }

    public static func emptyPDF() -> ConversionError {
        ConversionError(Localized.text("This PDF has no pages."))
    }

    public static func emptyPageRange() -> ConversionError {
        ConversionError(Localized.text("The page range is empty or invalid."))
    }

    public static func unsupportedOutput(_ name: String) -> ConversionError {
        ConversionError(Localized.text("This Mac cannot write %@ files.", name))
    }

    public static func unsupportedInput(_ name: String) -> ConversionError {
        ConversionError(Localized.text("Cannot read %@ files.", name))
    }

    public static func conversionNotSupported(_ from: String, _ to: String) -> ConversionError {
        ConversionError(Localized.text("Converting %@ to %@ is not supported.", from, to))
    }

    public static func tooManyPixels(_ width: Int, _ height: Int, limit: Int) -> ConversionError {
        let megapixels = Double(width * height) / 1_000_000
        let limitMegapixels = Double(limit) / 1_000_000
        return ConversionError(
            Localized.text(
                "The output would be about %.0f megapixels, over the %.0f megapixel safety limit. Lower the DPI or scale.",
                megapixels, limitMegapixels)
        )
    }

    /// 输出尺寸不满足格式的硬性要求。
    public static func sizeNotAllowed(
        format: String, width: Int, height: Int, requirement: String
    ) -> ConversionError {
        ConversionError(
            Localized.text(
                "%@ needs %@, but the output would be %d×%d. Change the page size, scale, or pick another format.",
                format, requirement, width, height)
        )
    }

    public static func missingExternalTool(_ tool: String, hint: String) -> ConversionError {
        ConversionError(Localized.text("%@ was not found, so this format cannot be converted. %@", tool, hint))
    }
}
