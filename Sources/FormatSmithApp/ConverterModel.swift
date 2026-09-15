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

    var isRunning: Bool {
        if case .converting = self { return true }
        return false
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
    @Published var statusText = Localized.text("Drop PDF files here, or click “Choose PDFs” to start.")
    @Published var lastOutputFolder: URL?
    /// 支持长尾格式的开关；关闭时只显示常用格式。
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
        // 旧偏好里的格式在当前系统上可能不可写，回退到 PNG。
        if !settings.format.isWritableBySystem {
            settings.format = .png
        }
        settings.normalizeForFormat()
    }

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: - 格式清单

    var availableFormats: [ImageFormat] {
        showsAllFormats ? FormatRegistry.allWritable : FormatRegistry.curated
    }

    // MARK: - 队列

    var pendingCount: Int {
        items.filter { !$0.status.isTerminal }.count
    }

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

    /// 当前阶段只接受 PDF；后续阶段会放开图片与文档。
    private func isSupported(_ url: URL) -> Bool {
        InputKind.detect(url: url) == .pdf
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
                        default: return nil
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
                    : .failed(
                        Localized.text("Could not read this file.")
                    )
                DebugLog.log(
                    "读取 \(url.lastPathComponent): \(loaded.0.pageCount) 页, 尺寸 "
                        + "\(Int(loaded.0.displaySize.width))×\(Int(loaded.0.displaySize.height))"
                )
            }
        }
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        if items.isEmpty {
            statusText = Localized.text("Drop PDF files here, or click “Choose PDFs” to start.")
        }
    }

    func removeAll() {
        guard !isConverting else { return }
        items.removeAll()
        overallProgress = 0
        statusText = Localized.text("Drop PDF files here, or click “Choose PDFs” to start.")
    }

    func clearFinished() {
        guard !isConverting else { return }
        items.removeAll { $0.status.isTerminal }
    }

    // MARK: - 面板

    func chooseInputFiles() {
        let panel = NSOpenPanel()
        panel.title = Localized.text("Choose PDF files")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf]
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
        let queue = items.filter { $0.document.pageCount > 0 && $0.document.kind == .pdf }
        guard !queue.isEmpty else {
            statusText = Localized.text("There is nothing to convert.")
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
        let total = queue.count
        let flag = cancellation

        Task { @MainActor in
            var finished = 0
            var failures = 0
            var lastFolder: URL?

            for (index, item) in queue.enumerated() {
                if flag.isCancelled { break }

                self.items.firstIndex(where: { $0.id == item.id }).map {
                    self.items[$0].status = .converting(done: 0, total: max(item.document.pageCount, 1))
                }
                self.statusText = Localized.text("Converting: %@", item.name)

                let documentID = item.id
                let observer = ConversionObserver(
                    onProgress: { progress in
                        Task { @MainActor in
                            guard let idx = self.items.firstIndex(where: { $0.id == documentID }) else { return }
                            self.items[idx].status = .converting(
                                done: progress.completedUnits,
                                total: progress.totalUnits
                            )
                            self.overallProgress = progress.fraction
                        }
                    }
                )

                let result = await Task.detached(priority: .userInitiated) {
                    ConversionEngine.convertPDFToImages(
                        document: item.document,
                        settings: snapshot,
                        cancellation: flag,
                        observer: observer,
                        fileIndex: index,
                        fileCount: total
                    )
                }.value

                if let folder = result.outputFolder { lastFolder = folder }

                if let idx = self.items.firstIndex(where: { $0.id == documentID }) {
                    if let error = result.error {
                        self.items[idx].status = .failed(error.message)
                    } else {
                        self.items[idx].status = .finished(files: result.producedCount, folder: result.outputFolder)
                    }
                }
                if result.error != nil { failures += 1 }
                finished += 1
                self.overallProgress = Double(finished) / Double(total)
            }

            let wasCancelled = flag.isCancelled
            self.isConverting = false
            self.overallProgress = wasCancelled ? 0 : 1
            self.lastOutputFolder = lastFolder ?? root

            if wasCancelled {
                self.statusText = Localized.text("Cancelled.")
            } else if failures == 0 {
                self.statusText = Localized.text("Finished: %d file(s) → %@", finished, root.path)
                if snapshot.openFolderWhenFinished { self.openOutputFolder() }
            } else {
                self.statusText = Localized.text("Finished with %d failure(s).", failures)
            }
        }
    }

    func cancelConversion() {
        cancellation.cancel()
        statusText = Localized.text("Cancelling…")
    }
}
