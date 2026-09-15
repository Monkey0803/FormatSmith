import FormatSmithCore
import SwiftUI

/// 当前界面语言，供视图树内的子视图读取。
///
/// 同时也让系统控件（日期、数字、文本方向）跟随所选语言。
struct AppLanguageKey: EnvironmentKey {
    static let defaultValue = AppLanguage.system
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageKey.self] }
        set { self[AppLanguageKey.self] = newValue }
    }
}

extension AppLanguage {
    /// 供 `.environment(\.locale, …)` 使用；跟随系统时用当前生效的 locale。
    var locale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        case .english: return Locale(identifier: "en")
        case .simplifiedChinese: return Locale(identifier: "zh-Hans")
        }
    }
}

extension View {
    /// 声明「这个视图会显示本地化文案」，让它在语言切换后重新取词。
    ///
    /// 为什么需要这一步：`Localized.text(...)` 是一个静态函数，
    /// SwiftUI 无从知道某个视图用到了它。视图的 body 只有在**读到了会变的观察对象**时
    /// 才会重新求值，所以这里显式把当前语言读进来 —— 一是建立依赖，
    /// 二是把它放进 environment，让子视图和系统格式化也跟着走。
    ///
    /// 之前用的是给根视图换 `.id(...)` 强制重建，能刷新文案，但会把
    /// 滚动位置和输入焦点一起清掉；这个做法没有那个副作用。
    func localizedText(_ language: AppLanguage) -> some View {
        environment(\.appLanguage, language)
            .environment(\.locale, language.locale)
    }
}
