import Foundation

/// PDF 工具箱里的操作。
///
/// 这一组和「格式转换」是两回事：输入和输出都是 PDF，改变的是文档结构。
public enum PDFTool: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 多个 PDF 首尾相接合成一个。
    case merge
    /// 每 N 页拆成一个独立的 PDF。
    case split
    /// 只保留指定页面，输出一个 PDF。
    case extract
    /// 所有页面旋转若干度。
    case rotate
    /// 重新以较低分辨率栅格化，换取更小的文件。
    case compress

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .merge: return Localized.text("Merge")
        case .split: return Localized.text("Split")
        case .extract: return Localized.text("Extract pages")
        case .rotate: return Localized.text("Rotate")
        case .compress: return Localized.text("Compress")
        }
    }

    public var summary: String {
        switch self {
        case .merge: return Localized.text("Join several PDFs into one document.")
        case .split: return Localized.text("Write a separate PDF every N pages.")
        case .extract: return Localized.text("Keep only the pages you list.")
        case .rotate: return Localized.text("Turn every page by a fixed angle.")
        case .compress: return Localized.text("Rasterise pages at a lower resolution to shrink the file.")
        }
    }

    /// 是否会丢失文本层与矢量信息（压缩会）。
    public var isLossy: Bool {
        self == .compress
    }

    /// 该操作是否需要把整批输入当成一个文档处理。
    public var operatesOnWholeBatch: Bool {
        self == .merge
    }
}

/// 旋转角度。
public enum RotationAngle: Int, Codable, CaseIterable, Identifiable, Sendable {
    case clockwise90 = 90
    case upsideDown = 180
    case counterClockwise90 = 270

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .clockwise90: return Localized.text("90° clockwise")
        case .upsideDown: return Localized.text("180°")
        case .counterClockwise90: return Localized.text("90° counter-clockwise")
        }
    }
}
