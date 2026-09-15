import AppKit
import Combine
import FormatSmithCore
import Foundation
import SwiftUI

/// 队列里一项的界面状态。
enum ItemStatus: Equatable {
    case loading
    case ready
    case converting(done: Int, total: Int)
    case finished(files: Int, folder: URL?)
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .finished, .failed: return true
        default: return false
        }
    }
}

/// 输入文件 + 界面状态。
struct QueueItem: Identifiable, Equatable {
    var document: SourceDocument
    var status: ItemStatus = .loading
    var thumbnail: NSImage?

    var id: UUID { document.id }
    var url: URL { document.url }
    var name: String { document.displayName }

    static func == (lhs: QueueItem, rhs: QueueItem) -> Bool {
        lhs.document == rhs.document && lhs.status == rhs.status
    }
}

@MainActor
final class ConverterModel: ObservableObject {

    @Published var items: [QueueItem] = []
    @Published var settings: ConversionSettings {
        didSet { persistSettings() }
    }
    @Published var isConverting = false
    @Published var overallProgress: Double = 0
    @Published var statusText = Localized.text("Drop files here, or click “Choose Files” to start.")
    @Published var lastOutputFolder: URL?
    /// 是否展开长尾格式。
    @Published var showsAllFormats = false

    private let cancellation = CancellationFlag()
    private let defaultsKey = "FormatSmith.settings.v2"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(ConversionSettings.self, from: data)
        {
            settings = decoded
        } else {
            settings = ConversionSettings()
        }
        if !settings.format.isWritableBySystem {
            settings.format = .png
        }
        settings.normalizeForFormat()
    }

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: - 目标与能力

    var target: OutputTarget {
        get { settings.target }
        set {
            settings.target = newValue
            settings.normalizeForFormat()
        }
    }

    var availableFormats: [ImageFormat] {
        showsAllFormats ? FormatRegistry.allWritable : FormatRegistry.curated
    }

    /// 队列里实际会参与转换的项。
    var convertibleItems: [QueueItem] {
        items.filter { $0.document.pageCount > 0 }
    }

    var queueKinds: [InputKind] {
        convertibleItems.map(\.document.kind)
    }

    var hasPDFInputs: Bool {
        queueKinds.contains(.pdf)
    }

    var hasImageInputs: Bool {
        queueKinds.contains(where: \.isImage)
    }

    var allInputsAreImages: Bool {
        let kinds = queueKinds
        return !kinds.isEmpty && kinds.allSatisfy(\.isImage)
    }

    /// 当前目标下这批文件整体是否可行；不可行时给出逐项原因。
    var unavailableReasons: [String] {
        let kinds = queueKinds
        guard !kinds.isEmpty else { return [] }
        return ConversionRouter.batchAvailability(inputs: kinds, target: target).unsupportedReasons
    }

    /// 当前队列需要、但本机没装的外部工具。
    ///
    /// 只查文件系统（不启动进程），可以安全地在界面里算。
    var missingRequiredTools: [ExternalTool] {
        var missing: [ExternalTool] = []
        let needsOffice = queueKinds.contains { kind in
            if case .office = kind { return true }
            return false
        }
        if needsOffice {
            let libreOffice = ToolLocator.libreOffice()
            if !libreOffice.isAvailable { missing.append(libreOffice) }
        }
        return missing
    }

    /// 本机已探测到的可选工具（用于「依赖」一栏的说明）。
    var detectedTools: [ExternalTool] {
        ToolLocator.all().filter(\.isAvailable)
    }

    /// 这批文件会走哪条管线。
    var plannedKind: ConversionPlan.Kind? {
        let kinds = queueKinds
        guard !kinds.isEmpty else { return nil }
        return ConversionRouter.strategy(
            inputs: kinds,
            target: target,
            mergesImages: settings.mergeImagesIntoOnePDF
        )
    }

    /// 底部主按钮的标题：直接说清楚这次会做什么。
    var actionTitle: String {
        if model_isPDFTarget {
            if hasDocumentInputs, !hasPDFInputs, !hasImageInputs {
                return Localized.text("Create PDF")
            }
            if hasPDFInputs { return settings.pdfTool.displayName }
            return Localized.text("Create PDF")
        }
        return Localized.text("Convert Now")
    }

    /// 队列里是否有文档类输入（Office / HTML / Markdown / 纯文本）。
    var hasDocumentInputs: Bool {
        queueKinds.contains { kind in
            switch kind {
            case .office, .html, .markdown, .plainText: return true
            default: return false
            }
        }
    }

    private var model_isPDFTarget: Bool { target.isPDF }

    var canConvert: Bool {
        !items.isEmpty && !isConverting && !convertibleItems.isEmpty && unavailableReasons.isEmpty
    }

    // MARK: - 队列

    func add(urls: [URL]) {
        let incoming = expand(urls: urls)
        var known = Set(items.map { $0.url.standardizedFileURL.path })
        var added: [QueueItem] = []

        for url in incoming {
            let key = url.standardizedFileURL.path
            guard !known.contains(key) else { continue }
            known.insert(key)
            added.append(QueueItem(document: .make(from: url)))
        }

        DebugLog.log("add(urls: \(urls.count)) → 新增 \(added.count) 项")
        guard !added.isEmpty else { return }
        items.append(contentsOf: added)
        statusText = Localized.text("Added %d file(s).", added.count)
        loadMetadata(for: added.map(\.id))
    }

    /// 展开拖入的目录，收集支持的输入文件（含子目录）。
    private func expand(urls: [URL]) -> [URL] {
        let manager = FileManager.default
        var result: [URL] = []

        for url in urls {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                let enumerator = manager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let child = enumerator?.nextObject() as? URL, isSupported(child) {
                    result.append(child)
                }
            } else if isSupported(url) {
                result.append(url)
            } else {
                statusText = Localized.text("Ignored unsupported file: %@", url.lastPathComponent)
            }
        }

        return result.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// 当前支持的输入：PDF、图片，以及能转成 PDF 的文档。
    private func isSupported(_ url: URL) -> Bool {
        switch InputKind.detect(url: url) {
        case .pdf, .image, .office, .html, .markdown, .plainText: return true
        case .unknown: return false
        }
    }

    private func loadMetadata(for ids: [UUID]) {
        for id in ids {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            let url = items[index].url
            let kind = items[index].document.kind
            items[index].status = .loading

            Task { @MainActor in
                let loaded = await Task.detached(priority: .utility) { () -> (DocumentInfo, NSImage?) in
                    let info = ConversionEngine.inspect(url)
                    let cgImage: CGImage? = {
                        switch kind {
                        case .pdf: return PDFRasterizer.thumbnail(for: url, maxSize: 128)
                        case .image: return ImageDecoder.thumbnail(url: url, maxSize: 128)
                        default: return nil  // 文档类没有便宜的缩略图路径
                        }
                    }()
                    return (
                        info, cgImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                    )
                }.value

                guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[idx].document.pageCount = loaded.0.pageCount
                self.items[idx].document.size = loaded.0.displaySize
                self.items[idx].thumbnail = loaded.1
                self.items[idx].status =
                    loaded.0.pageCount > 0
                    ? .ready
                    : .failed(Localized.text("Could not read this file."))
                DebugLog.log(
                    "读取 \(url.lastPathComponent): \(loaded.0.kind.displayName), \(loaded.0.pageCount) 页/帧, "
                        + "\(Int(loaded.0.displaySize.width))×\(Int(loaded.0.displaySize.height))"
                )
            }
        }
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        if items.isEmpty {
            statusText = Localized.text("Drop files here, or click “Choose Files” to start.")
        }
    }

    func removeAll() {
        guard !isConverting else { return }
        items.removeAll()
        overallProgress = 0
        statusText = Localized.text("Drop files here, or click “Choose Files” to start.")
    }

    func clearFinished() {
        guard !isConverting else { return }
        items.removeAll { $0.status.isTerminal }
    }

    // MARK: - 面板

    func chooseInputFiles() {
        let panel = NSOpenPanel()
        panel.title = Localized.text("Choose files")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf, .image, .html, .plainText, .rtf]
        if panel.runModal() == .OK {
            add(urls: panel.urls)
        }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = Localized.text("Choose output folder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.resolvedOutputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputDirectoryPath = url.path
        }
    }

    func resetOutputDirectory() {
        settings.outputDirectoryPath = ""
    }

    func openOutputFolder() {
        let folder = lastOutputFolder ?? settings.resolvedOutputDirectory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) else {
            statusText = Localized.text("Output folder does not exist: %@", folder.path)
            return
        }
        NSWorkspace.shared.open(folder)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 转换

    func startConversion() {
        guard !isConverting else { return }

        let queue = convertibleItems
        guard !queue.isEmpty else {
            statusText = Localized.text("There is nothing to convert.")
            return
        }

        let reasons = unavailableReasons
        guard reasons.isEmpty else {
            statusText = reasons[0]
            return
        }

        let root = settings.resolvedOutputDirectory
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            statusText = Localized.text("Output folder is not writable: %@", error.localizedDescription)
            return
        }

        cancellation.reset()
        isConverting = true
        overallProgress = 0
        lastOutputFolder = nil
        for item in queue {
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].status = .ready
            }
        }

        let snapshot = settings
        let flag = cancellation
        let strategy = ConversionRouter.strategy(
            inputs: queue.map(\.document.kind),
            target: snapshot.target,
            mergesImages: snapshot.mergeImagesIntoOnePDF
        )

        // 把这一轮要用的数据固定下来，避免转换过程中队列变化影响遍历。
        let jobs = queue.map { ($0.id, $0.document) }

        Task { @MainActor in
            if strategy == .imagesToOnePDF {
                await self.runMerge(jobs: jobs, settings: snapshot, cancellation: flag, root: root)
            } else if strategy == .pdfToolbox, snapshot.pdfTool.operatesOnWholeBatch, jobs.count > 1 {
                await self.runPDFToolBatch(jobs: jobs, settings: snapshot, cancellation: flag, root: root)
            } else {
                await self.runIndividually(jobs: jobs, settings: snapshot, cancellation: flag, root: root)
            }
        }
    }

    /// 每个文件各自产出（PDF → 图片、图片 → 图片、单图 → PDF）。
    private func runIndividually(
        jobs: [(UUID, SourceDocument)],
        settings snapshot: ConversionSettings,
        cancellation flag: CancellationFlag,
        root: URL
    ) async {
        var finished = 0
        var failures = 0
        var lastFolder: URL?

        for (index, job) in jobs.enumerated() {
            if flag.isCancelled { break }
            let (documentID, document) = job

            markConverting(itemID: documentID, done: 0, total: max(document.pageCount, 1))
            statusText = Localized.text("Converting: %@", document.displayName)

            let observer = ConversionObserver(onProgress: { progress in
                Task { @MainActor in
                    guard let idx = self.items.firstIndex(where: { $0.id == documentID }) else { return }
                    self.items[idx].status = .converting(done: progress.completedUnits, total: progress.totalUnits)
                    self.overallProgress = progress.fraction
                }
            })

            let result = await Task.detached(priority: .userInitiated) {
                ConversionEngine.convert(
                    document: document,
                    target: snapshot.target,
                    settings: snapshot,
                    cancellation: flag,
                    observer: observer,
                    fileIndex: index,
                    fileCount: jobs.count
                )
            }.value

            if let folder = result.outputFolder { lastFolder = folder }
            apply(result, to: documentID)
            if result.error != nil { failures += 1 }
            finished += 1
            overallProgress = Double(finished) / Double(jobs.count)
        }

        finish(
            finished: finished,
            failures: failures,
            cancelled: flag.isCancelled,
            lastFolder: lastFolder ?? root,
            settings: snapshot,
            root: root
        )
    }

    /// 多张图片合并成一个 PDF：全部输入对应同一份输出。
    private func runMerge(
        jobs: [(UUID, SourceDocument)],
        settings snapshot: ConversionSettings,
        cancellation flag: CancellationFlag,
        root: URL
    ) async {
        for (documentID, _) in jobs {
            markConverting(itemID: documentID, done: 0, total: 1)
        }
        statusText = Localized.text("Merging %d images into one PDF…", jobs.count)

        let documents = jobs.map(\.1)
        let observer = ConversionObserver(onProgress: { progress in
            Task { @MainActor in
                self.overallProgress = progress.fraction
            }
        })

        let result = await Task.detached(priority: .userInitiated) {
            ConversionEngine.composePDF(
                documents: documents,
                settings: snapshot,
                cancellation: flag,
                observer: observer
            )
        }.value

        for documentID in result.includedDocumentIDs {
            apply(result, to: documentID)
        }

        finish(
            finished: 1,
            failures: result.error == nil ? 0 : 1,
            cancelled: flag.isCancelled,
            lastFolder: result.outputFolder ?? root,
            settings: snapshot,
            root: root,
            mergedCount: jobs.count
        )
    }

    /// 需要整批处理的 PDF 工具（合并）：所有输入对应同一份输出。
    private func runPDFToolBatch(
        jobs: [(UUID, SourceDocument)],
        settings snapshot: ConversionSettings,
        cancellation flag: CancellationFlag,
        root: URL
    ) async {
        for (documentID, _) in jobs {
            markConverting(itemID: documentID, done: 0, total: 1)
        }
        statusText = Localized.text("Merging %d PDFs into one…", jobs.count)

        let documents = jobs.map(\.1)
        let observer = ConversionObserver(onProgress: { progress in
            Task { @MainActor in
                self.overallProgress = progress.fraction
            }
        })

        let result = await Task.detached(priority: .userInitiated) {
            ConversionEngine.runPDFTool(
                documents: documents,
                tool: snapshot.pdfTool,
                settings: snapshot,
                cancellation: flag,
                observer: observer
            )
        }.value

        for documentID in result.includedDocumentIDs {
            apply(result, to: documentID)
        }

        finish(
            finished: 1,
            failures: result.error == nil ? 0 : 1,
            cancelled: flag.isCancelled,
            lastFolder: result.outputFolder ?? root,
            settings: snapshot,
            root: root,
            successSummary: result.error == nil
                ? Localized.text("Merged %d PDFs → %@", jobs.count, result.outputFiles.first?.lastPathComponent ?? "")
                : nil
        )
    }

    // MARK: - 状态更新

    private func markConverting(itemID: UUID, done: Int, total: Int) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].status = .converting(done: done, total: total)
    }

    private func apply(_ result: ConversionResult, to documentID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == documentID }) else { return }
        if let error = result.error {
            items[idx].status = .failed(error.message)
        } else {
            items[idx].status = .finished(files: result.producedCount, folder: result.outputFolder)
        }
    }

    private func finish(
        finished: Int,
        failures: Int,
        cancelled: Bool,
        lastFolder: URL,
        settings snapshot: ConversionSettings,
        root: URL,
        mergedCount: Int = 0,
        successSummary: String? = nil
    ) {
        isConverting = false
        overallProgress = cancelled ? 0 : 1
        lastOutputFolder = lastFolder

        if cancelled {
            statusText = Localized.text("Cancelled.")
        } else if failures > 0 {
            statusText = Localized.text("Finished with %d failure(s).", failures)
        } else if let successSummary {
            statusText = successSummary
            if snapshot.openFolderWhenFinished { openOutputFolder() }
        } else if mergedCount > 0 {
            statusText = Localized.text("Merged %d images → %@", mergedCount, lastFolder.path)
            if snapshot.openFolderWhenFinished { openOutputFolder() }
        } else {
            statusText = Localized.text("Finished: %d file(s) → %@", finished, root.path)
            if snapshot.openFolderWhenFinished { openOutputFolder() }
        }
    }

    func cancelConversion() {
        cancellation.cancel()
        statusText = Localized.text("Cancelling…")
    }
}
