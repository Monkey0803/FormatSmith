import Foundation

/// 把「用户给的文件与文件夹」展开成真正要处理的文件清单。
///
/// 命令行以前遇到文件夹只会打印 `Skipping directory` —— 而界面上把文件夹拖进来是好用的。
/// 同一个工具的两副面孔不该有这种差别，所以规则收到这里，两边共用。
public enum InputExpansion {

    public struct Outcome: Sendable {
        /// 要处理的文件，顺序是确定的。
        public let files: [URL]
        /// 看懂了但用不上、以及根本不是文件的路径。
        public let skipped: [URL]
    }

    /// 展开规则：
    /// - 文件夹：枚举里面的文件（跳过隐藏文件与包内部），**按名字排序** ——
    ///   文件系统给的顺序不可靠，而顺序在「图片合并成 PDF」这种事上是有意义的。
    /// - 显式给出的文件：**保持用户给的顺序**，不排序。
    public static func expand(_ urls: [URL], fileManager: FileManager = .default) -> Outcome {
        var files: [URL] = []
        var skipped: [URL] = []

        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                skipped.append(url)
                continue
            }

            if isDirectory.boolValue {
                files.append(contentsOf: contents(of: url, fileManager: fileManager))
            } else if isSupported(url) {
                files.append(url)
            } else {
                skipped.append(url)
            }
        }
        return Outcome(files: files, skipped: skipped)
    }

    /// 文件夹里的文件，按名字排序。
    public static func contents(of directory: URL, fileManager: FileManager = .default) -> [URL] {
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var inside: [URL] = []
        // 注意：不能写成 `while let child = ..., isSupported(child)`。
        // 那样一遇到「不支持的东西」（例如子目录本身）条件为假，**整个循环就结束了**，
        // 子目录里的文件永远看不到 —— 界面里拖入文件夹时也因此一直忽略子目录。
        while let child = enumerator?.nextObject() as? URL {
            guard isSupported(child) else { continue }
            inside.append(child)
        }
        return inside.sorted(by: isOrderedBefore)
    }

    /// 这个路径是不是能处理的输入。
    public static func isSupported(_ url: URL) -> Bool {
        switch InputKind.detect(url: url) {
        case .pdf, .image, .office, .html, .markdown, .plainText: return true
        case .unknown: return false
        }
    }

    /// 按文件名排序，同名再比路径 —— 保证结果稳定。
    public static func isOrderedBefore(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.lastPathComponent
        let right = rhs.lastPathComponent
        if left != right {
            return left.localizedStandardCompare(right) == .orderedAscending
        }
        return lhs.path < rhs.path
    }
}
