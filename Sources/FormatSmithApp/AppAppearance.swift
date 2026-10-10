import FormatSmithCore
import SwiftUI

/// 界面外观。
///
/// 「跟随系统」是默认：Mac 用户大多在系统层面切深浅色，
/// 工具应当跟着走，而不是各自为政。
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return Localized.text("Follow system")
        case .light: return Localized.text("Light")
        case .dark: return Localized.text("Dark")
        }
    }

    /// 交给 `preferredColorScheme`；`nil` 表示不干预，跟随系统。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
