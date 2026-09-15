import Foundation

/// 可以当作状态文案参数的值。
///
/// 刻意保留类型：`%d` 传字符串会直接崩，不能一律转成 String。
public protocol StatusArgument {
    var statusArgument: StatusMessage.Argument { get }
}

extension String: StatusArgument {
    public var statusArgument: StatusMessage.Argument { .text(self) }
}

extension Int: StatusArgument {
    public var statusArgument: StatusMessage.Argument { .number(self) }
}

/// 底部状态栏的一句话。
///
/// 存的是「key + 参数」而不是渲染好的字符串：这样切换语言后，
/// 已经显示在界面上的状态也会立刻换成新语言，而不是停留在上一个语言里。
public struct StatusMessage: Equatable {

    public enum Argument: Equatable {
        case text(String)
        case number(Int)

        var cVarArg: CVarArg {
            switch self {
            case let .text(value): return value as CVarArg
            case let .number(value): return value as CVarArg
            }
        }
    }

    public let key: String
    public let arguments: [Argument]

    public init(_ key: String, _ arguments: any StatusArgument...) {
        self.key = key
        self.arguments = arguments.map(\.statusArgument)
    }

    /// 用当前语言渲染出来。
    public func resolved() -> String {
        let format = Localized.text(key)
        guard !arguments.isEmpty else { return format }
        return String(format: format, arguments: arguments.map(\.cVarArg))
    }

    /// 「完成」类的状态用来选图标与颜色。
    public var isSuccess: Bool {
        key.hasPrefix("Finished") || key.hasPrefix("Merged")
    }

    public static let idle = StatusMessage("Drop files here, or click “Choose Files” to start.")
}
