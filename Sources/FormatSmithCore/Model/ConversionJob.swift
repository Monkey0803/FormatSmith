import CoreGraphics
import Foundation

/// 队列里的一个输入文件。
///
/// 只描述「是什么」，不携带任何 UI 状态；界面状态由 App 层包一层。
public struct SourceDocument: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let url: URL
    public let kind: InputKind
    /// PDF 的页数；图片为 1；文档在转换前未知，为 0。
    public var pageCount: Int
    /// PDF 首页的显示尺寸（点）或图片的像素尺寸。
    public var size: CGSize
    public var byteSize: Int64
    /// 已知的页面尺寸集合为空时，用这个值做预估。
    public var displayName: String

    public init(
        id: UUID = UUID(),
        url: URL,
        kind: InputKind,
        pageCount: Int = 0,
        size: CGSize = .zero,
        byteSize: Int64 = 0,
        displayName: String? = nil
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.pageCount = pageCount
        self.size = size
        self.byteSize = byteSize
        self.displayName = displayName ?? url.deletingPathExtension().lastPathComponent
    }

    /// 描述这个输入的信息，供设置判断用。
    public var info: DocumentInfo {
        DocumentInfo(kind: kind, pageCount: pageCount, displaySize: size)
    }

    /// 套用探测结果，保留原有 id（队列里已经用它标识这一项）。
    public func with(info: DocumentInfo) -> SourceDocument {
        SourceDocument(
            id: id,
            url: url,
            kind: info.kind,
            pageCount: info.pageCount,
            size: info.displaySize,
            byteSize: byteSize,
            displayName: displayName
        )
    }

    /// 从文件系统读入，只取元信息，不解码像素。
    ///
    /// **尺寸与页数一并探测。** 这两项决定了输出尺寸的估算与「最长边」这类约束，
    /// 而引擎干活时只认 `SourceDocument` 里的值 —— 如果这里不填，
    /// 调用方（比如命令行）就会拿到一份「尺寸为 0」的输入，
    /// 于是所有与尺寸有关的设置静默失效。探测本身只读元数据，代价很低。
    public static func make(from url: URL) -> SourceDocument {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let info = ConversionEngine.inspect(url)
        return SourceDocument(
            url: url,
            kind: info.kind,
            pageCount: info.pageCount,
            size: info.displaySize,
            byteSize: byteSize
        )
    }
}

/// 单个文件的转换结果。
public struct ConversionResult: Sendable {
    /// 主要输入（合并输出时是第一个输入）。
    public let documentID: UUID
    /// 合并成一份输出时，参与的全部输入。
    public var includedDocumentIDs: [UUID] = []
    /// 转换过程中的提示（例如「没检测到人像，已保留原背景」），供界面展示。
    public var notes: [String] = []
    public let outputFiles: [URL]
    public let outputFolder: URL?
    /// 实际写出的张数 / 页数。
    public let producedCount: Int
    public let error: ConversionError?
    public let duration: TimeInterval

    public var isSuccess: Bool { error == nil }

    public init(
        documentID: UUID,
        outputFiles: [URL] = [],
        outputFolder: URL? = nil,
        producedCount: Int = 0,
        error: ConversionError? = nil,
        duration: TimeInterval = 0,
        includedDocumentIDs: [UUID] = [],
        notes: [String] = []
    ) {
        self.documentID = documentID
        self.outputFiles = outputFiles
        self.outputFolder = outputFolder
        self.producedCount = producedCount
        self.error = error
        self.duration = duration
        self.includedDocumentIDs = includedDocumentIDs.isEmpty ? [documentID] : includedDocumentIDs
        self.notes = notes
    }
}

/// 转换进度回调。所有回调都在工作线程被调用，调用方负责切回主线程。
public struct ConversionProgress: Sendable {
    /// 这条进度属于哪个输入。并发转换时用它区分来源。
    public let documentID: UUID?
    /// 当前文件已完成的页数 / 张数。
    public let completedUnits: Int
    /// 当前文件的总页数 / 张数。
    public let totalUnits: Int
    /// 正在处理第几个文件（0 基）。
    public let fileIndex: Int
    public let fileCount: Int
    /// 0–1 的整体进度。
    public var fraction: Double {
        guard fileCount > 0 else { return 0 }
        let perFile = 1.0 / Double(fileCount)
        let within = totalUnits > 0 ? Double(completedUnits) / Double(totalUnits) : 0
        return min(1, Double(fileIndex) * perFile + within * perFile)
    }

    public init(
        completedUnits: Int,
        totalUnits: Int,
        fileIndex: Int,
        fileCount: Int,
        documentID: UUID? = nil
    ) {
        self.documentID = documentID
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.fileIndex = fileIndex
        self.fileCount = fileCount
    }
}

/// 转换进度与结果的回调集合。
public struct ConversionObserver: Sendable {
    public var onProgress: (@Sendable (ConversionProgress) -> Void)?
    public var onFileFinished: (@Sendable (ConversionResult) -> Void)?

    public init(
        onProgress: (@Sendable (ConversionProgress) -> Void)? = nil,
        onFileFinished: (@Sendable (ConversionResult) -> Void)? = nil
    ) {
        self.onProgress = onProgress
        self.onFileFinished = onFileFinished
    }

    public static let none = ConversionObserver()
}
