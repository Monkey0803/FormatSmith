import Foundation

/// 一项设置在当前的输入与目标下到底生不生效。
///
/// 存在的理由是一类反复出现的问题：**设置生效了，界面却没地方看**，或者反过来
/// **界面显示了，调了半天其实不起作用**。已经发生过的三次：
/// - 证件照设置在 PDF 目标下被隐藏，但仍然生效 → 用户看到输出多了一层蓝底却找不到开关
/// - 相纸排版在 PDF 目标下照常显示，但它产出的是图片，对 PDF 没有任何影响
/// - 分辨率与背景在证件照模式下被隐藏（因为那时由证件照规格决定）
///
/// 所以「显示」和「生效」必须来自同一处判断，而且这个判断要能被测试。
/// 判断规则以引擎的实际行为为准：`SettingsScopeTests` 里会逐条验证
/// 「被判为不生效的设置，改动之后产出必须一模一样」。
public struct SettingsScope: Equatable, Sendable {

    /// 会被判断生效性的设置项。
    public enum Feature: String, CaseIterable, Sendable {
        /// 证件照规格（尺寸、底色、按人脸构图）
        case idPhoto
        /// 相纸排版
        case photoSheet
        /// 分辨率（倍数 / DPI）
        case resolution
        /// 图片最长边
        case maxLongEdge
        /// 透明区域铺什么底色
        case background
        /// 图片质量
        case quality
        /// 页码范围
        case pageRange
        /// PDF 工具箱（合并 / 拆分 / 提取 / 旋转 / 压缩）
        case pdfTool
        /// PDF 每页排几张
        case pdfLayout
        /// PDF 内嵌图片压缩
        case pdfCompression
    }

    public enum State: Equatable, Sendable {
        /// 对这次转换有影响
        case active
        /// 不起作用；界面不该显示它
        case inactive

        public var isActive: Bool { self == .active }
    }

    // MARK: - 输入与目标

    public let hasImages: Bool
    public let hasPDFs: Bool
    public let hasDocuments: Bool
    public let targetIsPDF: Bool
    /// 是否有输入真的有多页（决定页码范围是否有意义）
    public let hasMultiPageInput: Bool
    public let idPhotoEnabled: Bool
    public let pdfTool: PDFTool

    public init(
        documentKinds: [InputKind],
        pageCounts: [Int] = [],
        target: OutputTarget,
        settings: ConversionSettings
    ) {
        hasImages = documentKinds.contains { $0.isImage }
        hasPDFs = documentKinds.contains { $0 == .pdf }
        hasDocuments = documentKinds.contains { $0.isDocument }
        targetIsPDF = target.isPDF
        hasMultiPageInput = pageCounts.contains { $0 > 1 }
        idPhotoEnabled = settings.idPhotoEnabled
        pdfTool = settings.pdfTool
    }

    /// 只有目标与输入，没有设置时的便捷构造。
    public init(documentKinds: [InputKind], target: OutputTarget) {
        self.init(
            documentKinds: documentKinds,
            target: target,
            settings: ConversionSettings()
        )
    }

    // MARK: - 判断

    public func state(of feature: Feature) -> State {
        // 没有对应输入时，与它相关的设置一律不生效
        switch feature {
        case .idPhoto:
            // 证件照只处理图片输入；但输出可以是图片，也可以是 PDF
            // （图片 → PDF 时同样按证件照规格出图，所以这里不能按目标排除）
            return hasImages ? .active : .inactive

        case .photoSheet:
            // 相纸排版产出的是图片，PDF 目标下用不上
            return hasImages && !targetIsPDF && idPhotoEnabled ? .active : .inactive

        case .resolution:
            // PDF 只有「渲染成图片」时才谈分辨率；PDF 工具箱与文档 → PDF 都用不到它
            return hasImages || (hasPDFs && !targetIsPDF) ? .active : .inactive

        case .maxLongEdge:
            // 证件照的尺寸由规格决定，最长边对它没有意义
            return hasImages && !idPhotoEnabled ? .active : .inactive

        case .background:
            // 证件照模式下底色由证件照规格决定，这里的「透明铺底」不参与
            return hasImages && !idPhotoEnabled ? .active : .inactive

        case .quality:
            return (hasImages && !idPhotoEnabled || !targetIsPDF) ? .active : .inactive

        case .pageRange:
            // 页码只在这两处被引擎读取：
            //   PDF → 图片（按页渲染），以及工具箱里的「提取页」。
            // 合并、压缩、旋转都是把整份文件重新组织，给它们显示页码只会误导。
            guard hasPDFs, hasMultiPageInput else { return .inactive }
            if !targetIsPDF { return .active }
            return pdfTool == .extract ? .active : .inactive

        case .pdfTool:
            return hasPDFs && targetIsPDF ? .active : .inactive

        case .pdfLayout:
            return hasImages && targetIsPDF ? .active : .inactive

        case .pdfCompression:
            return targetIsPDF ? .active : .inactive
        }
    }

    public func isActive(_ feature: Feature) -> Bool {
        state(of: feature).isActive
    }
}

extension InputKind {
    /// 需要走文档转换管线（Office / HTML / Markdown / 纯文本）的输入。
    var isDocument: Bool {
        switch self {
        case .office, .html, .markdown, .plainText: return true
        default: return false
        }
    }
}
