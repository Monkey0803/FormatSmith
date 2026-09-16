import CoreGraphics
import Foundation

/// 标准证件照尺寸。
///
/// 用毫米定义，像素值由 DPI 换算 —— 打印店按毫米裁纸，按像素存图，
/// 两边都得对得上，所以这里只存毫米、算像素。
public enum IDPhotoSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case smallOneInch  // 小一寸
    case oneInch  // 一寸
    case idCard  // 身份证
    case largeOneInch  // 大一寸 / 小二寸 / 护照
    case twoInch  // 二寸
    case largeTwoInch  // 大二寸
    case threeInch  // 三寸
    case usVisa  // 美国签证（2×2 英寸）

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .smallOneInch: return Localized.text("Small 1-inch")
        case .oneInch: return Localized.text("1-inch")
        case .idCard: return Localized.text("ID card")
        case .largeOneInch: return Localized.text("Large 1-inch / passport")
        case .twoInch: return Localized.text("2-inch")
        case .largeTwoInch: return Localized.text("Large 2-inch")
        case .threeInch: return Localized.text("3-inch")
        case .usVisa: return Localized.text("US visa")
        }
    }

    /// 命令行里用的名字：`one-inch` 比 `oneInch` 好敲。
    public var cliName: String {
        switch self {
        case .smallOneInch: return "small-one-inch"
        case .oneInch: return "one-inch"
        case .idCard: return "id-card"
        case .largeOneInch: return "large-one-inch"
        case .twoInch: return "two-inch"
        case .largeTwoInch: return "large-two-inch"
        case .threeInch: return "three-inch"
        case .usVisa: return "us-visa"
        }
    }

    /// 宽 × 高（毫米）。
    public var millimetres: (width: Double, height: Double) {
        switch self {
        case .smallOneInch: return (22, 32)
        case .oneInch: return (25, 35)
        case .idCard: return (26, 32)
        case .largeOneInch: return (33, 48)
        case .twoInch: return (35, 49)
        case .largeTwoInch: return (35, 53)
        case .threeInch: return (55, 84)
        // 2×2 英寸正好是 600×600 像素 @300 DPI，用 50.8mm 而不是四舍五入的 51mm
        case .usVisa: return (50.8, 50.8)
        }
    }

    public var widthMM: Double { millimetres.width }
    public var heightMM: Double { millimetres.height }

    /// 一毫米等于多少点（1 pt = 1/72 inch）。
    static let pointsPerMillimetre = 72.0 / 25.4

    /// 目标像素尺寸。
    public func pixelSize(dpi: Double) -> (width: Int, height: Int) {
        let unit = max(dpi, 1) / 25.4
        let width = Int((widthMM * unit).rounded())
        let height = Int((heightMM * unit).rounded())
        return (max(width, 1), max(height, 1))
    }

    /// 用于排版的毫米尺寸（点）。
    public var pointSize: CGSize {
        CGSize(
            width: widthMM * Self.pointsPerMillimetre,
            height: heightMM * Self.pointsPerMillimetre
        )
    }

    /// 面向用户的说明，例如「25 × 35 mm · 300 DPI 下 295 × 413 px」。
    public func summary(dpi: Double) -> String {
        let pixels = pixelSize(dpi: dpi)
        return String(
            format: Localized.text("%.0f × %.0f mm · %d × %d px at %.0f DPI"),
            widthMM, heightMM, pixels.width, pixels.height, dpi
        )
    }
}

/// 证件照底色。
public enum IDPhotoBackground: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 保留照片原来的背景，只做裁剪与缩放。
    case keep
    case white
    case blue
    case red

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .keep: return Localized.text("Keep original")
        case .white: return Localized.text("White")
        case .blue: return Localized.text("Blue")
        case .red: return Localized.text("Red")
        }
    }

    /// 填充色；`.keep` 返回 nil。
    ///
    /// 显式用 sRGB 构造：`CGColor(red:green:blue:alpha:)` 建出来的是 GenericRGB，
    /// 填进 sRGB 画布时要经过一次色彩空间转换，纯红会变成 (255,38,0) 这种结果。
    /// 证件照底色是有标准的，不能让它飘。
    public var color: CGColor? {
        guard let components = sRGBComponents else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return CGColor(red: components.0, green: components.1, blue: components.2, alpha: 1)
        }
        return CGColor(
            colorSpace: space,
            components: [components.0, components.1, components.2, 1]
        )
    }

    /// 0–1 的 sRGB 分量。
    public var sRGBComponents: (red: Double, green: Double, blue: Double)? {
        switch self {
        case .keep: return nil
        case .white: return (1, 1, 1)
        // 证件照常用的「标准蓝」
        case .blue: return (67 / 255, 142 / 255, 219 / 255)
        case .red: return (1, 0, 0)
        }
    }

    /// 是否需要把人像抠出来（换底色才需要）。
    public var requiresCutout: Bool {
        self != .keep
    }
}

/// 冲印相纸尺寸。
public enum PrintSheet: String, Codable, CaseIterable, Identifiable, Sendable {
    case fiveInch  // 5 寸
    case sixInch  // 6 寸
    case a4

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fiveInch: return Localized.text("5-inch paper")
        case .sixInch: return Localized.text("6-inch paper")
        case .a4: return "A4"
        }
    }

    /// 命令行里用的名字。
    public var cliName: String {
        switch self {
        case .fiveInch: return "five-inch"
        case .sixInch: return "six-inch"
        case .a4: return "a4"
        }
    }

    /// 宽 × 高（毫米）。
    public var millimetres: (width: Double, height: Double) {
        switch self {
        case .fiveInch: return (89, 127)
        case .sixInch: return (102, 152)
        case .a4: return (210, 297)
        }
    }

    public var widthMM: Double { millimetres.width }
    public var heightMM: Double { millimetres.height }

    public func pixelSize(dpi: Double) -> (width: Int, height: Int) {
        let unit = max(dpi, 1) / 25.4
        return (
            max(Int((widthMM * unit).rounded()), 1),
            max(Int((heightMM * unit).rounded()), 1)
        )
    }
}
