import Foundation

/// 在必须使用主线程的 API（WKWebView 等）上执行异步工作。
///
/// 关键在于**调用方是不是主线程都要能用**：
/// - 后台线程：直接等信号量即可，主线程空闲，会正常执行排入的 block。
/// - 主线程（命令行就是这样）：不能 `wait()`，否则主队列永远没机会跑；
///   必须用嵌套 runloop 边等边跑。
///
/// 少了后一种情况，命令行里的 HTML → PDF 会直接死锁。
public enum MainThreadBridge {

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Result<T, Error>?

        func set(_ value: Result<T, Error>) {
            lock.lock()
            storage = value
            lock.unlock()
        }

        func get() -> Result<T, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// 在同步上下文里等待一段**不要求主 actor** 的异步工作。
    ///
    /// 命令行入口就是这种情况：它必须在主线程上同步等待，但又不能真的把主线程堵死，
    /// 因为批次里可能有 HTML 文档，而 WebKit 的回调要靠主线程跑。
    /// 主线程上阻塞等待 = 和 `run` 里的主线程动作互相锁死。
    public static func await<T: Sendable>(
        timeout: TimeInterval = 3600,
        _ work: @escaping @Sendable () async throws -> T
    ) throws -> T {
        try wait(timeout: timeout) { box, signal in
            Task {
                do {
                    box.set(.success(try await work()))
                } catch {
                    box.set(.failure(error))
                }
                signal()
            }
        }
    }

    public static func run<T: Sendable>(
        timeout: TimeInterval = 120,
        _ work: @escaping @MainActor () async throws -> T
    ) throws -> T {
        try wait(timeout: timeout) { box, signal in
            Task { @MainActor in
                do {
                    box.set(.success(try await work()))
                } catch {
                    box.set(.failure(error))
                }
                signal()
            }
        }
    }

    /// 共用的等待逻辑：主线程上边跑 runloop 边等，其他线程直接等信号量。
    private static func wait<T: Sendable>(
        timeout: TimeInterval,
        start: (Box<T>, @escaping @Sendable () -> Void) -> Void
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<T>()
        start(box) { semaphore.signal() }

        let deadline = Date().addingTimeInterval(timeout)
        if Thread.isMainThread {
            while semaphore.wait(timeout: .now() + 0.02) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
                if Date() > deadline {
                    throw ConversionError(Localized.text("The converter did not finish in time."))
                }
            }
        } else if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw ConversionError(Localized.text("The converter did not finish in time."))
        }

        guard let result = box.get() else {
            throw ConversionError(Localized.text("The converter did not finish in time."))
        }
        return try result.get()
    }
}
