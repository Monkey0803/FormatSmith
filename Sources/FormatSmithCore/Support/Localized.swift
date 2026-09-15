import Foundation

/// 极简本地化入口。
///
/// 约定：**英文原文就是 key**。`en.lproj` 可以不存在（回退到 key 本身），
/// `zh-Hans.lproj` 提供中文。
///
/// 资源以 `.lproj` 目录形式由 `scripts/build-app.sh` 直接放进
/// `FormatSmith.app/Contents/Resources/`，因此这里查的是 `Bundle.main`。
/// 这样比 SwiftPM 的资源 bundle 更贴近标准 macOS 应用布局，也不需要 `Bundle.module`。
public enum Localized {

    /// 强制使用英文原文。
    ///
    /// 命令行模式会打开它：脚本解析输出时不应该受系统语言影响，
    /// 「Not available in this build yet.」变成中文会让 grep 和错误处理全部失效。
    /// 由命令行入口在解析参数前设置一次，之后不再变化。
    nonisolated(unsafe) public static var forcesBaseLanguage = false

    /// 取一条本地化文案。找不到时返回 key（即英文原文）。
    public static func text(_ key: String) -> String {
        guard !forcesBaseLanguage else { return key }
        return Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    /// 取一条带格式参数的本地化文案。
    public static func text(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), arguments: arguments)
    }
}
