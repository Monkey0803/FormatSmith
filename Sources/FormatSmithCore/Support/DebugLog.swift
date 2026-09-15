import Foundation

/// 仅在设置环境变量 `FORMATSMITH_DEBUG=1` 时输出诊断日志到 stderr。
/// 用于排查「拖入文件后没有反应」这类问题；正常使用不会有任何输出。
public enum DebugLog {
    public static let isEnabled = ProcessInfo.processInfo.environment["FORMATSMITH_DEBUG"] != nil

    public static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        FileHandle.standardError.write("[FormatSmith] \(message())\n".data(using: .utf8)!)
    }
}
