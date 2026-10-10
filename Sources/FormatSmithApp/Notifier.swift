import FormatSmithCore
import Foundation
import UserNotifications

/// 转换结束后的系统通知。
///
/// 批量 OCR 一份几百页的扫描件要跑几分钟，用户不会一直盯着窗口。
/// 只在「跑了足够久、很可能已经切走」时才打扰一次。
enum Notifier {

    /// 短于这个时长就不发通知：小批量转换几秒就完，弹通知纯属噪音。
    static let minimumDuration: TimeInterval = 20

    /// 应用没打进 bundle（例如跑测试）时不碰通知中心。
    private static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    static func notifyIfNeeded(duration: TimeInterval, succeeded: Int, failed: Int) {
        guard isAvailable, duration >= minimumDuration, succeeded + failed > 0 else { return }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = Localized.text("Conversion finished")
            if failed > 0 {
                content.body = Localized.text("%d done, %d failed", succeeded, failed)
            } else {
                content.body = Localized.text("%d file(s) written", succeeded)
            }
            content.sound = nil

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }
}
