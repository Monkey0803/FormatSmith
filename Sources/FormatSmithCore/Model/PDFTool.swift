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
    /// 按给定顺序重排页面；没列出的页按原顺序接在后面。
    case reorder
    /// 删掉指定页面，其余保持原顺序。
    case delete
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
        case .reorder: return Localized.text("Reorder pages")
        case .delete: return Localized.text("Delete pages")
        case .rotate: return Localized.text("Rotate")
        case .compress: return Localized.text("Compress")
        }
    }

    public var summary: String {
        switch self {
        case .merge: return Localized.text("Join several PDFs into one document.")
        case .split: return Localized.text("Write a separate PDF every N pages.")
        case .extract: return Localized.text("Keep only the pages you list.")
        case .reorder: return Localized.text("Move the pages you list to the front; the rest follow in order.")
        case .delete: return Localized.text("Drop the pages you list; nothing else moves.")
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

    /// 这个操作按「页码清单」工作（提取 / 重排 / 删除）。
    public var usesPageSelection: Bool {
        switch self {
        case .extract, .reorder, .delete: return true
        default: return false
        }
    }

    /// 页码清单的含义：要保留、要排到前面、还是要删掉。
    public var pageSelectionMeaning: PageSelectionMeaning? {
        switch self {
        case .extract: return .keep
        case .reorder: return .front
        case .delete: return .remove
        default: return nil
        }
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

/// 页码清单在某个工具下的含义。
public enum PageSelectionMeaning: Equatable, Sendable {
    /// 只保留这些页
    case keep
    /// 把这些页排到最前，其余按原顺序跟随
    case front
    /// 删除这些页
    case remove
}
