import Foundation

/// 用本机的 LibreOffice 把 Office 文档转成 PDF。
///
/// 最容易踩的坑是**并发实例**：用户可能正开着 LibreOffice，第二个实例会被拒绝服务。
/// 解法是给每次转换一个独立的 `-env:UserInstallation` profile 目录，
/// 让这次调用完全独立于用户正在用的那份配置。
public enum LibreOfficeConverter {

    /// 支持作为输入的文档类型（LibreOffice 能打开的）。
    public static let supportedExtensions: Set<String> = [
        "doc", "docx", "docm", "odt", "rtf", "txt", "csv",
        "xls", "xlsx", "xlsm", "ods",
        "ppt", "pptx", "odp",
        "html", "htm", "xhtml",
    ]

    /// 转成 PDF，返回写出的文件。
    ///
    /// - Returns: 转换结果在 `outputURL`（必要时会附加去重后缀）。
    @discardableResult
    public static func convert(
        url: URL,
        to outputURL: URL,
        tool: ExternalTool,
        timeout: TimeInterval = 180
    ) throws -> URL {
        guard let executable = tool.executableURL else {
            throw ConversionError.missingExternalTool(tool.name, hint: tool.installHint)
        }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormatSmithLO-\(UUID().uuidString)", isDirectory: true)
        let profileURL = workspace.appendingPathComponent("profile", isDirectory: true)
        let outDirectory = workspace.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let result = try ProcessRunner.run(
            executable: executable,
            arguments: [
                // 独立 profile：既不打扰用户正在用的 LibreOffice，也不会被它挡住
                "-env:UserInstallation=\(profileURL.absoluteString)",
                "--headless",
                "--norestore",
                "--invisible",
                "--nolockcheck",
                "--nodefault",
                "--nofirststartwizard",
                "--convert-to",
                "pdf",
                "--outdir",
                outDirectory.path,
                url.path,
            ],
            timeout: timeout
        )

        guard result.succeeded else {
            let message = result.standardError.isEmpty ? result.standardOutput : result.standardError
            throw ProcessRunner.Failure.nonZeroExit(
                status: result.status,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        guard let produced = findProducedPDF(in: outDirectory, for: url) else {
            throw ConversionError(
                Localized.text("%@ did not produce a PDF for “%@”.", tool.name, url.lastPathComponent)
            )
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = OutputNaming.uniqueURL(outputURL)
        try FileManager.default.moveItem(at: produced, to: target)
        return target
    }

    /// LibreOffice 按输入文件名命名输出，这里把它找出来。
    static func findProducedPDF(in directory: URL, for input: URL) -> URL? {
        let expected =
            directory
            .appendingPathComponent(input.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("pdf")
        if FileManager.default.fileExists(atPath: expected.path) { return expected }

        // 大小写或名字被改写时的兜底：目录里第一个 PDF 就是它。
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []
        return contents.first { $0.pathExtension.lowercased() == "pdf" }
    }
}
