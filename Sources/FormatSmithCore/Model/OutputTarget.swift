import Foundation

/// 用户想把文件变成什么。
public enum OutputTarget: Hashable, Sendable {
    /// 导出成这批图片格式里的某一种。
    case image(ImageFormat)
    /// 导出成一个 PDF。
    case pdf

    public var displayName: String {
        switch self {
        case let .image(format): return format.displayName
        case .pdf: return "PDF"
        }
    }

    public var isPDF: Bool {
        self == .pdf
    }

    public var imageFormat: ImageFormat? {
        if case let .image(format) = self { return format }
        return nil
    }
}

/// 一个输入 + 一个目标，应该走哪条管线。
///
/// 路由和「能不能做」是两件事：`kind` 说走哪条路，`availability` 说这条路现在通不通。
/// UI 用前者组织界面，用后者决定置灰与提示文案 —— 用户看到的永远是「为什么不行」，
/// 而不是一句笼统的失败。
public struct ConversionPlan: Equatable, Sendable {

    public enum Kind: Equatable, Sendable {
        /// PDF 的每一页 → 一张图片
        case pdfPagesToImages
        /// 图片 → 另一种图片格式（可缩放）
        case imagesToImages
        /// 单张图片 → 一个 PDF
        case imageToPDF
        /// 多张图片 → 一个多页 PDF
        case imagesToOnePDF
        /// 文档（Office / HTML / Markdown）→ PDF
        case documentToPDF
        /// PDF 工具箱：合并、拆分、提取、旋转、压缩
        case pdfToolbox
    }

    public enum Availability: Equatable, Sendable {
        case ready
        /// 路线已定，但引擎还没实现（用于把路线图公开在界面上）
        case notImplementedYet
        /// 这个组合本身不成立，附上可展示的原因
        case unsupported(String)
    }

    public let kind: Kind
    public let availability: Availability

    public init(kind: Kind, availability: Availability = .ready) {
        self.kind = kind
        self.availability = availability
    }

    public var isReady: Bool { availability == .ready }

    public var unavailableReason: String? {
        switch availability {
        case .ready: return nil
        case .notImplementedYet: return Localized.text("Not available in this build yet.")
        case let .unsupported(reason): return reason
        }
    }
}

/// 输入 × 目标 的路由表。
public enum ConversionRouter {

    /// 当队列里同时存在多种输入时，以「能否全部处理」为准取最严格的结果。
    public static func plan(input: InputKind, target: OutputTarget) -> ConversionPlan {
        switch (input, target) {

        // PDF → 图片
        case (.pdf, .image(let format)):
            guard format.isWritableBySystem else {
                return ConversionPlan(
                    kind: .pdfPagesToImages,
                    availability: .unsupported(Localized.text("This Mac cannot write %@ files.", format.displayName))
                )
            }
            return ConversionPlan(kind: .pdfPagesToImages)

        // PDF → PDF：合并 / 拆分 / 压缩等，属于工具箱
        case (.pdf, .pdf):
            return ConversionPlan(kind: .pdfToolbox)

        // 图片 → 图片
        case (.image(let identifier), .image(let format)):
            guard format.isWritableBySystem else {
                return ConversionPlan(
                    kind: .imagesToImages,
                    availability: .unsupported(Localized.text("This Mac cannot write %@ files.", format.displayName))
                )
            }
            if identifier == format.identifier {
                // 同格式再编码没有意义，但缩放仍然是有效需求，所以只作为提示而非错误。
                return ConversionPlan(kind: .imagesToImages)
            }
            return ConversionPlan(kind: .imagesToImages)

        // 图片 → PDF
        case (.image, .pdf):
            return ConversionPlan(kind: .imageToPDF)

        // 文档 → PDF
        case (.office, .pdf), (.html, .pdf), (.markdown, .pdf), (.plainText, .pdf):
            return ConversionPlan(kind: .documentToPDF, availability: .notImplementedYet)

        // 文档 → 图片：必须先经过 PDF
        case (.office, .image), (.html, .image), (.markdown, .image), (.plainText, .image):
            return ConversionPlan(
                kind: .documentToPDF,
                availability: .unsupported(
                    Localized.text("Convert documents to PDF first, then to images.")
                )
            )

        case (.unknown, _):
            return ConversionPlan(
                kind: .pdfPagesToImages,
                availability: .unsupported(Localized.text("This file type is not supported."))
            )
        }
    }

    /// 队列里能否整体执行：只要有任意一项不可行，就返回它的原因。
    public static func batchAvailability(
        inputs: [InputKind],
        target: OutputTarget
    ) -> (plan: ConversionPlan, unsupportedReasons: [String]) {
        guard let first = inputs.first else {
            return (ConversionPlan(kind: .pdfPagesToImages), [])
        }

        var reasons: [String] = []
        var resolvedPlan = plan(input: first, target: target)
        for input in inputs {
            let plan = plan(input: input, target: target)
            if let reason = plan.unavailableReason {
                reasons.append("\(input.displayName): \(reason)")
            }
            // 以第一个可行项的路线作为队列主路线
            if plan.isReady { resolvedPlan = plan }
        }
        return (resolvedPlan, reasons)
    }

    /// 一批输入 + 目标，应该按「每个文件一套输出」还是「合并成一个 PDF」来执行。
    public static func strategy(
        inputs: [InputKind],
        target: OutputTarget,
        mergesImages: Bool
    ) -> ConversionPlan.Kind? {
        guard let first = inputs.first else { return nil }
        let plan = self.plan(input: first, target: target)
        guard plan.isReady else { return nil }

        // 一批混合输入（例如同时拖进 PDF 和图片）无法用单一管线描述，
        // 与其猜一个，不如让调用方按文件逐个执行。
        let distinctKinds = Set(inputs.map { self.plan(input: $0, target: target).kind })
        guard distinctKinds.count == 1 else { return nil }

        if plan.kind == .imageToPDF {
            let allImages = inputs.allSatisfy(\.isImage)
            if allImages && mergesImages && inputs.count > 1 {
                return .imagesToOnePDF
            }
            return .imageToPDF
        }
        return plan.kind
    }
}
