import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 一个图片格式。用 UTType identifier 作为稳定主键，这样：
/// - 设置持久化后跨版本仍然有效；
/// - 能力的真实来源是系统的 ImageIO，而不是我们硬编码的枚举。
public struct ImageFormat: Codable, Hashable, Identifiable, Sendable {
    public let identifier: String

    public init(_ identifier: String) {
        self.identifier = identifier
    }

    public var id: String { identifier }

    public var utType: UTType? { UTType(identifier) }

    /// 面向用户的名字，例如 "PNG"、"JPEG 2000"。
    public var displayName: String {
        FormatRegistry.displayName(for: identifier)
    }

    /// 文件扩展名，例如 "jpg"。
    ///
    /// 不完全依赖 `preferredFilenameExtension`：系统对 JPEG 给的是 "jpeg"，
    /// 而用户预期是 "jpg"。
    public var fileExtension: String {
        FormatRegistry.preferredExtensions[identifier]
            ?? utType?.preferredFilenameExtension
            ?? "img"
    }

    /// 一句话说明，用于 UI 提示。
    public var summary: String {
        let compression = supportsQuality ? Localized.text("Lossy") : Localized.text("Lossless")
        let transparency =
            supportsAlpha
            ? Localized.text("Supports transparency")
            : Localized.text("No transparency")
        return "\(compression) · \(transparency)"
    }

    /// 是否可以带压缩质量参数（有损格式）。
    public var supportsQuality: Bool {
        FormatRegistry.lossyIdentifiers.contains(identifier)
    }

    /// 是否可以保留透明通道。
    ///
    /// 对未知格式一律返回 false：宁可多铺一层背景，也不要写出一个
    /// 「应该是透明、实际却变黑」的图片。
    public var supportsAlpha: Bool {
        FormatRegistry.alphaCapableIdentifiers.contains(identifier)
    }

    /// 当前系统是否真的能写出这个格式。
    public var isWritableBySystem: Bool {
        FormatRegistry.writableIdentifiers.contains(identifier)
    }

    public var isReadableBySystem: Bool {
        FormatRegistry.readableIdentifiers.contains(identifier)
    }

    /// 该格式对输出像素尺寸的硬性要求。
    ///
    /// 这些容器格式并不是「任意图片都行」：ICO 要求正方形，
    /// ICNS 只接受特定边长的图标。与其让 `CGImageDestinationFinalize` 失败后
    /// 报一句看不懂的错，不如提前判断并给出能照着改的提示。
    public var pixelConstraint: PixelConstraint {
        FormatRegistry.constrainedIdentifiers[identifier] ?? .none
    }

    /// UI 选择器里的展示文本，例如 "PNG · .png"。
    public var menuLabel: String {
        "\(displayName)  ·  .\(fileExtension)"
    }

    // MARK: - 常用常量

    public static let png = ImageFormat("public.png")
    public static let jpeg = ImageFormat("public.jpeg")
    public static let tiff = ImageFormat("public.tiff")
    public static let heic = ImageFormat("public.heic")
    public static let bmp = ImageFormat("com.microsoft.bmp")
    public static let gif = ImageFormat("com.compuserve.gif")
    public static let avif = ImageFormat("public.avif")
    public static let jpeg2000 = ImageFormat("public.jpeg-2000")
    public static let psd = ImageFormat("com.adobe.photoshop-image")
}

/// 某些容器格式对输出尺寸有硬性要求。
///
/// 实测数据（macOS 27，`CGImageDestinationFinalize`）：
/// ICO 接受 16/24/32/48/64/128/256 的正方形，拒绝 96、512 及非正方形；
/// ICNS 只接受 16/24/32/48/128/256/512，连 64 和 1024 都会被拒。
/// 这类规则既没有文档也很难穷举，所以只保留可可靠支撑的格式，
/// 其余在编码前给出明确错误，而不是让用户看到一句 finalize 失败。
public enum PixelConstraint: Equatable, Sendable {
    /// 没有限制。
    case none
    /// 必须是给定范围内的正方形。
    case square(sideRange: ClosedRange<Int>)

    public func allows(width: Int, height: Int) -> Bool {
        switch self {
        case .none:
            return true
        case let .square(range):
            return width == height && range.contains(width)
        }
    }

    /// 面向用户的「为什么不行」说明。
    public var requirementDescription: String {
        switch self {
        case .none:
            return ""
        case let .square(range):
            return Localized.text("a square image, %d–%d px per side", range.lowerBound, range.upperBound)
        }
    }
}

/// ImageIO 能力查询与格式清单。
///
/// 所有能力都在运行时向系统询问（`CGImageDestinationCopyTypeIdentifiers` 等），
/// 因此在新系统上自动获得新格式，不需要改代码。
public enum FormatRegistry {

