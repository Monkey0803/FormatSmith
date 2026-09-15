import Foundation

/// 在必须使用主线程的 API（WKWebView 等）上执行异步工作。
///
/// 关键在于**调用方是不是主线程都要能用**：
/// - 后台线程：直接等信号量即可，主线程空闲，会正常执行排入的 block。
/// - 主线程（命令行就是这样）：不能 `wait()`，否则主队列永远没机会跑；
///   必须用嵌套 runloop 边等边跑。
///
/// 少了后一种情况，命令行里的 HTML → PDF 会直接死锁。
enum MainThreadBridge {

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

    static func run<T: Sendable>(
        timeout: TimeInterval = 120,
        _ work: @escaping @MainActor () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<T>()

        Task { @MainActor in
            do {
                box.set(.success(try await work()))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }

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
