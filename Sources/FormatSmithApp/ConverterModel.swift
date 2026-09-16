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

/// 证件照预览：真正跑一遍处理管线得到的结果，所见即所得。
struct IDPhotoPreview: Equatable {
    var photo: NSImage?
    var sheet: NSImage?
    var caption: String = ""
    var notes: [String] = []
    var isRendering = false
    var failure: String?

    var isEmpty: Bool {
        photo == nil && sheet == nil && !isRendering && failure == nil
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
            scheduleIDPhotoPreview()
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
    /// 证件照预览。用户改一个参数就重算一次，但会防抖，并且复用同一个分析会话。
    @Published var idPhotoPreview = IDPhotoPreview()
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
    private var cachedSession: (path: String, session: IDPhotoSession)?

    /// 队列里第一张图片——证件照只处理图片输入。
    var firstImageInput: URL? {
        convertibleItems.first { $0.document.kind.isImage }?.url
    }

    /// 安排一次预览。连续调参数时只在停下来之后算一次。
    func scheduleIDPhotoPreview() {
        previewTask?.cancel()

        if DebugLog.isEnabled {
            DebugLog.log(
                "preview scheduling: enabled=\(settings.idPhotoEnabled), "
                    + "converting=\(isConverting), imageInput=\(firstImageInput?.lastPathComponent ?? "none")"
            )
        }
        guard settings.idPhotoEnabled, !isConverting, let source = firstImageInput else {
            if !idPhotoPreview.isEmpty { idPhotoPreview = IDPhotoPreview() }
            return
        }

        let snapshot = settings
        idPhotoPreview.isRendering = true
        previewTask = Task { @MainActor in
            // 防抖：拖滑块时不要每一帧都去跑 Vision
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            await self.renderIDPhotoPreview(source: source, settings: snapshot)
        }
    }

    private func renderIDPhotoPreview(source: URL, settings snapshot: ConversionSettings) async {
        do {
            let session = try await analysisSession(for: source)
            guard !Task.isCancelled else { return }

            let rendered = try await Task.detached(priority: .userInitiated) { () -> PreviewRender in
                let outcome = try session.render(
                    size: snapshot.idPhotoSize,
                    background: snapshot.idPhotoBackground,
                    dpi: snapshot.dpi,
                    autoCrop: snapshot.idPhotoAutoCrop
                )
                var sheet: CGImage?
                var sheetCount = 0
                if snapshot.printSheetEnabled {
                    sheet = try PhotoSheetTiler.render(
                        photo: outcome.image,
                        photoSize: snapshot.idPhotoSize,
                        sheet: snapshot.printSheet,
                        dpi: snapshot.dpi,
                        marginMM: snapshot.printSheetMarginMM,
                        gapMM: snapshot.printSheetGapMM,
                        cutGuides: snapshot.printSheetCutGuides
                    )
                    sheetCount =
                        PhotoSheetTiler.layout(
                            photo: snapshot.idPhotoSize,
                            sheet: snapshot.printSheet,
                            marginMM: snapshot.printSheetMarginMM,
                            gapMM: snapshot.printSheetGapMM
                        ).count
                }
                return PreviewRender(
                    photo: outcome.image,
                    sheet: sheet,
                    sheetCount: sheetCount,
                    notes: outcome.notes
                )
            }.value

            guard !Task.isCancelled else { return }

            let pixels = snapshot.idPhotoSize.pixelSize(dpi: snapshot.dpi)
            DebugLog.log(
                "preview rendered: \(pixels.width)×\(pixels.height)px, "
                    + "sheet=\(rendered.sheet != nil), notes=\(rendered.notes.count)"
            )
            idPhotoPreview = IDPhotoPreview(
                photo: NSImage(cgImage: rendered.photo, size: .zero),
                sheet: rendered.sheet.map { NSImage(cgImage: $0, size: .zero) },
                caption: sheetCaption(
                    count: rendered.sheetCount,
                    pixels: pixels,
                    settings: snapshot
                ),
                notes: rendered.notes,
                isRendering: false,
                failure: nil
            )
        } catch {
            guard !Task.isCancelled else { return }
            let message = (error as? ConversionError)?.message ?? error.localizedDescription
            idPhotoPreview = IDPhotoPreview(isRendering: false, failure: message)
        }
    }

    private struct PreviewRender: Sendable {
        let photo: CGImage
        let sheet: CGImage?
        let sheetCount: Int
        let notes: [String]
    }

    /// 同一个文件的解码与分析结果复用，换参数时不用重跑 Vision。
    private func analysisSession(for url: URL) async throws -> IDPhotoSession {
        if let cached = cachedSession, cached.path == url.path {
            return cached.session
        }
        let created = try await Task.detached(priority: .userInitiated) {
            try IDPhotoSession(url: url)
        }.value
        cachedSession = (url.path, created)
        return created
    }

    private func sheetCaption(
        count: Int,
        pixels: (width: Int, height: Int),
        settings snapshot: ConversionSettings
    ) -> String {
        if snapshot.printSheetEnabled {
            return Localized.text(
                "%d photos · %@",
                count,
                snapshot.printSheet.displayName
            )
        }
        return "\(pixels.width) × \(pixels.height) px" + " · " + snapshot.idPhotoSize.displayName
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
        scheduleIDPhotoPreview()
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
                self.scheduleIDPhotoPreview()
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
        scheduleIDPhotoPreview()
    }

    /// 下移一项。
    func moveDown(id: UUID) {
        guard !isConverting,
            let index = items.firstIndex(where: { $0.id == id }), index < items.count - 1
        else { return }
        items.swapAt(index, index + 1)
        scheduleIDPhotoPreview()
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
        scheduleIDPhotoPreview()
        if items.isEmpty {
            status = .idle
        }
    }

    func removeAll() {
        guard !isConverting else { return }
        items.removeAll()
        scheduleIDPhotoPreview()
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

    func startConversion() {
        guard !isConverting else { return }

        let queue = convertibleItems
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
    ///
    /// 并发调度交给 `ConversionEngine.convertBatch`，这里只负责把进度写回界面。
    private func runIndividually(
        jobs: [(UUID, SourceDocument)],
        settings snapshot: ConversionSettings,
        cancellation flag: CancellationFlag,
        root: URL
    ) async {
        let limit = ConversionEngine.automaticConcurrency(configured: snapshot.maxConcurrentFiles)
        inFlightProgress.removeAll()

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
                guard let documentID = progress.documentID else { return }
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

        let results = await ConversionEngine.convertBatch(
            documents: jobs.map(\.1),
            target: snapshot.target,
            settings: snapshot,
            cancellation: flag,
            maxConcurrency: limit,
            observer: observer
        )

        // 兜底：并发回调是异步投递的，等它们落地后再收尾。
        for result in results {
            recordFinished(result, fileCount: jobs.count)
        }

        let failures = results.filter { $0.error != nil }.count
        let lastFolder = results.compactMap(\.outputFolder).last ?? root

        finish(
            finished: results.count,
            failures: failures,
            cancelled: flag.isCancelled,
            lastFolder: lastFolder,
            settings: snapshot,
            root: root
        )
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
    private func runMerge(
        jobs: [(UUID, SourceDocument)],
        settings snapshot: ConversionSettings,
        cancellation flag: CancellationFlag,
        root: URL
    ) async {
        for (documentID, _) in jobs {
            markConverting(itemID: documentID, done: 0, total: 1)
        }
        status = StatusMessage("Merging %d images into one PDF…", jobs.count)

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
        status = StatusMessage("Merging %d PDFs into one…", jobs.count)

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
            status = StatusMessage("Cancelled.")
        } else if failures > 0 {
            status = StatusMessage("Finished with %d failure(s).", failures)
        } else if let successSummary {
            status = StatusMessage("%@", successSummary)
            if snapshot.openFolderWhenFinished { openOutputFolder() }
        } else if mergedCount > 0 {
            status = StatusMessage("Merged %d images → %@", mergedCount, lastFolder.path)
            if snapshot.openFolderWhenFinished { openOutputFolder() }
        } else {
            status = StatusMessage("Finished: %d file(s) → %@", finished, root.path)
            if snapshot.openFolderWhenFinished { openOutputFolder() }
        }
    }

    func cancelConversion() {
        cancellation.cancel()
        status = StatusMessage("Cancelling…")
    }
}
