import Foundation
import XCTest
@testable import AIusage

@MainActor
final class NotificationAlertTests: XCTestCase {
    func testDisabledNotificationsAreNeitherDeliveredNorMarked() async {
        let saved = SavedNotificationSettings()
        defer { saved.restore() }
        AppSettings.notificationsEnabled = false
        AppSettings.alertedKeys = []

        let delivery = FakeNotificationDelivery()
        let store = UsageStore(notificationService: delivery)
        let window = makeWindow(kind: .fiveHours, usedPercent: 99)

        await store.evaluateAlerts(for: [window], resets: [])

        XCTAssertTrue(delivery.usageWindows.isEmpty)
        XCTAssertFalse(AppSettings.alertedKeys.contains(window.alertKey))
    }

    func testFailedDeliveryIsNotMarkedAndCanRetry() async {
        let saved = SavedNotificationSettings()
        defer { saved.restore() }
        AppSettings.notificationsEnabled = true
        AppSettings.fiveHourNotificationThreshold = 90
        AppSettings.resetExpirationNotificationsEnabled = false
        AppSettings.alertedKeys = []

        let delivery = FakeNotificationDelivery(usageResults: [false, true])
        let store = UsageStore(notificationService: delivery)
        let window = makeWindow(kind: .fiveHours, usedPercent: 91)

        await store.evaluateAlerts(for: [window], resets: [])
        XCTAssertFalse(AppSettings.alertedKeys.contains(window.alertKey))

        await store.evaluateAlerts(for: [window], resets: [])
        XCTAssertEqual(delivery.usageWindows.count, 2)
        XCTAssertTrue(AppSettings.alertedKeys.contains(window.alertKey))
    }

    func testEachUsageWindowUsesItsOwnThreshold() async {
        let saved = SavedNotificationSettings()
        defer { saved.restore() }
        AppSettings.notificationsEnabled = true
        AppSettings.fiveHourNotificationThreshold = 80
        AppSettings.weeklyNotificationThreshold = 95
        AppSettings.resetExpirationNotificationsEnabled = false
        AppSettings.alertedKeys = []

        let delivery = FakeNotificationDelivery()
        let store = UsageStore(notificationService: delivery)
        let fiveHour = makeWindow(kind: .fiveHours, usedPercent: 81)
        let weekly = makeWindow(kind: .weekly, usedPercent: 94)

        await store.evaluateAlerts(for: [fiveHour, weekly], resets: [])

        XCTAssertEqual(delivery.usageWindows.map(\.kind), [.fiveHours])
        XCTAssertTrue(AppSettings.alertedKeys.contains(fiveHour.alertKey))
        XCTAssertFalse(AppSettings.alertedKeys.contains(weekly.alertKey))
    }

    func testResetExpirationAlertUsesLeadDaysAndIsSentOnce() async {
        let saved = SavedNotificationSettings()
        defer { saved.restore() }
        AppSettings.notificationsEnabled = true
        AppSettings.resetExpirationNotificationsEnabled = true
        AppSettings.resetExpirationLeadDays = 3
        AppSettings.alertedKeys = []

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let soon = makeReset(id: "soon", expiresAt: now.addingTimeInterval(2 * 86_400))
        let later = makeReset(id: "later", expiresAt: now.addingTimeInterval(4 * 86_400))
        let delivery = FakeNotificationDelivery()
        let store = UsageStore(notificationService: delivery)

        await store.evaluateAlerts(for: [], resets: [soon, later], now: now)
        await store.evaluateAlerts(for: [], resets: [soon, later], now: now)

        XCTAssertEqual(delivery.resets.map(\.id), ["soon"])
        XCTAssertTrue(AppSettings.alertedKeys.contains(soon.expirationAlertKey))
        XCTAssertFalse(AppSettings.alertedKeys.contains(later.expirationAlertKey))
    }

    private func makeWindow(kind: UsageWindow.Kind, usedPercent: Double) -> UsageWindow {
        UsageWindow(
            id: "test.\(kind.rawValue)",
            kind: kind,
            label: kind.rawValue,
            durationMinutes: kind == .fiveHours ? 300 : 10_080,
            usedPercent: usedPercent,
            resetsAt: Date().addingTimeInterval(86_400)
        )
    }

    private func makeReset(id: String, expiresAt: Date) -> ResetCredit {
        ResetCredit(payload: ResetCreditPayload(
            id: id,
            resetType: "full",
            status: "available",
            grantedAt: nil,
            expiresAt: Int64(expiresAt.timeIntervalSince1970),
            title: "Full reset",
            description: nil
        ))
    }
}

@MainActor
private final class FakeNotificationDelivery: NotificationDelivering {
    var usageWindows: [UsageWindow] = []
    var resets: [ResetCredit] = []
    private var usageResults: [Bool]
    private var resetResults: [Bool]

    init(usageResults: [Bool] = [], resetResults: [Bool] = []) {
        self.usageResults = usageResults
        self.resetResults = resetResults
    }

    func requestAuthorization() async -> Bool {
        true
    }

    func sendUsageAlert(for window: UsageWindow) async -> Bool {
        usageWindows.append(window)
        return usageResults.isEmpty ? true : usageResults.removeFirst()
    }

    func sendResetExpirationAlert(for reset: ResetCredit, now: Date) async -> Bool {
        resets.append(reset)
        return resetResults.isEmpty ? true : resetResults.removeFirst()
    }
}

private struct SavedNotificationSettings {
    let enabled = AppSettings.notificationsEnabled
    let fiveHourThreshold = AppSettings.fiveHourNotificationThreshold
    let weeklyThreshold = AppSettings.weeklyNotificationThreshold
    let resetEnabled = AppSettings.resetExpirationNotificationsEnabled
    let resetLeadDays = AppSettings.resetExpirationLeadDays
    let alertedKeys = AppSettings.alertedKeys

    func restore() {
        AppSettings.notificationsEnabled = enabled
        AppSettings.fiveHourNotificationThreshold = fiveHourThreshold
        AppSettings.weeklyNotificationThreshold = weeklyThreshold
        AppSettings.resetExpirationNotificationsEnabled = resetEnabled
        AppSettings.resetExpirationLeadDays = resetLeadDays
        AppSettings.alertedKeys = alertedKeys
    }
}
