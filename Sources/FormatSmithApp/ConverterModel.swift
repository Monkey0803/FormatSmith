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
    case finished(files: Int, folder: URL?, outputs: [URL] = [])
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .finished, .failed: return true
        default: return false
        }
    }
}

/// 一轮转换的结果汇总。
///
/// 批量转换里最要紧的是「哪几个没成功、为什么」——只给一句「完成 3/5」，
/// 用户还得自己一个个点开看。
struct BatchSummary: Equatable {
    struct Failure: Equatable, Identifiable {
        let id: UUID
        let name: String
        let message: String
    }

    var succeeded: Int = 0
    var failures: [Failure] = []
    var outputCount: Int = 0
    var outputFolder: URL?
    var cancelled = false

    var isEmpty: Bool { succeeded == 0 && failures.isEmpty }
    var hasFailures: Bool { !failures.isEmpty }
}

/// 输出预览：真正跑一遍该走的管线得到的结果，所见即所得。
struct OutputPreviewState: Equatable {
    var image: NSImage?
    var kind: OutputPreview.Kind = .image
    var caption: String = ""
    var notes: [String] = []
    /// 会产出多少份文件 / 首份输出多少页。
    var fileCount: Int = 1
    var pageCount: Int = 1
    var isRendering = false
    var failure: String?

    var isEmpty: Bool {
        image == nil && !isRendering && failure == nil
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
        didSet {
            persistSettings()
            scheduleOutputPreview()
        }
    }
    @Published var isConverting = false
    @Published var overallProgress: Double = 0
    @Published var status: StatusMessage = .idle {
        didSet {
            if status != oldValue { DebugLog.log("status: \(status.key)") }
        }
    }
    @Published var lastOutputFolder: URL?
    /// 输出预览。用户改一个参数就重算一次，但会防抖，并且复用同一个分析会话。
    @Published var outputPreview = OutputPreviewState()
    /// 上一轮转换的结果汇总；开跑新一轮时清空。
    @Published var batchSummary: BatchSummary?
    /// 是否展开长尾格式。
    @Published var showsAllFormats = false
    /// 界面语言。改动会立刻生效（根视图用它的值做 id，从而重建整棵视图树）。
    @Published var language: AppLanguage {
        didSet {
            Localized.language = language
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
        }
    }

    static let languageKey = "FormatSmith.language"

    private let cancellation = CancellationFlag()
    /// 每个正在转换的文件内部的进度，用于并发时合成整体进度。
    private var inFlightProgress: [UUID: Double] = [:]
    private let defaultsKey = "FormatSmith.settings.v2"

    init() {
        // 语言要在任何界面构建之前确定下来。
        let stored = UserDefaults.standard.string(forKey: Self.languageKey)
        let resolved = stored.flatMap(AppLanguage.init(rawValue:)) ?? .system
        language = resolved
        Localized.language = resolved
        // 打一行真实解析出来的文案：「偏好是什么」和「界面实际会显示什么」是两件事，
        // 只打偏好会漏掉「语言被别处强制成英文」这种 bug。
        DebugLog.log(
            "language: \(resolved.rawValue) "
                + "(bundled: \(Localized.bundledLanguages().joined(separator: ", "))) "
                + "sample: \(Localized.text("Output format"))"
        )

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

    /// 首张图的输出像素估算。证件照与相纸排版按规格算，其余按缩放算。
    var outputEstimate: (width: Int, height: Int)? {
        guard let first = items.first(where: { $0.document.size.width > 0 }) else { return nil }
        let info = DocumentInfo(
            kind: first.document.kind,
            pageCount: first.document.pageCount,
            displaySize: first.document.size
        )
        return settings.estimatedPixelSize(for: info)
    }

    /// 当前参数会不会因为像素数过高而被拒绝。
    var estimateExceedsLimit: Bool {
        guard let estimate = outputEstimate else { return false }
        return estimate.width * estimate.height > settings.maxPixels
    }

    /// 当前这批输入与目标下，哪些设置真的生效。
    ///
    /// 界面据此决定显示哪些分区：显示与生效来自同一处判断，
    /// 不会出现「生效了却没地方看」或「显示了却不起作用」。
    var settingsScope: SettingsScope {
        SettingsScope(
            documentKinds: convertibleItems.map(\.document.kind),
            pageCounts: convertibleItems.map(\.document.pageCount),
            target: settings.target,
            settings: settings
        )
    }

    /// 这台文件的输出像素上限（百万像素），用于提示文案。
    var maxMegapixels: Int { settings.maxPixels / 1_000_000 }

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

    // MARK: - 证件照预览

    private var previewTask: Task<Void, Never>?
    /// 预览复用同一个会话，证件照的人像分析只跑一次。
    private let previewSession = OutputPreviewSession()

    /// 队列里第一张图片——证件照只处理图片输入。
    var firstImageInput: URL? {
        convertibleItems.first { $0.document.kind.isImage }?.url
    }

    /// 安排一次预览。连续调参数时只在停下来之后算一次。
    func scheduleOutputPreview() {
        previewTask?.cancel()

        guard !isConverting, !convertibleItems.isEmpty else {
            if !outputPreview.isEmpty { outputPreview = OutputPreviewState() }
            return
        }

        let documents = convertibleItems.map(\.document)
        let snapshot = settings
        // 文档 → PDF 要真的跑一次转换（LibreOffice / WebKit），等用户停下来再触发
        let expensive = OutputPreview.isExpensive(documents: documents, target: snapshot.target)
        let delay: UInt64 = expensive ? 700_000_000 : 180_000_000

        if DebugLog.isEnabled {
            DebugLog.log(
                "preview scheduling: files=\(documents.count), expensive=\(expensive), "
                    + "target=\(snapshot.target.isPDF ? "pdf" : "image")"
            )
        }

        outputPreview.isRendering = true
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self.renderOutputPreview(documents: documents, settings: snapshot)
        }
    }