    // MARK: - 系统能力

    /// 系统可以写出的类型标识符。
    public static let writableIdentifiers: Set<String> = {
        Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
    }()

    /// 系统可以读取的类型标识符（含只能读不能写的 WebP、JPEG XL、各家 RAW 等）。
    public static let readableIdentifiers: Set<String> = {
        Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
    }()

    // MARK: - 元数据表

    /// UI 默认展示的精选格式（按常见程度排序）。
    public static let curatedOrder: [String] = [
        "public.png",
        "public.jpeg",
        "public.heic",
        "public.avif",
        "public.tiff",
        "com.compuserve.gif",
        "com.microsoft.bmp",
    ]

    /// 「显示全部格式」时追加的长尾格式。
    public static let extendedOrder: [String] = [
        "public.jpeg-2000",
        "com.adobe.photoshop-image",
        "com.truevision.tga-image",
        "com.ilm.openexr-image",
        "public.pbm",
        "com.microsoft.ico",
    ]

    /// `com.adobe.pdf` 也在 ImageIO 的可写列表里，但它由专门的 PDF 管线负责，
    /// 不应混进「图片格式」清单。
    static let nonImageIdentifiers: Set<String> = ["com.adobe.pdf"]

    /// 扩展名覆盖：系统给的名字不符合用户预期时以这里为准。
    static let preferredExtensions: [String: String] = [
        "public.jpeg": "jpg"
    ]

    /// 对输出尺寸有硬性要求的格式。
    static let constrainedIdentifiers: [String: PixelConstraint] = [
        "com.microsoft.ico": .square(sideRange: 16...256)
    ]

    /// 有损格式：接受 `kCGImageDestinationLossyCompressionQuality`。
    static let lossyIdentifiers: Set<String> = [
        "public.jpeg",
        "public.heic",
        "public.heics",
        "public.avif",
        "public.jpeg-2000",
        "com.ilm.openexr-image",
    ]

    /// 能保留透明通道的格式。
    ///
    /// 只列出高置信度的：PNG/TIFF/GIF 是本项目一直在用的，
    /// 其余是各自规范明确支持 alpha 的容器。
    static let alphaCapableIdentifiers: Set<String> = [
        "public.png",
        "public.tiff",
        "com.compuserve.gif",
        "com.adobe.photoshop-image",
        "com.truevision.tga-image",
        "com.ilm.openexr-image",
        "com.microsoft.ico",
        "com.apple.icns",
        "public.jpeg-2000",
    ]

    private static let displayNames: [String: String] = [
        "public.png": "PNG",
        "public.jpeg": "JPEG",
        "public.tiff": "TIFF",
        "public.heic": "HEIC",
        "public.heics": "HEIC Sequence",
        "com.microsoft.bmp": "BMP",
        "com.compuserve.gif": "GIF",
        "public.avif": "AVIF",
        "public.jpeg-2000": "JPEG 2000",
        "com.adobe.photoshop-image": "Photoshop",
        "com.microsoft.ico": "Windows Icon",
        "com.apple.icns": "Apple Icon",
        "com.truevision.tga-image": "Targa",
        "com.ilm.openexr-image": "OpenEXR",
        "com.microsoft.dds": "DirectDraw Surface",
        "org.khronos.ktx": "KTX",
        "org.khronos.ktx2": "KTX2",
        "org.khronos.astc": "ASTC",
        "public.pvr": "PowerVR",
        "com.apple.atx": "Apple Texture",
        "public.pbm": "Portable Bitmap",
        "org.webmproject.webp": "WebP",
        "public.jpeg-xl": "JPEG XL",
        "public.heif": "HEIF",
        "org.nema.dicom": "DICOM",
    ]

    public static func displayName(for identifier: String) -> String {
        if let name = displayNames[identifier] { return name }
        return UTType(identifier)?.localizedDescription ?? identifier
    }

    // MARK: - 清单

    /// 精选格式中当前系统真正支持的。
    public static var curated: [ImageFormat] {
        formats(from: curatedOrder)
    }

    /// 全部可写出的图片格式（精选 + 长尾），当前系统支持的。
    public static var allWritable: [ImageFormat] {
        formats(from: curatedOrder + extendedOrder)
    }

    /// 只能读、不能写的格式，用于「为什么不能导出成 WebP」这类说明。
    public static var readOnlyNotable: [ImageFormat] {
        ["org.webmproject.webp", "public.jpeg-xl", "public.heif"]
            .filter { readableIdentifiers.contains($0) }
            .map(ImageFormat.init)
    }

    private static func formats(from order: [String]) -> [ImageFormat] {
        order
            .filter { writableIdentifiers.contains($0) && !nonImageIdentifiers.contains($0) }
            .map(ImageFormat.init)
    }
}
