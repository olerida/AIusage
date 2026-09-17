import Foundation
import UserNotifications

@MainActor
protocol NotificationDelivering: AnyObject {
    func requestAuthorization() async -> Bool
    func sendUsageAlert(for window: UsageWindow) async -> Bool
    func sendResetExpirationAlert(for reset: ResetCredit, now: Date) async -> Bool
}

@MainActor
final class NotificationService: NotificationDelivering {
    func requestAuthorization() async -> Bool {
        await isAuthorized(UNUserNotificationCenter.current())
    }

    func sendUsageAlert(for window: UsageWindow) async -> Bool {
        guard AppSettings.notificationsEnabled else { return false }
        let usage = window.usedPercent.map {
            L10n.string("window.used", Int($0.rounded()))
        } ?? L10n.string("notification.unknownUsage")
        let body = L10n.string(
            "notification.body",
            window.localizedLabel,
            usage,
            window.resetSummary(now: Date())
        )
        return await deliver(
            identifier: "aiusage-\(window.alertKey)",
            title: L10n.string("notification.highUsage"),
            body: body
        )
    }

    func sendResetExpirationAlert(for reset: ResetCredit, now: Date) async -> Bool {
        guard AppSettings.notificationsEnabled,
              AppSettings.resetExpirationNotificationsEnabled,
              let expiresAt = reset.expiresAt else { return false }
        let body = L10n.string(
            "notification.resetExpiring.body",
            reset.title,
            relativeSummary(until: expiresAt, now: now),
            expiresAt.formatted(date: .abbreviated, time: .shortened)
        )
        return await deliver(
            identifier: "aiusage-\(reset.expirationAlertKey)",
            title: L10n.string("notification.resetExpiring.title"),
            body: body
        )
    }

    private func deliver(identifier: String, title: String, body: String) async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard await isAuthorized(center) else { return false }
        guard AppSettings.notificationsEnabled else { return false }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    private func isAuthorized(_ center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func relativeSummary(until date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return L10n.string("reset.summary.days", days, hours) }
        if hours > 0 { return L10n.string("reset.summary.hours", hours, minutes) }
        return L10n.string("reset.summary.minutes", minutes)
    }
}
