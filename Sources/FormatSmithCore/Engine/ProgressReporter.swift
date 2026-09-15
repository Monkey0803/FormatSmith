import Foundation

/// 把「第几页 / 共几页」的回调转成统一的 `ConversionProgress`。
///
/// PDFKit 的几个操作各自有不同形状的回调，这里收口，避免每处都手写一遍。
final class ProgressReporter: @unchecked Sendable {
    private let observer: ConversionObserver
    private let fileIndex: Int
    private let fileCount: Int

    init(observer: ConversionObserver, fileIndex: Int, fileCount: Int) {
        self.observer = observer
        self.fileIndex = fileIndex
        self.fileCount = fileCount
    }

    func report(completed: Int, total: Int) {
        observer.onProgress?(
            ConversionProgress(
                completedUnits: completed,
                totalUnits: total,
                fileIndex: fileIndex,
                fileCount: fileCount
            )
        )
    }
}
