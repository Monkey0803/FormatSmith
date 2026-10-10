import AppKit
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

    /// 交给 AppKit；`nil` 表示不干预，跟随系统。
    ///
    /// 这里刻意**不用** SwiftUI 的 `preferredColorScheme`：
    /// 它能把界面切成深色，但改回 `.system`（即传 `nil`）时并不会撤销已经设过的方案，
    /// 于是「深色 → 跟随系统」看起来毫无反应 —— 系统是浅色，窗口却还是深的。
    /// `NSApp.appearance = nil` 是 AppKit 的原生做法，会老实回到跟随系统。
    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// 把外观偏好落到应用上。
///
/// 单独抽出来是为了有个明确的地方可以测试与记录：
/// 「偏好是什么」和「应用实际是什么外观」是两件事。
enum AppearanceController {
    static func apply(_ appearance: AppAppearance) {
        NSApp?.appearance = appearance.appKitAppearance
    }

    /// 当前应用实际生效的外观，用于日志与排查。
    static var effectiveName: String {
        NSApp?.effectiveAppearance.name.rawValue ?? "unknown"
    }

    /// 是否处于「跟随系统」（没有钉住任何方案）。
    static var isFollowingSystem: Bool {
        NSApp?.appearance == nil
    }
}
