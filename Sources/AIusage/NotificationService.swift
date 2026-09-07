import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    func sendCriticalAlert(for window: UsageWindow) async {
        guard AppSettings.notificationsEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = L10n.string("notification.highUsage")
        let usage = window.usedPercent.map { L10n.string("window.used", Int($0.rounded())) } ?? L10n.string("notification.unknownUsage")
        content.body = L10n.string("notification.body", window.localizedLabel, usage, window.resetSummary(now: Date()))
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "aiusage-\(window.alertKey)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}
