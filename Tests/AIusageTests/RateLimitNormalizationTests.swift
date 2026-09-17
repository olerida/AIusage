import XCTest
@testable import AIusage

final class RateLimitNormalizationTests: XCTestCase {
    func testNormalizesFiveHourAndWeeklyWindows() throws {
        let response = try decode("""
        {
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": {"usedPercent": 91, "windowDurationMins": 300, "resetsAt": 1700000000},
              "secondary": {"usedPercent": 42, "windowDurationMins": 10080, "resetsAt": 1700604800}
            }
          },
          "rateLimitResetCredits": {"availableCount": 1, "credits": []}
        }
        """)

        let windows = response.normalizedWindows()
        XCTAssertEqual(windows.map(\.kind), [.fiveHours, .weekly])
        XCTAssertEqual(windows[0].usedPercent, 91)
        XCTAssertEqual(windows[0].remainingPercent, 9)
        XCTAssertTrue(windows[0].isCritical)
        XCTAssertFalse(windows[1].isCritical)
    }

    func testUnknownWindowIsNotMislabelled() throws {
        let response = try decode("""
        {"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":60,"resetsAt":1700000000}}}
        """)

        let window = try XCTUnwrap(response.normalizedWindows().first)
        XCTAssertEqual(window.kind, .other)
        XCTAssertEqual(window.label, "Otra ventana (60 min)")
    }

    func testResetDetailsAndMissingExpiry() throws {
        let response = try decode("""
        {
          "rateLimitResetCredits": {
            "availableCount": 2,
            "credits": [
              {"id":"later","status":"available","expiresAt":null,"title":"Sin fecha"},
              {"id":"soon","status":"available","expiresAt":1900000000,"title":"Próximo"},
              {"id":"expired","status":"expired","expiresAt":1600000000,"title":"Caducado"}
            ]
          }
        }
        """)

        XCTAssertEqual(response.availableResetCount, 2)
        XCTAssertEqual(response.normalizedResets().map(\.id), ["soon", "later"])
        XCTAssertNil(response.normalizedResets()[1].expiresAt)
    }

    func testResetIsHighlightedWithThreeDaysOrLessRemaining() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = ResetCredit(payload: ResetCreditPayload(
            id: "soon",
            resetType: "usage",
            status: "available",
            grantedAt: nil,
            expiresAt: Int64(now.timeIntervalSince1970) + 3 * 24 * 60 * 60,
            title: "Próximo",
            description: nil
        ))
        let later = ResetCredit(payload: ResetCreditPayload(
            id: "later",
            resetType: "usage",
            status: "available",
            grantedAt: nil,
            expiresAt: Int64(now.timeIntervalSince1970) + 4 * 24 * 60 * 60,
            title: "Más tarde",
            description: nil
        ))
        let withoutExpiry = ResetCredit(payload: ResetCreditPayload(
            id: "unknown",
            resetType: "usage",
            status: "available",
            grantedAt: nil,
            expiresAt: nil,
            title: "Sin fecha",
            description: nil
        ))

        XCTAssertTrue(reset.expires(withinDays: 3, relativeTo: now))
        XCTAssertFalse(later.expires(withinDays: 3, relativeTo: now))
        XCTAssertFalse(withoutExpiry.expires(withinDays: 3, relativeTo: now))
    }

    func testDecodesDailyTokenUsageBuckets() throws {
        let usage = try JSONDecoder().decode(AccountTokenUsage.self, from: Data("""
        {
          "summary": {
            "lifetimeTokens": 1200,
            "peakDailyTokens": 600,
            "longestRunningTurnSec": 20,
            "currentStreakDays": 2,
            "longestStreakDays": 4
          },
          "dailyUsageBuckets": [
            {"startDate":"2026-09-05","tokens":600},
            {"startDate":"2026-09-06","tokens":600}
          ]
        }
        """.utf8))

        XCTAssertEqual(usage.dailyUsageBuckets?.map(\.tokens), [600, 600])
        XCTAssertEqual(usage.dailyUsageBuckets?.first?.id, "2026-09-05")
    }

    private func decode(_ json: String) throws -> RateLimitsResponse {
        try JSONDecoder().decode(RateLimitsResponse.self, from: Data(json.utf8))
    }
}

final class UsageWindowTests: XCTestCase {
    func testAlertKeyChangesWithResetCycle() {
        let first = UsageWindow(id: "codex.primary", kind: .fiveHours, label: "5 horas", durationMinutes: 300, usedPercent: 90.1, resetsAt: Date(timeIntervalSince1970: 100))
        let second = UsageWindow(id: "codex.primary", kind: .fiveHours, label: "5 horas", durationMinutes: 300, usedPercent: 90.1, resetsAt: Date(timeIntervalSince1970: 200))
        XCTAssertNotEqual(first.alertKey, second.alertKey)
        XCTAssertTrue(first.isCritical)
    }

    func testExactlyNinetyPercentIsNotCritical() {
        let window = UsageWindow(id: "weekly", kind: .weekly, label: "Semanal", durationMinutes: 10080, usedPercent: 90, resetsAt: nil)
        XCTAssertFalse(window.isCritical)
        XCTAssertFalse(window.exceedsNotificationThreshold(90))
        XCTAssertTrue(window.exceedsNotificationThreshold(89))
    }
}
