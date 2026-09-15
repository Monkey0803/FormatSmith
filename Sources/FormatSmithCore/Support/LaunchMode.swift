import Foundation

/// 这次进程是图形界面还是命令行。
///
/// 单独抽出来是为了能被测试覆盖：判断错了会导致 GUI 被当成命令行，
/// 从而把界面文案强行锁成英文 —— 这个 bug 真的发生过。
public enum LaunchMode {

    /// 会进入命令行模式、因此必须固定输出英文的参数。
    public static let commandLineFlags: Set<String> = [
        "--convert",
        "--help", "-h",
        "--list-formats",
        "--check-dependencies",
        "--check-localization",
        "--version",
    ]

    public enum Intent: Equatable, Sendable {
        case graphical
        case commandLine
    }

    /// 依据启动参数判断意图。没有任何参数就是图形界面。
    public static func intent(arguments: [String]) -> Intent {
        arguments.contains { commandLineFlags.contains($0) } ? .commandLine : .graphical
    }
}
