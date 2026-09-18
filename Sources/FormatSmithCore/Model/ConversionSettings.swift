import CoreGraphics
import Foundation

/// 输出分辨率的表达方式。
public enum ResolutionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 按 DPI（PDF 的 72pt/inch 基准换算）。
    case dpi
    /// 按倍数（1× = PDF 原始尺寸，图片 = 原始像素）。
    case scale

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dpi: return "DPI"
        case .scale: return Localized.text("Scale")
        }
    }
}

/// 背景处理方式。
public enum ImageBackground: String, Codable, CaseIterable, Identifiable, Sendable {
    case white
    case black
    case transparent

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .white: return Localized.text("White")
        case .black: return Localized.text("Black")
        case .transparent: return Localized.text("Transparent")
        }
    }
}

/// 图片转 PDF 时的页面尺寸策略。
public enum PDFPageSize: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 页面尺寸等于图片尺寸（1 px = 1 pt）。
    case fitImage
    case a4
    case letter

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fitImage: return Localized.text("Match image")
        case .a4: return "A4"
        case .letter: return "Letter"
        }
    }

    /// 固定页面尺寸（点）；`.fitImage` 返回 nil，表示由图片决定。
    public var pointSize: CGSize? {
        switch self {
        case .fitImage: return nil
        case .a4: return CGSize(width: 595.28, height: 841.89)
        case .letter: return CGSize(width: 612, height: 792)
        }
    }
}

/// 页码范围选择方式。
public enum PageRangeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return Localized.text("All pages")
        case .custom: return Localized.text("Custom")
        }
    }
}

/// 一次转换的全部参数。Codable，直接用于持久化。
public struct ConversionSettings: Codable, Equatable, Sendable {

    // 输出目标
    /// 图片格式选择。切到 PDF 时这个值会保留，切回来还是原来那个格式。
    public var format: ImageFormat = .png
    /// 输出是否为 PDF。
    public var producesPDF: Bool = false
    /// 有损格式的压缩质量，0.05–1.0。
    public var quality: Double = 0.9

    // 分辨率
    public var resolutionMode: ResolutionMode = .dpi
    public var dpi: Double = 200
    public var scale: Double = 1
    /// 图片最长边的上限（像素）；0 表示不限制。
    ///
    /// 「发给别人的图」通常不在乎原图多大，只在乎别超过某个尺寸。
    /// 以前只能选倍数，而倍数对 48MP 和 12MP 的含义完全不同 —— 于是「邮件」预设
    /// 号称能缩小附件，实际尺寸一个像素都没变。
    public var maxLongEdge: Int = 0

    // 背景
    public var background: ImageBackground = .white

    // 页码
    public var pageRangeMode: PageRangeMode = .all
    /// 形如 "1-3,5,8-10"。
    public var pageRangeText: String = ""

    // 输出位置与命名
    public var outputDirectoryPath: String = ""
    public var perFileSubfolder: Bool = true
    public var filenamePattern: String = "{name}-{page}"
    public var padsPageNumbers: Bool = true
    public var openFolderWhenFinished: Bool = false

    /// 单张图片的最大像素数，默认 1.2 亿，防止超高 DPI 把内存吃满。
    public var maxPixels: Int = 120_000_000

    /// 并发转换的文件数上限。0 表示自动（`min(核数, 4)`）。
    public var maxConcurrentFiles: Int = 0

    // PDF 工具箱
    /// 当输入与输出都是 PDF 时执行哪个操作。
    public var pdfTool: PDFTool = .merge
    /// 拆分时每多少页一个文件。
    public var splitEveryPages: Int = 1
    /// 旋转角度。
    public var rotationAngle: RotationAngle = .clockwise90

    // 证件照
    /// 是否按证件照规格处理（尺寸、底色、按人脸构图）。
    public var idPhotoEnabled: Bool = false
    public var idPhotoSize: IDPhotoSize = .oneInch
    public var idPhotoBackground: IDPhotoBackground = .white
    /// 按人脸构图；关掉就整张图等比缩放居中。
    public var idPhotoAutoCrop: Bool = true

    // 相纸排版
    /// 把证件照在相纸上排满，供冲印后剪开。
    public var printSheetEnabled: Bool = false
    public var printSheet: PrintSheet = .sixInch
    public var printSheetMarginMM: Double = 2
    public var printSheetGapMM: Double = 1
    public var printSheetCutGuides: Bool = true

