import Foundation

/// 外部命令的执行结果。
public struct ProcessResult: Sendable {
    public let status: Int32
    public let standardOutput: String
    public let standardError: String

    public var succeeded: Bool { status == 0 }
}

/// 调用外部命令行工具。
///
/// 两个刻意的设计：
/// 1. stdout / stderr 重定向到临时文件而不是管道 —— 管道写满会让子进程阻塞，
///    而 LibreOffice 的输出量我们无法预估。
/// 2. 一定会超时 —— 卡住的转换必须能自己结束，不能把界面一起拖住。
public enum ProcessRunner {

    public enum Failure: Error, LocalizedError {
        case launchFailed(String)
        case timedOut(seconds: Double)
        case nonZeroExit(status: Int32, message: String)

        public var errorDescription: String? {
            switch self {
            case let .launchFailed(reason):
                return Localized.text("Could not start the converter: %@", reason)
            case let .timedOut(seconds):
                return Localized.text("The converter did not finish within %d seconds.", Int(seconds))
            case let .nonZeroExit(status, message):
                return Localized.text("The converter failed (exit %d): %@", Int(status), message)
            }
        }
    }

    /// 运行一个可执行文件并等待结束。
    ///
    /// - Parameters:
    ///   - arguments: 命令行参数。
    ///   - environment: 追加的环境变量（会与当前环境合并）。
    ///   - timeout: 超过这个时间就终止子进程。
    @discardableResult
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 180
    ) throws -> ProcessResult {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormatSmithProcess-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let stdoutURL = workspace.appendingPathComponent("stdout.txt")
        let stderrURL = workspace.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        process.standardInput = FileHandle.nullDevice
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        if !environment.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment { merged[key] = value }
            process.environment = merged
        }

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            exited.signal()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            // 给一次体面退出的机会，再强杀。
            if exited.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
            throw Failure.timedOut(seconds: timeout)
        }

        try? stdoutHandle.synchronize()
        try? stderrHandle.synchronize()
        let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""

        return ProcessResult(status: process.terminationStatus, standardOutput: stdout, standardError: stderr)
    }
}
