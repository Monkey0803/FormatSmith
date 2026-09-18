import Foundation

/// 「1-3,5,8-10」形式的页码范围解析。
///
/// 刻意做成纯函数：这是最容易出错、也最值得回归测试的一段逻辑。
public enum PageRangeParser {

    /// 解析页码文本，返回升序去重的 1 基页码数组。
    ///
    /// 规则：
    /// - 空文本或全空白 → 「全部页面」（`1...pageCount`）。
    /// - 支持 `1-3`、`5`、`8-10`、`3-`（到末尾）、`-3`（从开头）。
    /// - 反向区间 `8-5` 会被自动纠正为 `5-8`。
    /// - 越界页码与非法片段直接丢弃，不抛错。
    /// - 兼容中文逗号与全角连字符。
    public static func parse(_ text: String, pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(1...pageCount) }

        var selected = Set<Int>()
        for chunk in normalize(trimmed).split(separator: ",") where !chunk.isEmpty {
            let bounds = chunk.split(separator: "-", omittingEmptySubsequences: false)
            switch bounds.count {
            case 1:
                if let page = Int(bounds[0]) {
                    insert(page, into: &selected, pageCount: pageCount)
                }
            case 2:
                let lower = Int(bounds[0]) ?? 1
                let upper = Int(bounds[1]) ?? pageCount
                let start = min(lower, upper)
                let end = max(lower, upper)
                for page in start...max(start, end) {
                    insert(page, into: &selected, pageCount: pageCount)
                }
            default:
                continue
            }
        }
        return selected.sorted()
    }

    /// 与 `parse` 同样的语法，但**保留书写顺序**。
    ///
    /// 给「重排」和「提取」用：`3,1` 的意思是「先放第 3 页，再放第 1 页」，
    /// 而 `parse` 会按升序排成 1,3 —— 那样重排就完全失去意义了。
    /// 重复出现的页码只保留第一次出现的位置。
    public static func parseOrdered(_ text: String, pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(1...pageCount) }

        var ordered: [Int] = []
        var seen = Set<Int>()

        func append(_ page: Int) {
            guard page >= 1, page <= pageCount, !seen.contains(page) else { return }
            seen.insert(page)
            ordered.append(page)
        }

        for chunk in normalize(trimmed).split(separator: ",") where !chunk.isEmpty {
            let bounds = chunk.split(separator: "-", omittingEmptySubsequences: false)
            switch bounds.count {
            case 1:
                if let page = Int(bounds[0]) { append(page) }
            case 2:
                let lower = Int(bounds[0]) ?? 1
                let upper = Int(bounds[1]) ?? pageCount
                let start = min(lower, upper)
                let end = max(lower, upper)
                // 区间内部保持自然顺序；写成 5-3 时按 3..5 展开，与 parse 一致
                for page in start...max(start, end) { append(page) }
            default:
                continue
            }
        }
        return ordered
    }

    /// 判断这段文本是否「看起来合法」，用于 UI 提前给出提示。
    public static func validate(_ text: String, pageCount: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }  // 空 = 全部
        return !parse(text, pageCount: pageCount).isEmpty
    }

    private static func insert(_ page: Int, into set: inout Set<Int>, pageCount: Int) {
        guard page >= 1, page <= pageCount else { return }
        set.insert(page)
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "、", with: ",")
            .replacingOccurrences(of: "－", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
    }
}
