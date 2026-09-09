import Foundation

enum AgentKind: String, Codable, CaseIterable, Identifiable {
    case codex
    case githubCopilot

    var id: Self { self }

    var displayName: String {
        switch self {
        case .codex: return L10n.string("agent.codex")
        case .githubCopilot: return L10n.string("agent.githubCopilot")
        }
    }

    var systemImage: String {
        switch self {
        case .codex: return "terminal"
        case .githubCopilot: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

enum JSONValue: Codable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

struct RPCRequest: Encodable {
    let method: String
    let id: Int?
    let params: JSONValue?
}

struct RPCError: Codable, Equatable {
    let code: Int?
    let message: String?
}

struct RPCMessage: Codable {
    let id: Int?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: RPCError?
}

struct AccountInfo: Codable, Equatable {
    let type: String?
    let email: String?
    let planType: String?
}

struct AccountReadResponse: Codable {
    let account: AccountInfo?
    let requiresOpenaiAuth: Bool?
}

struct AccountUpdatedParams: Codable {
    let authMode: String?
    let planType: String?
}

struct LoginStartResponse: Codable {
    let type: String?
    let loginId: String?
    let authUrl: String?
}

struct LoginCompletedParams: Codable {
    let loginId: String?
    let success: Bool
    let error: String?
}

struct LimitMetric: Codable, Equatable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Int64?
}

struct RateLimitBucket: Codable {
    let limitId: String?
    let limitName: String?
    let primary: LimitMetric?
    let secondary: LimitMetric?
    let planType: String?
}

struct ResetCreditPayload: Codable, Equatable {
    let id: String?
    let resetType: String?
    let status: String?
    let grantedAt: Int64?
    let expiresAt: Int64?
    let title: String?
    let description: String?
}

struct RateLimitResetCredits: Codable {
    let availableCount: Int
    let credits: [ResetCreditPayload]?
}

struct RateLimitsResponse: Codable {
    let rateLimits: RateLimitBucket?
    let rateLimitsByLimitId: [String: RateLimitBucket]?
    let rateLimitResetCredits: RateLimitResetCredits?

    var codexBucket: RateLimitBucket? {
        rateLimitsByLimitId?["codex"] ?? rateLimits
    }

    func normalizedWindows() -> [UsageWindow] {
        guard let bucket = codexBucket else { return [] }
        var metrics: [(String, LimitMetric)] = []
        if let primary = bucket.primary { metrics.append(("primary", primary)) }
        if let secondary = bucket.secondary { metrics.append(("secondary", secondary)) }

        return metrics.map { key, metric in
            let duration = metric.windowDurationMins ?? 0
            let kind: UsageWindow.Kind
            let label: String
            switch duration {
            case 300:
                kind = .fiveHours
                label = "5 horas"
            case 10080:
                kind = .weekly
                label = "Semanal"
            default:
                kind = .other
                label = duration > 0 ? "Otra ventana (\(duration) min)" : "Otra ventana"
            }

            return UsageWindow(
                id: "codex.\(key)",
                kind: kind,
                label: label,
                durationMinutes: duration,
                usedPercent: metric.usedPercent.map { min(max($0, 0), 100) },
                resetsAt: metric.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }
    }

    func normalizedResets(relativeTo date: Date = Date()) -> [ResetCredit] {
        guard let payload = rateLimitResetCredits else { return [] }
        return (payload.credits ?? []).map(ResetCredit.init(payload:))
            .filter { reset in
                guard reset.status?.lowercased() != "expired" else { return false }
                return reset.expiresAt.map { $0 > date } ?? true
            }
            .sorted { lhs, rhs in
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (.some(left), .some(right)): return left < right
                case (.some, .none): return true
                default: return false
                }
            }
    }

    var availableResetCount: Int {
        rateLimitResetCredits?.availableCount ?? 0
    }
}

struct AccountTokenUsageDailyBucket: Codable, Equatable, Identifiable {
    let startDate: String
    let tokens: Int64

    var id: String { startDate }

    var date: Date? {
        Self.dateFormatter.date(from: startDate)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct AccountTokenUsageSummary: Codable, Equatable {
    let currentStreakDays: Int64?
    let lifetimeTokens: Int64?
    let longestRunningTurnSec: Int64?
    let longestStreakDays: Int64?
    let peakDailyTokens: Int64?
}

struct AccountTokenUsage: Codable, Equatable {
    let summary: AccountTokenUsageSummary
    let dailyUsageBuckets: [AccountTokenUsageDailyBucket]?
}

struct UsageWindow: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case fiveHours
        case weekly
        case other
    }

    let id: String
    let kind: Kind
    let label: String
    let durationMinutes: Int
    let usedPercent: Double?
    let resetsAt: Date?

    var localizedLabel: String {
        switch kind {
        case .fiveHours: return L10n.string("window.fiveHours")
        case .weekly: return L10n.string("window.weekly")
        case .other: return L10n.string("window.other", durationMinutes)
        }
    }

    var remainingPercent: Double? {
        usedPercent.map { max(0, min(100, 100 - $0)) }
    }

    var isCritical: Bool {
        (usedPercent ?? 0) > 90
    }

    var alertKey: String {
        let resetKey = resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
        return "\(id):\(resetKey)"
    }
}

struct ResetCredit: Codable, Equatable, Identifiable {
    let id: String
    let status: String?
    let grantedAt: Date?
    let expiresAt: Date?
    let title: String
    let description: String?

    func isExpiringSoon(relativeTo date: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(date) <= 3 * 24 * 60 * 60
    }

    init(payload: ResetCreditPayload) {
        id = payload.id ?? UUID().uuidString
        status = payload.status
        grantedAt = payload.grantedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        expiresAt = payload.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        title = payload.title ?? L10n.string("reset.usage")
        description = payload.description
    }
}

struct UsageSnapshot: Codable, Equatable {
    let account: AccountInfo?
    let windows: [UsageWindow]
    let resets: [ResetCredit]
    let availableResetCount: Int
    let tokenUsage: AccountTokenUsage?
    let fetchedAt: Date
}

enum ConnectionState: Equatable {
    case starting
    case needsCodex
    case needsLogin
    case connecting
    case ready
    case stale
    case error(String)

    var label: String {
        switch self {
        case .starting: return L10n.string("state.starting")
        case .needsCodex: return L10n.string("state.needsCodex")
        case .needsLogin: return L10n.string("state.needsLogin")
        case .connecting: return L10n.string("state.connecting")
        case .ready: return L10n.string("state.ready")
        case .stale: return L10n.string("state.stale")
        case .error(let message): return message
        }
    }
}

struct GitHubAccount: Codable, Equatable {
    let login: String
    let name: String?
    let avatarURL: URL?
    let htmlURL: URL?

    enum CodingKeys: String, CodingKey {
        case login, name
        case avatarURL = "avatarUrl"
        case htmlURL = "htmlUrl"
    }

    var displayName: String {
        let cleanedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanedName?.isEmpty == false ? cleanedName! : "@\(login)"
    }
}

struct GitHubBillingUsageReport: Codable, Equatable {
    struct TimePeriod: Codable, Equatable {
        let year: Int?
        let month: Int?
        let day: Int?
    }

    struct Item: Codable, Equatable, Identifiable {
        let product: String?
        let sku: String?
        let model: String?
        let unitType: String?
        let grossQuantity: Double?
        let grossAmount: Double?
        let discountQuantity: Double?
        let discountAmount: Double?
        let netQuantity: Double?
        let netAmount: Double?

        var id: String {
            [product, sku, model, unitType].compactMap { $0 }.joined(separator: ":")
        }

        var usageQuantity: Double {
            max(0, grossQuantity ?? netQuantity ?? 0)
        }
    }

    let timePeriod: TimePeriod?
    let user: String?
    let usageItems: [Item]

    var totalQuantity: Double {
        usageItems.reduce(0) { $0 + $1.usageQuantity }
    }

    var totalAmount: Double {
        usageItems.reduce(0) { $0 + max(0, $1.netAmount ?? $1.grossAmount ?? 0) }
    }

    var totalGrossAmount: Double {
        usageItems.reduce(0) { $0 + max(0, $1.grossAmount ?? $1.netAmount ?? 0) }
    }
}

struct CopilotModelUsage: Equatable, Identifiable {
    let model: String
    let quantity: Double
    let unitType: String?

    var id: String { model }
}

struct CopilotUsageSnapshot: Codable, Equatable {
    let account: GitHubAccount
    let premiumRequests: GitHubBillingUsageReport?
    let aiCredits: GitHubBillingUsageReport?
    let fetchedAt: Date

    var totalNetAmount: Double {
        [premiumRequests, aiCredits].compactMap { $0 }.reduce(0) { $0 + $1.totalAmount }
    }

    var totalGrossAmount: Double {
        [premiumRequests, aiCredits].compactMap { $0 }.reduce(0) { $0 + $1.totalGrossAmount }
    }

    var modelUsage: [CopilotModelUsage] {
        guard let report = [premiumRequests, aiCredits]
            .compactMap({ $0 })
            .first(where: { !$0.usageItems.isEmpty }) else { return [] }
        var totals: [String: Double] = [:]
        for item in report.usageItems {
            let model = item.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let model, !model.isEmpty, item.usageQuantity > 0 else { continue }
            totals[model, default: 0] += item.usageQuantity
        }
        let unitType = report.usageItems.compactMap(\.unitType).first
        return totals
            .map { CopilotModelUsage(model: $0.key, quantity: $0.value, unitType: unitType) }
            .sorted { lhs, rhs in
                lhs.quantity == rhs.quantity ? lhs.model < rhs.model : lhs.quantity > rhs.quantity
            }
    }
}

struct GitHubDeviceAuthorization: Codable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let expiresAt: Date
    let pollingInterval: TimeInterval
}

struct GitHubCredentials: Codable, Equatable {
    let accessToken: String
    let tokenType: String?
    let scope: String?
    let expiresAt: Date?
    let refreshToken: String?
    let refreshTokenExpiresAt: Date?

    var needsRefresh: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }
}
