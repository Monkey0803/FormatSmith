import Foundation

/// 图片写进 PDF 时，一页放几张。
///
/// 「身份证正反面合成一页」这类需求靠它：两张图上下排在同一张 A4 上，
/// 上传时就是一个文件、一页，不用再翻页。
public enum PDFPageLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case onePerPage
    case twoPerPage

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .onePerPage: return Localized.text("One per page")
        case .twoPerPage: return Localized.text("Two per page")
        }
    }

    public var summary: String {
        switch self {
        case .onePerPage: return Localized.text("Each image gets its own page.")
        case .twoPerPage: return Localized.text("Two images stacked on one page — handy for ID scans.")
        }
    }

    public var imagesPerPage: Int {
        switch self {
        case .onePerPage: return 1
        case .twoPerPage: return 2
        }
    }

    public func pageCount(forImageCount count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Int(ceil(Double(count) / Double(imagesPerPage)))
    }
}
