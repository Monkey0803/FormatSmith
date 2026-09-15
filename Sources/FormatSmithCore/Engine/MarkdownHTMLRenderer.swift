import Foundation

/// 一个够用就好、但完全可预测的 Markdown → HTML 转换器。
///
/// 存在的理由：pandoc 不在的机器上，Markdown 也必须能转。
/// 与其自己用 TextKit 做分页，不如先生成 HTML，再复用已经验证过的
/// WKWebView 渲染路径 —— 字体、分页、打印样式都交给 WebKit。
///
/// 刻意**不**追求完整支持 CommonMark：只覆盖日常写法，
/// 遇到不认识的语法就按普通段落处理，不猜。
public enum MarkdownHTMLRenderer {

    /// 把 Markdown 正文渲染成一份可独立打开的 HTML 文档。
    public static func renderDocument(markdown: String, title: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>\(escape(title))</title>
        </head>
        <body>
        \(renderBody(markdown))
        </body>
        </html>
        """
    }

    /// 只渲染正文部分（不包 head），便于单测。
    public static func renderBody(_ markdown: String) -> String {
        var html: [String] = []
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        var index = 0
        var paragraph: [String] = []
        var listItems: [String] = []
        var listIsOrdered = false
        var quoteLines: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html.append("<p>\(renderInline(paragraph.joined(separator: " ")))</p>")
            paragraph.removeAll()
        }

        func flushList() {
            guard !listItems.isEmpty else { return }
            let tag = listIsOrdered ? "ol" : "ul"
            let items = listItems.map { "<li>\(renderInline($0))</li>" }.joined(separator: "\n")
            html.append("<\(tag)>\n\(items)\n</\(tag)>")
            listItems.removeAll()
        }

        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            let body = quoteLines.map { renderInline($0) }.joined(separator: "<br>")
            html.append("<blockquote><p>\(body)</p></blockquote>")
            quoteLines.removeAll()
        }

        func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 围栏代码块
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence) { break }
                    code.append(lines[index])
                    index += 1
                }
                html.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>")
                index += 1
                continue
            }

            // 空行：结束当前块
            if trimmed.isEmpty {
                flushAll()
                index += 1
                continue
            }

            // 水平线
            if isHorizontalRule(trimmed) {
                flushAll()
                html.append("<hr>")
                index += 1
                continue
            }

            // 标题
            if let heading = parseHeading(trimmed) {
                flushAll()
                html.append("<h\(heading.level)>\(renderInline(heading.text))</h\(heading.level)>")
                index += 1
                continue
            }

            // 引用
            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                quoteLines.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                index += 1
                continue
            }

            // 列表
            if let item = parseListItem(trimmed) {
                flushParagraph()
                flushQuote()
                if !listItems.isEmpty, item.ordered != listIsOrdered {
                    flushList()
                }
                listIsOrdered = item.ordered
                listItems.append(item.text)
                index += 1
                continue
            }

            // 表格分隔行（| --- | --- |）跳过，避免当成段落
            if isTableDelimiter(trimmed) {
                index += 1
                continue
            }

            // 普通段落
            flushList()
            flushQuote()
            paragraph.append(trimmed)
            index += 1
        }

        flushAll()
        return html.joined(separator: "\n")
    }

    // MARK: - 行内

    /// 处理行内语法：代码、粗体、斜体、链接、图片。
    public static func renderInline(_ text: String) -> String {
        var result = escape(text)

        // 行内代码优先，避免里面的星号被当成强调
        var codeSpans: [String] = []
        result = replacePattern(in: result, pattern: "`([^`]+)`") { match in
            codeSpans.append(match[1])
            return "\u{0}CODE\(codeSpans.count - 1)\u{0}"
        }

        // 图片先于链接处理（语法只差一个 !）
        result = replacePattern(in: result, pattern: "!\\[([^\\]]*)\\]\\(([^)\\s]+)[^)]*\\)") { match in
            let alt = match[1].isEmpty ? "image" : match[1]
            return "<em>[\(alt)]</em>"
        }
        result = replacePattern(in: result, pattern: "\\[([^\\]]+)\\]\\(([^)\\s]+)[^)]*\\)") { match in
            "<a href=\"\(match[2])\">\(match[1])</a>"
        }
        result = replacePattern(in: result, pattern: "\\*\\*([^*]+)\\*\\*") { "<strong>\($0[1])</strong>" }
        result = replacePattern(in: result, pattern: "__([^_]+)__") { "<strong>\($0[1])</strong>" }
        result = replacePattern(in: result, pattern: "\\*([^*]+)\\*") { "<em>\($0[1])</em>" }
        result = replacePattern(in: result, pattern: "(?<![\\w_])_([^_]+)_(?![\\w_])") { "<em>\($0[1])</em>" }
        result = replacePattern(in: result, pattern: "~~([^~]+)~~") { "<del>\($0[1])</del>" }

        // 还原代码
        for (offset, code) in codeSpans.enumerated() {
            result = result.replacingOccurrences(of: "\u{0}CODE\(offset)\u{0}", with: "<code>\(code)</code>")
        }
        return result
    }

    // MARK: - 工具

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }
        let level = hashes.count
        guard level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        // ATX 标题要求 # 后有空格（或整行只有 #）
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        // 去掉结尾的 # 号
        let cleaned = text.replacingOccurrences(
            of: "#+\\s*$", with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        return (level, cleaned)
    }

    static func parseListItem(_ line: String) -> (ordered: Bool, text: String)? {
        if let match = firstMatch(line, pattern: "^[-*+]\\s+(.*)$") {
            return (false, match[1])
        }
        if let match = firstMatch(line, pattern: "^\\d+[.)]\\s+(.*)$") {
            return (true, match[1])
        }
        return nil
    }

    static func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    static func isTableDelimiter(_ line: String) -> Bool {
        guard line.hasPrefix("|") || line.contains("|") else { return false }
        let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// 用正则做替换，回调拿到捕获组（下标 0 是整段匹配）。
    static func replacePattern(
        in text: String,
        pattern: String,
        transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = ""
        var lastEnd = text.startIndex

        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let matchRange = Range(match.range, in: text) else { return }
            result += text[lastEnd..<matchRange.lowerBound]
            var groups: [String] = []
            for index in 0..<match.numberOfRanges {
                if let groupRange = Range(match.range(at: index), in: text) {
                    groups.append(String(text[groupRange]))
                } else {
                    groups.append("")
                }
            }
            result += transform(groups)
            lastEnd = matchRange.upperBound
        }
        result += text[lastEnd...]
        return result
    }

    static func firstMatch(_ text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        var groups: [String] = []
        for index in 0..<match.numberOfRanges {
            if let groupRange = Range(match.range(at: index), in: text) {
                groups.append(String(text[groupRange]))
            } else {
                groups.append("")
            }
        }
        return groups
    }
}