    private func renderOutputPreview(documents: [SourceDocument], settings snapshot: ConversionSettings) async {
        do {
            let session = previewSession
            let rendered = try await Task.detached(priority: .userInitiated) {
                try session.render(documents: documents, target: snapshot.target, settings: snapshot)
            }.value

            guard !Task.isCancelled else { return }
            DebugLog.log(
                "preview rendered: \(rendered.caption), files=\(rendered.fileCount), pages=\(rendered.pageCount)"
            )
            outputPreview = OutputPreviewState(
                image: NSImage(cgImage: rendered.image, size: .zero),
                kind: rendered.kind,
                caption: rendered.caption,
                notes: rendered.notes,
                fileCount: rendered.fileCount,
                pageCount: rendered.pageCount,
                isRendering: false,
                failure: nil
            )
        } catch {
            guard !Task.isCancelled else { return }
            let message = (error as? ConversionError)?.message ?? error.localizedDescription
            DebugLog.log("preview failed: \(message)")
            outputPreview = OutputPreviewState(isRendering: false, failure: message)
        }
    }

    // MARK: - 预设

    func apply(_ preset: Preset) {
        // 预设是完整配方：没提到的项回到默认值，避免上一次的选择残留下来
        settings = preset.applied(to: settings)
        status = StatusMessage("Applied preset: %@", preset.name)
        DebugLog.log("applied preset: \(preset.id)")
    }

    /// 当前设置是否正好等于某个预设。
    func matches(_ preset: Preset) -> Bool {
        preset.applied(to: settings) == settings
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

        DebugLog.log("add(urls: \(urls.count)) → \(added.count) new item(s)")
        guard !added.isEmpty else { return }
        items.append(contentsOf: added)
        status = StatusMessage("Added %d file(s).", added.count)
        loadMetadata(for: added.map(\.id))
        scheduleOutputPreview()
    }

    /// 展开拖入的目录，收集支持的输入文件（含子目录）。
    private func expand(urls: [URL]) -> [URL] {
        let manager = FileManager.default
        var result: [URL] = []

        for url in urls {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                // 文件夹里的顺序是文件系统给的，不可靠，按名字排一下
                let enumerator = manager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                var inside: [URL] = []
                while let child = enumerator?.nextObject() as? URL, isSupported(child) {
                    inside.append(child)
                }
                result.append(contentsOf: inside.sorted { Self.isOrderedBefore($0, $1) })
            } else if isSupported(url) {
                result.append(url)
            } else {
                status = StatusMessage("Ignored unsupported file: %@", url.lastPathComponent)
            }
        }

