import Foundation

/// 一个可选的命令行依赖。
public struct ExternalTool: Sendable, Equatable {
    public let name: String
    public let executableURL: URL?
    /// 给用户的安装提示（一句人话）。
    public let installHint: String
    /// 可以直接粘进终端的安装命令。
    public let installCommand: String?

    public init(name: String, executableURL: URL?, installHint: String, installCommand: String? = nil) {
        self.name = name
        self.executableURL = executableURL
        self.installHint = installHint
        self.installCommand = installCommand
    }

    public var isAvailable: Bool { executableURL != nil }

    /// 位置说明。只反映文件系统探测结果，**不含版本号**，
    /// 因此可以安全地在界面渲染路径上调用。
    public var locationDescription: String {
        executableURL?.path ?? Localized.text("Not found")
    }

    /// 带版本号的完整说明。
    ///
    /// 和 `probeVersion` 一样会启动外部进程，只应在用户显式要求时调用。
    public func describe() -> String {
        guard let executableURL else { return Localized.text("Not found") }
        if let version = probeVersion() {
            return "\(version) — \(executableURL.path)"
        }
        return executableURL.path
    }

    /// 探测版本号。
    ///
    /// 这会真的启动一次外部进程（LibreOffice 可能要一两秒），所以只应在
    /// 用户明确要求时调用，绝不能放在 SwiftUI 的 body 里。
    public func probeVersion(force: Bool = false) -> String? {
        guard let executableURL else { return nil }
        return ToolLocator.version(of: executableURL, force: force)
    }
}

/// 探测本机装了哪些可选的转换工具。
///
/// 找不到不算错误：受影响的只有「文档 → PDF」里依赖外部工具的那部分，其余功能照常。
/// 探测结果会缓存 —— 位置探测只查文件系统，很快；版本探测会起进程，按需触发。
public enum ToolLocator {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var toolCache: [String: ExternalTool] = [:]
    nonisolated(unsafe) private static var versionCache: [String: String] = [:]

    // MARK: - 对外

    /// LibreOffice：负责 Word / Excel / PowerPoint / OpenDocument / RTF。
    public static func libreOffice(refresh: Bool = false) -> ExternalTool {
        cached("libreoffice", refresh: refresh) {
            let executable = findExecutable(
                named: "soffice",
                extraPaths: [
                    "/Applications/LibreOffice.app/Contents/MacOS/soffice",
                    "~/Applications/LibreOffice.app/Contents/MacOS/soffice",
                    "/opt/homebrew/bin/soffice",
                    "/usr/local/bin/soffice",
                ],
                environmentOverride: "LIBREOFFICE_PATH"
            )
            return ExternalTool(
                name: "LibreOffice",
                executableURL: executable,
                installHint: Localized.text(
                    "Install it with Homebrew, or download it from libreoffice.org."),
                installCommand: "brew install --cask libreoffice"
            )
        }
    }

    /// pandoc：负责把 Markdown 转成 HTML（保真度比内置渲染高）。
    public static func pandoc(refresh: Bool = false) -> ExternalTool {
        cached("pandoc", refresh: refresh) {
            let executable = findExecutable(
                named: "pandoc",
                extraPaths: [
                    "/opt/homebrew/bin/pandoc",
                    "/usr/local/bin/pandoc",
                    "~/.local/bin/pandoc",
                ],
                environmentOverride: "PANDOC_PATH"
            )
            return ExternalTool(
                name: "pandoc",
                executableURL: executable,
                installHint: Localized.text(
                    "Install it with Homebrew. Markdown still converts without it, using the built-in renderer."),
                installCommand: "brew install pandoc"
            )
        }
    }

    public static func all(refresh: Bool = false) -> [ExternalTool] {
        [libreOffice(refresh: refresh), pandoc(refresh: refresh)]
    }

    // MARK: - 探测

    /// 按「环境变量 → 已知安装位置 → PATH」的顺序找可执行文件。
    static func findExecutable(
        named name: String,
        extraPaths: [String],
        environmentOverride: String? = nil
    ) -> URL? {
        let manager = FileManager.default

        func isExecutable(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return false
            }
            return manager.isExecutableFile(atPath: path)
        }

        if let environmentOverride,
            let override = ProcessInfo.processInfo.environment[environmentOverride],
            !override.isEmpty
        {
            let expanded = (override as NSString).expandingTildeInPath
            if isExecutable(expanded) { return URL(fileURLWithPath: expanded) }
        }

        for candidate in extraPaths {
            let expanded = (candidate as NSString).expandingTildeInPath
            if isExecutable(expanded) { return URL(fileURLWithPath: expanded) }
        }

        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in searchPath.split(separator: ":") {
            let candidate = (String(directory) as NSString).appendingPathComponent(name)
            if isExecutable(candidate) { return URL(fileURLWithPath: candidate) }
        }

        return nil
    }

    /// 取首行版本号；结果会缓存。失败不影响「工具可用」这个结论。
    static func version(of executable: URL, force: Bool = false) -> String? {
        let key = executable.path
        lock.lock()
        if !force, let cached = versionCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard
            let result = try? ProcessRunner.run(
                executable: executable,
                arguments: ["--version"],
                timeout: 20
            )
        else { return nil }

        let text = result.standardOutput.isEmpty ? result.standardError : result.standardOutput
        let firstLine =
            text
            .split(separator: "\n")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        guard let firstLine, !firstLine.isEmpty else { return nil }

        lock.lock()
        versionCache[key] = firstLine
        lock.unlock()
        return firstLine
    }

    private static func cached(_ key: String, refresh: Bool, build: () -> ExternalTool) -> ExternalTool {
        lock.lock()
        if !refresh, let existing = toolCache[key] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let tool = build()
        lock.lock()
        toolCache[key] = tool
        lock.unlock()
        return tool
    }

    /// 测试用：清掉缓存。
    static func resetCache() {
        lock.lock()
        toolCache.removeAll()
        versionCache.removeAll()
        lock.unlock()
    }
}
