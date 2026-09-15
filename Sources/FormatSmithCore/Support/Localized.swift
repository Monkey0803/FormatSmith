import Foundation

/// 界面语言。
///
/// `english` 不需要 `en.lproj`：本项目约定**英文原文就是 key**，
/// 找不到语言包时回退到 key 本身就是正确的英文。
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    /// 跟随系统设置。
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }

    /// 语言名用**它自己**的写法，否则用户切成看不懂的语言后就找不回来了。
    public var displayName: String {
        switch self {
        case .system: return Localized.text("Follow system")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    /// 用于 `AppleLanguages` 的语言代码；`system` 返回 nil。
    public var languageCode: String? {
        self == .system ? nil : rawValue
    }
}

/// 极简本地化入口。
///
/// 约定：**英文原文就是 key**。`zh-Hans.lproj` 提供中文；
/// 想加别的语言，只要在 `Resources/i18n/` 下加目录并在 `AppLanguage` 里加一个 case。
///
/// 资源以 `.lproj` 目录形式由 `scripts/build-app.sh` 直接放进
/// `FormatSmith.app/Contents/Resources/`，所以这里查的是 `Bundle.main` 里的子包。
public enum Localized {

    /// 强制使用英文原文。
    ///
    /// 命令行模式会打开它：脚本解析输出时不应该受系统语言影响，
    /// 「Not available in this build yet.」变成中文会让 grep 和错误处理全部失效。
    /// 由命令行入口在解析参数前设置一次，之后不再变化。
    nonisolated(unsafe) public static var forcesBaseLanguage = false

    private nonisolated(unsafe) static var currentLanguage: AppLanguage = .system
    private nonisolated(unsafe) static var bundleCache: [String: Bundle] = [:]
    private static let lock = NSLock()

    /// 当前界面语言。设置它会立刻影响后续所有取词（界面重建后即可见）。
    public static var language: AppLanguage {
        get {
            lock.lock()
            defer { lock.unlock() }
            return currentLanguage
        }
        set {
            lock.lock()
            currentLanguage = newValue
            lock.unlock()
        }
    }

    /// 取一条本地化文案。找不到时返回 key（即英文原文）。
    public static func text(_ key: String) -> String {
        guard !forcesBaseLanguage else { return key }
        guard let bundle = activeBundle else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// 取一条带格式参数的本地化文案。
    public static func text(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), arguments: arguments)
    }

    /// 当前应该用哪个语言包。
    ///
    /// - `.system` 交给 `Bundle.main`，由系统按用户的语言偏好挑选。
    /// - 指定语言时直接取对应的 `.lproj`；取不到就返回 nil，
    ///   由调用方回退到英文原文 —— 对 `.english` 来说这恰好就是正确答案。
    static var activeBundle: Bundle? {
        switch language {
        case .system:
            return .main
        case let explicit:
            return bundle(for: explicit)
        }
    }

    /// 取某个语言的 `.lproj` 子包；没有就返回 nil。
    public static func bundle(for language: AppLanguage) -> Bundle? {
        guard let code = language.languageCode else { return nil }

        lock.lock()
        if let cached = bundleCache[code] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            return nil
        }

        lock.lock()
        bundleCache[code] = bundle
        lock.unlock()
        return bundle
    }

    /// 当前应用包里实际带了哪些语言（用于诊断输出）。
    public static func bundledLanguages() -> [String] {
        // localizations 会把 CFBundleLocalizations 与 .lproj 目录都算进来，去重后再排序。
        Array(Set(Bundle.main.localizations.filter { $0 != "Base" })).sorted()
    }

    /// 把 key 在指定语言下解析出来，供诊断命令使用。
    ///
    /// 刻意**不**受 `forcesBaseLanguage` 影响：这是「请告诉我它在 X 语言下长什么样」，
    /// 是显式的诊断请求，不是普通的界面取词。
    public static func resolve(_ key: String, in language: AppLanguage) -> String {
        switch language {
        case .system:
            return Bundle.main.localizedString(forKey: key, value: key, table: nil)
        default:
            guard let bundle = bundle(for: language) else { return key }
            return bundle.localizedString(forKey: key, value: key, table: nil)
        }
    }
}