        // 显式给出的文件**保持用户给的顺序**。
        //
        // 之前这里统一按文件名排序，结果「先拖正面、再拖反面」会被排成 back、front ——
        // 身份证正反面这类有先后含义的输入就被悄悄调换了。
        // 需要别的顺序时，列表里的 ↑ ↓ 可以调。
        return result
    }

    /// 文件夹内的排序用。
    private static func isOrderedBefore(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
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
            // `SourceDocument.make` 已经把元信息探测好了，只有确实缺页数时才显示「载入中」，
            // 免得刚加进来就先把状态闪一下。
            if items[index].document.pageCount == 0 {
                items[index].status = .loading
            }

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

                // 元信息可能在转换开始之后、甚至结束之后才回来。
                // 那时候不能再动状态，否则会把已经完成（或失败）的项打回「待转换」——
                // 之前这里无条件写 `.ready`，就出过这个问题。
                if case .loading = self.items[idx].status {
                    self.items[idx].status =
                        loaded.0.pageCount > 0
                        ? .ready
                        : .failed(Localized.text("Could not read this file."))
                }
                self.scheduleOutputPreview()
                DebugLog.log(
                    "inspected \(url.lastPathComponent): \(loaded.0.kind.displayName), "
                        + "\(loaded.0.pageCount) page(s)/frame(s), "
                        + "\(Int(loaded.0.displaySize.width))×\(Int(loaded.0.displaySize.height))"
                )
            }
        }
    }

    /// 上移一项。合并类任务（身份证正反面、多图 PDF）里顺序是有含义的。
    func moveUp(id: UUID) {
        guard !isConverting,
            let index = items.firstIndex(where: { $0.id == id }), index > 0
        else { return }
        items.swapAt(index, index - 1)
        scheduleOutputPreview()
    }

    /// 下移一项。
    func moveDown(id: UUID) {
        guard !isConverting,
            let index = items.firstIndex(where: { $0.id == id }), index < items.count - 1
        else { return }
        items.swapAt(index, index + 1)
        scheduleOutputPreview()
    }

    /// 该项能不能上移 / 下移，用于决定按钮是否可用。
    func canMoveUp(id: UUID) -> Bool {
        guard !isConverting, let index = items.firstIndex(where: { $0.id == id }) else { return false }
        return index > 0
    }

    func canMoveDown(id: UUID) -> Bool {
        guard !isConverting, let index = items.firstIndex(where: { $0.id == id }) else { return false }
        return index < items.count - 1
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        scheduleOutputPreview()
        if items.isEmpty {
            status = .idle
        }
    }

    func removeAll() {
        guard !isConverting else { return }
        items.removeAll()
        scheduleOutputPreview()
        overallProgress = 0
        status = .idle
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
            status = StatusMessage("Output folder does not exist: %@", folder.path)
            return
        }
        NSWorkspace.shared.open(folder)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 转换

    func startConversion(only limitedTo: Set<UUID>? = nil) {
        guard !isConverting else { return }

        let queue = limitedTo.map { ids in convertibleItems.filter { ids.contains($0.id) } } ?? convertibleItems
        guard !queue.isEmpty else {
            status = StatusMessage("There is nothing to convert.")
            return
        }

        let reasons = unavailableReasons
        guard reasons.isEmpty else {
            status = StatusMessage("%@", reasons[0])
            return
        }

        let root = settings.resolvedOutputDirectory
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            status = StatusMessage("Output folder is not writable: %@", error.localizedDescription)
            return
        }

        cancellation.reset()
        isConverting = true
        overallProgress = 0
        lastOutputFolder = nil
        batchSummary = nil
        for item in queue {
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].status = .ready
            }
        }

        let snapshot = settings
        let flag = cancellation

        // 把这一轮要用的数据固定下来，避免转换过程中队列变化影响遍历。
        let jobs = queue.map { ($0.id, $0.document) }

        Task { @MainActor in
            await self.runConversion(jobs: jobs, settings: snapshot, cancellation: flag, root: root)
        }
    }

    /// 跑完这一批。
    ///
    /// 合并成一个 PDF、整批走 PDF 工具箱、还是逐个转换，判断只在 `ConversionEngine.run`
    /// 里做一次 —— 这里只负责把进度与结果写回界面。
    private func runConversion(
        jobs: [(UUID, SourceDocument)],
        settings snapshot: ConversionSettings,
        cancellation flag: CancellationFlag,
        root: URL
    ) async {
        inFlightProgress.removeAll()

        let limit = ConversionEngine.automaticConcurrency(configured: snapshot.maxConcurrentFiles)
        status =
            limit > 1
            ? StatusMessage("Converting %d file(s), %d at a time…", jobs.count, limit)
            : StatusMessage("Converting %d file(s)…", jobs.count)

        for (documentID, document) in jobs {
            markConverting(itemID: documentID, done: 0, total: max(document.pageCount, 1))
        }

        // 进度回调来自工作线程，统一跳回主线程写状态。
        let observer = ConversionObserver(
            onProgress: { progress in
                guard let documentID = progress.documentID else {
                    Task { @MainActor in self.overallProgress = progress.fraction }
                    return
                }
                Task { @MainActor in
                    self.recordProgress(
                        documentID: documentID,
                        completed: progress.completedUnits,
                        total: progress.totalUnits,
                        fileCount: jobs.count
                    )
                }
            },
            onFileFinished: { result in
                Task { @MainActor in
                    self.recordFinished(result, fileCount: jobs.count)
                }
            }
        )

        let documents = jobs.map(\.1)
        // 合并与工具箱是同步的 CPU 活，放到后台线程跑，别卡住界面
        let results = await Task.detached(priority: .userInitiated) {
            await ConversionEngine.run(
                documents: documents,
                target: snapshot.target,
                settings: snapshot,
                cancellation: flag,
                observer: observer
            )
        }.value

        // 兜底：并发回调是异步投递的，等它们落地后再收尾。
        for result in results {
            recordFinished(result, fileCount: jobs.count)
        }

        finish(results: results, cancelled: flag.isCancelled, root: root, settings: snapshot)
    }

    /// 更新单个文件内部的进度，并合成整体进度。
    private func recordProgress(documentID: UUID, completed: Int, total: Int, fileCount: Int) {
        guard let idx = items.firstIndex(where: { $0.id == documentID }) else { return }
        items[idx].status = .converting(done: completed, total: total)
        if total > 0 {
            inFlightProgress[documentID] = Double(completed) / Double(total)
        }
        refreshOverallProgress(total: fileCount)
    }

    /// 一个文件结束时更新状态与整体进度。
    private func recordFinished(_ result: ConversionResult, fileCount: Int) {
        inFlightProgress[result.documentID] = nil
        apply(result, to: result.documentID)
        refreshOverallProgress(total: fileCount)
    }

    /// 已完成的文件数 + 进行中的文件内进度，合成为整体进度。
    private func refreshOverallProgress(total: Int) {
        guard total > 0 else {
            overallProgress = 0
            return
        }
        let finishedCount = items.filter { $0.status.isTerminal }.count
        let partial = inFlightProgress.values.reduce(0, +)
        overallProgress = min(1, (Double(finishedCount) + partial) / Double(total))
    }

    /// 多张图片合并成一个 PDF：全部输入对应同一份输出。
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
            items[idx].status = .finished(
                files: result.producedCount,
                folder: result.outputFolder,
                outputs: result.outputFiles
            )
        }
    }

    /// 收尾：状态行、汇总卡片、以及可选的自动打开输出目录。
    ///
    /// 一切都从结果推导：失败数、合并了几份、输出目录。
    private func finish(
        results: [ConversionResult],
        cancelled: Bool,
        root: URL,
        settings snapshot: ConversionSettings
    ) {
        isConverting = false
        overallProgress = cancelled ? 0 : 1

        let failures = results.filter { $0.error != nil }.count
        let mergedCount = results.first { $0.includedDocumentIDs.count > 1 }?.includedDocumentIDs.count ?? 0
        let lastFolder = results.compactMap(\.outputFolder).first ?? root
        lastOutputFolder = lastFolder

        batchSummary = Self.summarise(items: items, folder: lastFolder, cancelled: cancelled)

        if cancelled {
            status = StatusMessage("Cancelled.")
        } else if failures > 0 {
            status = StatusMessage("Finished with %d failure(s).", failures)
        } else if mergedCount > 0 {
            status = StatusMessage("Merged %d file(s) → %@", mergedCount, lastFolder.path)
            if snapshot.openFolderWhenFinished { openOutputFolder() }
        } else {
            status = StatusMessage("Finished: %d file(s) → %@", results.count, lastFolder.path)
            if snapshot.openFolderWhenFinished { openOutputFolder() }
        }
    }

    /// 从当前队列状态生成汇总。
    ///
    /// 统计的是「队列现在的状态」，而不是「这一轮跑了什么」：
    /// 重试成功后卡片会显示全部成功，重试按钮随之消失，符合直觉。
    private static func summarise(items: [QueueItem], folder: URL, cancelled: Bool) -> BatchSummary {
        var summary = BatchSummary(outputFolder: folder, cancelled: cancelled)
        for item in items {
            switch item.status {
            case .finished(let files, _, _):
                summary.succeeded += 1
                summary.outputCount += files
            case .failed(let message):
                summary.failures.append(
                    BatchSummary.Failure(id: item.id, name: item.name, message: message)
                )
            default:
                break
            }
        }
        return summary
    }

    /// 只重跑上一轮失败的项。
    func retryFailedItems() {
        guard !isConverting, let summary = batchSummary, summary.hasFailures else { return }
        let failed = Set(summary.failures.map(\.id))

        for index in items.indices where failed.contains(items[index].id) {
            items[index].status = .ready
        }
        DebugLog.log("retrying \(failed.count) failed item(s)")
        startConversion(only: failed)
    }

    /// 清掉汇总卡片。
    func dismissBatchSummary() {
        batchSummary = nil
    }

    func cancelConversion() {
        cancellation.cancel()
        status = StatusMessage("Cancelling…")
    }
}