    // 图片 → PDF
    /// 多张图片是否合并成一个多页 PDF。
    public var mergeImagesIntoOnePDF: Bool = true
    public var pdfPageSize: PDFPageSize = .fitImage
    /// 页边距（点），仅在固定页面尺寸下生效。
    public var pdfMargin: Double = 24
    /// 一页放几张图；证件扫描件常用「两张一页」。
    public var pdfLayout: PDFPageLayout = .onePerPage
    /// 是否对嵌入 PDF 的图片做有损压缩；默认保留原始画质。
    public var pdfCompressesImages: Bool = false
    public var pdfImageQuality: Double = 0.85

    public init() {}

    // MARK: - 派生值

    /// 当前目标。
    public var target: OutputTarget {
        get { producesPDF ? .pdf : .image(format) }
        set {
            switch newValue {
            case .pdf:
                producesPDF = true
            case let .image(newFormat):
                producesPDF = false
                format = newFormat
            }
        }
    }

    /// 图片输入使用的缩放系数（不知道原图尺寸时用这个）。
    ///
    /// 只看 `scale`，**不再把 DPI 当成放大倍数**。
    /// 之前沿用了 PDF 的 72 DPI 约定，于是默认的 200 DPI 会把图片放大 2.78 倍 ——
    /// 一张 4800 万像素的手机照片会瞬间变成 3.76 亿像素，直接撞上安全上限。
    /// 图片本来就有自己的像素尺寸，放大只在用户明确要求时才做。
    public var imageScale: Double {
        max(0.05, scale)
    }

    /// 图片实际使用的缩放系数：先按倍数，再受最长边约束。
    ///
    /// 两者取小，所以最长边只会缩不会放：本来就不大的图不会被意外放大。
    public func imageScale(for info: DocumentInfo) -> Double {
        let requested = imageScale
        guard maxLongEdge > 0 else { return requested }
        let longest = max(info.displaySize.width, info.displaySize.height)
        guard longest > 0 else { return requested }
        return min(requested, Double(maxLongEdge) / Double(longest))
    }

    /// 按输出目标估算首张图的像素尺寸。
    ///
    /// 每条链路都要如实反映：证件照与相纸排版的尺寸由规格决定，
    /// 而不是「输入尺寸 × 缩放」——这正是之前误报「超过安全上限」的原因。
    public func estimatedPixelSize(for info: DocumentInfo) -> (width: Int, height: Int)? {
        switch info.kind {
        case .image:
            if idPhotoEnabled {
                if printSheetEnabled { return printSheet.pixelSize(dpi: dpi) }
                return idPhotoSize.pixelSize(dpi: dpi)
            }
            return Self.scaled(info.displaySize, by: imageScale(for: info))
        case .pdf:
            return Self.scaled(info.displaySize, by: effectiveScale)
        default:
            return nil
        }
    }

    /// 估算值是否超出安全上限（超过就说明这个参数组合会被拒绝）。
    public func estimateExceedsLimit(for info: DocumentInfo) -> Bool {
        guard let pixels = estimatedPixelSize(for: info) else { return false }
        return pixels.width * pixels.height > maxPixels
    }

    private static func scaled(_ size: CGSize, by scale: Double) -> (width: Int, height: Int) {
        (
            max(Int((size.width * scale).rounded()), 1),
            max(Int((size.height * scale).rounded()), 1)
        )
    }

    /// 渲染时使用的缩放系数（相对 PDF 的 72pt/inch）。
    public var effectiveScale: Double {
        switch resolutionMode {
        case .dpi: return max(0.05, dpi / 72.0)
        case .scale: return max(0.05, scale)
        }
    }

    /// 解析后的输出目录；未指定时用桌面。
    public var resolvedOutputDirectory: URL {
        guard !outputDirectoryPath.isEmpty else {
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: (outputDirectoryPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// 给定页数后，本次要输出的页码列表。
    public func pages(outOf pageCount: Int) -> [Int] {
        switch pageRangeMode {
        case .all:
            return pageCount > 0 ? Array(1...pageCount) : []
        case .custom:
            return PageRangeParser.parse(pageRangeText, pageCount: pageCount)
        }
    }

    /// 保证背景与格式能力一致：不支持透明的格式不允许留在 transparent。
    public mutating func normalizeForFormat() {
        if background == .transparent && !format.supportsAlpha {
            background = .white
        }
    }
}
