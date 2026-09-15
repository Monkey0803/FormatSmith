import Foundation

/// 「文档 → PDF」的统一入口。
///
/// 三条路各司其职，并且都能优雅降级：
/// - Office / OpenDocument / RTF → 本机 LibreOffice
/// - Markdown → pandoc（保真度高）；没有 pandoc 就用内置渲染器
/// - HTML / 纯文本 → 系统 WebKit，零依赖
public enum DocumentConverter {

    /// 打印样式：统一字体与页边距，让 WebKit 的输出看起来像一份文档而不是网页。
    static let printStyle = """
        <style>
          body {
            font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif;
            font-size: 12pt; line-height: 1.5; color: #111;
            /* 截取式分页下 @page 不生效，边距必须加在 body 上 */
            margin: 56pt 56pt;
            -webkit-text-size-adjust: 100%;
          }
          h1 { font-size: 22pt; } h2 { font-size: 17pt; } h3 { font-size: 14pt; }
          h1, h2, h3, h4 { line-height: 1.25; margin: 0.9em 0 0.4em; }
          p { margin: 0.55em 0; }
          pre {
            background: #f5f5f7; padding: 8pt 10pt; border-radius: 4pt;
            font-size: 10pt; white-space: pre-wrap; word-wrap: break-word;
          }
          code { font-family: Menlo, "SF Mono", monospace; font-size: 10pt; }
          blockquote { border-left: 3pt solid #d0d0d5; margin: 0.6em 0; padding-left: 10pt; color: #444; }
          table { border-collapse: collapse; margin: 0.6em 0; }
          th, td { border: 0.5pt solid #c0c0c6; padding: 4pt 6pt; text-align: left; }
          img { max-width: 100%; }
          hr { border: none; border-top: 0.5pt solid #ccc; margin: 1em 0; }
          @page { margin: 56pt; }
        </style>
        """

    /// 转换一个文档输入。
    @discardableResult
    public static func convert(
        url: URL,
        kind: InputKind,
        to outputURL: URL
    ) throws -> URL {
        switch kind {
        case .office:
            return try convertWithLibreOffice(url: url, to: outputURL)

        case .html:
            let html = try readText(url)
            return try renderHTML(html, title: url.deletingPathExtension().lastPathComponent, to: outputURL)

        case .markdown:
            let markdown = try readText(url)
            let html = renderMarkdown(markdown, title: url.deletingPathExtension().lastPathComponent)
            return try renderHTML(html, title: url.deletingPathExtension().lastPathComponent, to: outputURL)

        case .plainText:
            let text = try readText(url)
            let html = MarkdownHTMLRenderer.renderDocument(
                markdown: "```\n\(text)\n```",
                title: url.deletingPathExtension().lastPathComponent
            )
            return try renderHTML(html, title: url.deletingPathExtension().lastPathComponent, to: outputURL)

        default:
            throw ConversionError.unsupportedInput(kind.displayName)
        }
    }

    // MARK: - 各条路径

    static func convertWithLibreOffice(url: URL, to outputURL: URL) throws -> URL {
        let tool = ToolLocator.libreOffice()
        guard tool.isAvailable else {
            throw ConversionError.missingExternalTool(tool.name, hint: tool.installHint)
        }
        return try LibreOfficeConverter.convert(url: url, to: outputURL, tool: tool)
    }

    /// Markdown 优先交给 pandoc，没有就用内置渲染器。
    static func renderMarkdown(_ markdown: String, title: String) -> String {
        let pandoc = ToolLocator.pandoc()
        if let executable = pandoc.executableURL,
            let html = try? renderWithPandoc(markdown, title: title, pandoc: executable)
        {
            return html
        }
        return MarkdownHTMLRenderer.renderDocument(markdown: markdown, title: title)
    }

    static func renderWithPandoc(_ markdown: String, title: String, pandoc: URL) throws -> String {
        // pandoc 直接读文件更省事，这里写一份临时 Markdown。
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormatSmithPandoc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let inputURL = workspace.appendingPathComponent("input.md")
        try markdown.write(to: inputURL, atomically: true, encoding: .utf8)

        let result = try ProcessRunner.run(
            executable: pandoc,
            arguments: [
                "--from", "markdown",
                "--to", "html5",
                "--standalone",
                "--metadata", "title=\(title)",
                inputURL.path,
            ],
            timeout: 60
        )
        guard result.succeeded, !result.standardOutput.isEmpty else {
            // pandoc 失败不是致命错误，交给调用方回退到内置渲染器。
            throw ProcessRunner.Failure.nonZeroExit(
                status: result.status,
                message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.standardOutput
    }

    /// 把 HTML 渲染成 PDF（先注入打印样式）。
    static func renderHTML(_ html: String, title: String, to outputURL: URL) throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormatSmithHTML-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let htmlURL = workspace.appendingPathComponent("\(sanitize(title)).html")
        try injectPrintStyle(into: html).write(to: htmlURL, atomically: true, encoding: .utf8)

        return try HTMLtoPDFConverter.convert(htmlURL: htmlURL, to: outputURL)
    }

    // MARK: - 工具

    /// 在 `</head>` 前插入打印样式；没有 head 就放到最前面。
    public static func injectPrintStyle(into html: String) -> String {
        if let headEnd = html.range(of: "</head>", options: .caseInsensitive) {
            return html.replacingCharacters(in: headEnd, with: printStyle + "\n</head>")
        }
        if let headStart = html.range(of: "<head>", options: .caseInsensitive) {
            return html.replacingCharacters(in: headStart, with: "<head>\n\(printStyle)")
        }
        return printStyle + "\n" + html
    }

    static func readText(_ url: URL) throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        // 有些文件不是 UTF-8，用系统推断再试一次。
        var encoding: UInt = 0
        if let text = try? NSString(contentsOf: url, usedEncoding: &encoding) {
            return text as String
        }
        throw ConversionError.unsupportedInput(url.lastPathComponent)
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = OutputNaming.sanitize(name)
        return cleaned.isEmpty ? "document" : cleaned
    }
}
