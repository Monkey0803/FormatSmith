import Foundation

/// 线程安全的取消标记。转换过程中由工作线程轮询，UI 线程负责触发取消。
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }
}
