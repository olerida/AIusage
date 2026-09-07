import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var state: ConnectionState = .starting
    @Published private(set) var account: AccountInfo?
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var showFiveHourPercentageInMenuBar = AppSettings.showFiveHourPercentageInMenuBar
    @Published private(set) var showWeeklyPercentageInMenuBar = AppSettings.showWeeklyPercentageInMenuBar

    private var client: CodexAppServerClient?
    private var refreshTask: Task<Void, Never>?
    private let notificationService = NotificationService()

    init() {
        loadCachedSnapshot()
    }

    deinit {
        refreshTask?.cancel()
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            try await ensureClient()
            guard let client else { throw AppServerError.notRunning }
            state = .connecting

            let accountResponse = try await client.readAccount()
            guard let account = accountResponse.account else {
                self.account = nil
                state = .needsLogin
                lastError = nil
                return
            }

            let limits = try await client.readRateLimits()
            let tokenUsage = (try? await client.readTokenUsage()) ?? snapshot?.tokenUsage
            let newSnapshot = UsageSnapshot(
                account: account,
                windows: limits.normalizedWindows(),
                resets: limits.normalizedResets(),
                availableResetCount: limits.availableResetCount,
                tokenUsage: tokenUsage,
                fetchedAt: Date()
            )
            self.account = account
            snapshot = newSnapshot
            state = .ready
            lastError = nil
            persist(snapshot: newSnapshot)
            evaluateAlerts(for: newSnapshot.windows)
        } catch AppServerError.executableNotFound {
            state = .needsCodex
            lastError = AppServerError.executableNotFound.localizedDescription
        } catch {
            lastError = error.localizedDescription
            state = snapshot == nil ? .error(error.localizedDescription) : .stale
        }
    }

    func login() async {
        do {
            try await ensureClient()
            guard let client else { throw AppServerError.notRunning }
            state = .connecting
            try await client.login()
            await refresh()
        } catch {
            lastError = error.localizedDescription
            state = .error(error.localizedDescription)
        }
    }

    func logout() async {
        do {
            try await client?.logout()
        } catch {
            lastError = error.localizedDescription
        }
        client?.stop()
        client = nil
        account = nil
        snapshot = nil
        try? FileManager.default.removeItem(at: AppSettings.snapshotURL)
        state = .needsLogin
    }

    func setCodexPath(_ path: String) async {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.codexPath = value.isEmpty ? nil : value
        client?.stop()
        client = nil
        await refresh()
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        AppSettings.notificationsEnabled = enabled
    }

    func setShowFiveHourPercentageInMenuBar(_ enabled: Bool) {
        AppSettings.showFiveHourPercentageInMenuBar = enabled
        showFiveHourPercentageInMenuBar = enabled
    }

    func setShowWeeklyPercentageInMenuBar(_ enabled: Bool) {
        AppSettings.showWeeklyPercentageInMenuBar = enabled
        showWeeklyPercentageInMenuBar = enabled
    }

    func openUsage() {
        _ = WorkspaceActions.openUsage()
    }

    var statusText: String {
        guard showFiveHourPercentageInMenuBar || showWeeklyPercentageInMenuBar else { return "" }

        var parts: [String] = []
        if showFiveHourPercentageInMenuBar {
            let five = snapshot?.windows.first(where: { $0.kind == .fiveHours })
            let text = five?.usedPercent.map { "\(Int($0.rounded()))%" } ?? "—"
            parts.append("5h \(text)")
        }
        if showWeeklyPercentageInMenuBar {
            let weekly = snapshot?.windows.first(where: { $0.kind == .weekly })
            let text = weekly?.usedPercent.map { "\(Int($0.rounded()))%" } ?? "—"
            parts.append("7d \(text)")
        }
        return parts.joined(separator: " · ")
    }

    var hasCriticalWindow: Bool {
        snapshot?.windows.contains(where: { $0.isCritical }) == true
    }

    var statusTooltip: String {
        var lines = [L10n.string("app.name"), state.label]
        if let fetchedAt = snapshot?.fetchedAt {
            lines.append(L10n.string("status.updated", fetchedAt.formatted(date: .abbreviated, time: .shortened)))
        }
        return lines.joined(separator: "\n")
    }

    var isStale: Bool {
        guard let fetchedAt = snapshot?.fetchedAt else { return false }
        return Date().timeIntervalSince(fetchedAt) > 300
    }

    private func ensureClient() async throws {
        if let client, client.isRunning { return }
        guard let executable = CodexExecutableResolver.resolve(customPath: AppSettings.codexPath) else {
            throw AppServerError.executableNotFound
        }

        state = .connecting
        let client = CodexAppServerClient(executableURL: executable)
        client.onRateLimitNotification = { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
        try await client.start()
        self.client = client
    }

    private func evaluateAlerts(for windows: [UsageWindow]) {
        var alertedKeys = AppSettings.alertedKeys
        for window in windows where window.isCritical {
            guard !alertedKeys.contains(window.alertKey) else { continue }
            alertedKeys.insert(window.alertKey)
            Task { @MainActor [notificationService] in
                await notificationService.sendCriticalAlert(for: window)
            }
        }
        AppSettings.alertedKeys = alertedKeys
    }

    private func persist(snapshot: UsageSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: AppSettings.snapshotURL, options: .atomic)
        }
    }

    private func loadCachedSnapshot() {
        guard let data = try? Data(contentsOf: AppSettings.snapshotURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cached = try? decoder.decode(UsageSnapshot.self, from: data) else { return }
        snapshot = cached
        account = cached.account
        state = .stale
    }
}

extension UsageWindow {
    func resetSummary(now: Date) -> String {
        guard let resetsAt else { return L10n.string("reset.summary.unknown") }
        let seconds = max(0, Int(resetsAt.timeIntervalSince(now)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return L10n.string("reset.summary.days", days, hours) }
        if hours > 0 { return L10n.string("reset.summary.hours", hours, minutes) }
        return L10n.string("reset.summary.minutes", minutes)
    }
}
