import Foundation

/// 输出文件命名：模板展开、非法字符清理、重名唯一化。
public enum OutputNaming {

    /// 展开文件名模板。
    ///
    /// 占位符：`{name}` 原文件名、`{page}` 页码、`{total}` 总页数、`{date}` 日期、`{time}` 时间。
    /// 单张输出（`page == nil`）时 `{page}`/`{total}` 会被替换成空串。
    public static func expand(
        pattern: String,
        documentName: String,
        page: Int?,
        pageCount: Int?,
        padsPageNumbers: Bool,
        date: Date = Date()
    ) -> String {
        let template = pattern.isEmpty ? "{name}-{page}" : pattern

        let pageLabel: String
        if let page {
            if padsPageNumbers, let pageCount, pageCount > 0 {
                let width = max(String(pageCount).count, 1)
                pageLabel = String(format: "%0\(width)d", page)
            } else {
                pageLabel = String(page)
            }
        } else {
            pageLabel = ""
        }

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")

        var result =
            template
            .replacingOccurrences(of: "{name}", with: documentName)
            .replacingOccurrences(of: "{page}", with: pageLabel)
            .replacingOccurrences(of: "{total}", with: pageCount.map(String.init) ?? "")

        for (token, format) in [("{date}", "yyyyMMdd"), ("{time}", "HHmmss")] where result.contains(token) {
            stamp.dateFormat = format
            result = result.replacingOccurrences(of: token, with: stamp.string(from: date))
        }

        // 去掉首尾的分隔符：{page} 在单张输出时会被替换成空串，
        // 不处理的话文件名会留下 "pic-" 这样的尾巴。
        let trimmed = sanitize(result).trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
        if !trimmed.isEmpty { return trimmed }

        // 清理后什么都不剩，兜底用原文件名。
        let fallback = pageLabel.isEmpty ? documentName : "\(documentName)-\(pageLabel)"
        let trimmedFallback = sanitize(fallback).trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
        return trimmedFallback.isEmpty ? "output" : trimmedFallback
    }

    /// 去除路径分隔符与非法字符，避免模板把文件写到别的目录。
    public static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned =
            name
            .components(separatedBy: illegal)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        // "." 与 ".." 会被文件系统解释成当前目录与上级目录。
        if cleaned.allSatisfy({ $0 == "." }) { return "" }
        return cleaned
    }

    /// 生成完整文件名（含扩展名）。
    public static func fileName(
        for documentName: String,
        page: Int?,
        pageCount: Int?,
        settings: ConversionSettings
    ) -> String {
        let base = expand(
            pattern: settings.filenamePattern,
            documentName: documentName,
            page: page,
            pageCount: pageCount,
            padsPageNumbers: settings.padsPageNumbers
        )
        return "\(base).\(settings.format.fileExtension)"
    }

    /// 若目标已存在，追加 -1、-2 … 直到找到空位。绝不覆盖用户已有文件。
    public static func uniqueURL(_ url: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }

        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent

        var index = 1
        while index < 10_000 {
            let candidate =
                directory
                .appendingPathComponent("\(base)-\(index)")
                .appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
        return url
    }
}
