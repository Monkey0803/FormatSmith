import Foundation
import UniformTypeIdentifiers

/// 输入文件的类型判定。
///
/// 这是「全面转换器」路由的起点：先知道手里是什么，再决定用哪条管线。
public enum InputKind: Equatable, Sendable {
    case pdf
    case image(identifier: String)
    /// Word / Excel / PowerPoint / OpenDocument / RTF —— 交给 LibreOffice。
    case office(identifier: String)
    case html
    case markdown
    case plainText
    case unknown(identifier: String?)

    // MARK: - 判定

    /// 依据文件的实际 UTType 判定，拿不到再退回扩展名。
    public static func detect(url: URL) -> InputKind {
        let identifier = contentTypeIdentifier(of: url)
        return classify(identifier: identifier, fileExtension: url.pathExtension)
    }

    /// 仅凭类型标识符 / 扩展名判定（便于测试，不需要真实文件）。
    public static func classify(identifier: String?, fileExtension: String) -> InputKind {
        if let identifier {
            if identifier == "com.adobe.pdf" { return .pdf }
            if officeIdentifiers.contains(identifier) { return .office(identifier: identifier) }
            if identifier == "public.html" || identifier == "public.xhtml" { return .html }
            if markdownIdentifiers.contains(identifier) { return .markdown }
            if identifier == "public.plain-text" || identifier == "public.utf8-plain-text" { return .plainText }
            if FormatRegistry.readableIdentifiers.contains(identifier) {
                return .image(identifier: identifier)
            }
        }

        switch fileExtension.lowercased() {
        case "pdf": return .pdf
        case "html", "htm", "xhtml": return .html
        case "md", "markdown", "mdown", "mkd": return .markdown
        case "txt": return .plainText
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf":
            return .office(identifier: identifier ?? "unknown")
        default:
            if let identifier, FormatRegistry.readableIdentifiers.contains(identifier) {
                return .image(identifier: identifier)
            }
            // 没有 UTType 时按扩展名反查，否则 .png 这类只有后缀的输入会被判成 unknown。
            if !fileExtension.isEmpty,
                let type = UTType(filenameExtension: fileExtension),
                FormatRegistry.readableIdentifiers.contains(type.identifier)
            {
                return .image(identifier: type.identifier)
            }
            return .unknown(identifier: identifier)
        }
    }

    private static func contentTypeIdentifier(of url: URL) -> String? {
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
            let type = values.contentType
        {
            return type.identifier
        }
        guard !url.pathExtension.isEmpty else { return nil }
        return UTType(filenameExtension: url.pathExtension)?.identifier
    }

    // MARK: - 属性

    /// 是否属于「文件本身就是位图/矢量图」的一类（含 PDF 之外的图片）。
    public var isImage: Bool {
        if case .image = self { return true }
        return false
    }

    public var imageIdentifier: String? {
        if case let .image(identifier) = self { return identifier }
        return nil
    }

    public var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case let .image(identifier): return FormatRegistry.displayName(for: identifier)
        case let .office(identifier): return FormatRegistry.displayName(for: identifier)
        case .html: return "HTML"
        case .markdown: return "Markdown"
        case .plainText: return Localized.text("Text")
        case let .unknown(identifier): return identifier ?? Localized.text("Unknown")
        }
    }

    /// 拖进队列时该显示成哪一类图标。
    public enum Icon: Sendable {
        case pdf
        case image
        case document
        case unknown
    }

    public var icon: Icon {
        switch self {
        case .pdf: return .pdf
        case .image: return .image
        case .office, .html, .markdown, .plainText: return .document
        case .unknown: return .unknown
        }
    }

    // MARK: - 类型集合

    static let officeIdentifiers: Set<String> = [
        "org.openxmlformats.wordprocessingml.document",
        "org.openxmlformats.spreadsheetml.sheet",
        "org.openxmlformats.presentationml.presentation",
        "com.microsoft.word.doc",
        "com.microsoft.excel.xls",
        "com.microsoft.powerpoint.ppt",
        "org.oasis-open.opendocument.text",
        "org.oasis-open.opendocument.spreadsheet",
        "org.oasis-open.opendocument.presentation",
        "public.rtf",
    ]

    static let markdownIdentifiers: Set<String> = [
        "net.daringfireball.markdown",
        "public.markdown",
    ]
}
