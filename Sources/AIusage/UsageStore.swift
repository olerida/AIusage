import AppKit
import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var state: ConnectionState = .starting
    @Published private(set) var selectedAgent = AppSettings.selectedAgent
    @Published private(set) var account: AccountInfo?
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var copilotSnapshot: CopilotUsageSnapshot?
    @Published private(set) var copilotDeviceAuthorization: GitHubDeviceAuthorization?
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isAuthenticatingCopilot = false
    @Published private(set) var hasCopilotCredentials = false
    @Published private(set) var notificationsEnabled = AppSettings.notificationsEnabled
    @Published private(set) var fiveHourNotificationThreshold = AppSettings.fiveHourNotificationThreshold
    @Published private(set) var weeklyNotificationThreshold = AppSettings.weeklyNotificationThreshold
    @Published private(set) var resetExpirationNotificationsEnabled = AppSettings.resetExpirationNotificationsEnabled
    @Published private(set) var resetExpirationLeadDays = AppSettings.resetExpirationLeadDays
    @Published private(set) var showFiveHourPercentageInMenuBar = AppSettings.showFiveHourPercentageInMenuBar
    @Published private(set) var showWeeklyPercentageInMenuBar = AppSettings.showWeeklyPercentageInMenuBar
    @Published private(set) var showCopilotCreditsInMenuBar = AppSettings.showCopilotCreditsInMenuBar
    @Published private(set) var showCopilotUsagePercentageInMenuBar = AppSettings.showCopilotUsagePercentageInMenuBar

    private var client: CodexAppServerClient?
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private var pendingAlertKeys: Set<String> = []
    private var githubCredentialCache = GitHubCredentialMemoryCache()
    private let notificationService: any NotificationDelivering
    private let codexSessionScanner = CodexSessionUsageScanner(
        homeDirectory: AppSettings.localCodexHomeDirectory
    )

    init() {
        notificationService = NotificationService()
        loadCachedSnapshots()
        loadGitHubCredentialStatus()
    }

    init(notificationService: any NotificationDelivering) {
        self.notificationService = notificationService
        loadCachedSnapshots()
        loadGitHubCredentialStatus()
    }

    init(
        previewAgent: AgentKind,
        state: ConnectionState,
        account: AccountInfo? = nil,
        snapshot: UsageSnapshot? = nil,
        copilotSnapshot: CopilotUsageSnapshot? = nil
    ) {
        notificationService = NotificationService()
        selectedAgent = previewAgent
        self.state = state
        self.account = account
        self.snapshot = snapshot
        self.copilotSnapshot = copilotSnapshot
        hasCopilotCredentials = copilotSnapshot != nil
    }

    deinit {
        refreshTask?.cancel()
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    func selectAgent(_ agent: AgentKind) {
        guard selectedAgent != agent else { return }
        selectedAgent = agent
        AppSettings.selectedAgent = agent
        lastError = nil
        copilotDeviceAuthorization = nil
        state = cachedSnapshotExists(for: agent) ? .stale : .starting
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else {
            refreshRequested = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        repeat {
            refreshRequested = false
            let refreshingAgent = selectedAgent
            switch refreshingAgent {
            case .codex: await refreshCodex()
            case .githubCopilot:
                await refreshCopilot()
                await refreshCodexAlerts()
            }
            if refreshingAgent != selectedAgent { refreshRequested = true }
        } while refreshRequested
    }

    func login(_ agent: AgentKind) async {
        switch agent {
        case .codex: await loginCodex()
        case .githubCopilot: await loginCopilot()
        }
    }

    func logout(_ agent: AgentKind) async {
        switch agent {
        case .codex: await logoutCodex()
        case .githubCopilot: logoutCopilot()
        }
    }

    func setCodexPath(_ path: String) async {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.codexPath = value.isEmpty ? nil : value
        client?.stop()
        client = nil
        if selectedAgent == .codex { await refresh() }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        AppSettings.notificationsEnabled = enabled
        notificationsEnabled = enabled
        guard enabled else { return }
        Task { @MainActor [weak self, notificationService] in
            guard await notificationService.requestAuthorization() else { return }
            await self?.refreshCodexAlerts()
        }
    }

    func setFiveHourNotificationThreshold(_ threshold: Int) {
        AppSettings.fiveHourNotificationThreshold = threshold
        fiveHourNotificationThreshold = AppSettings.fiveHourNotificationThreshold
        scheduleCodexAlertRefresh()
    }

    func setWeeklyNotificationThreshold(_ threshold: Int) {
        AppSettings.weeklyNotificationThreshold = threshold
        weeklyNotificationThreshold = AppSettings.weeklyNotificationThreshold
        scheduleCodexAlertRefresh()
    }

    func setResetExpirationNotificationsEnabled(_ enabled: Bool) {
        AppSettings.resetExpirationNotificationsEnabled = enabled
        resetExpirationNotificationsEnabled = enabled
        if enabled { scheduleCodexAlertRefresh() }
    }

    func setResetExpirationLeadDays(_ days: Int) {
        AppSettings.resetExpirationLeadDays = days
        resetExpirationLeadDays = AppSettings.resetExpirationLeadDays
        scheduleCodexAlertRefresh()
    }

    func setShowFiveHourPercentageInMenuBar(_ enabled: Bool) {
        AppSettings.showFiveHourPercentageInMenuBar = enabled
        showFiveHourPercentageInMenuBar = enabled
    }

    func setShowWeeklyPercentageInMenuBar(_ enabled: Bool) {
        AppSettings.showWeeklyPercentageInMenuBar = enabled
        showWeeklyPercentageInMenuBar = enabled
    }

    func setShowCopilotCreditsInMenuBar(_ enabled: Bool) {
        AppSettings.showCopilotCreditsInMenuBar = enabled
        showCopilotCreditsInMenuBar = enabled
    }

    func setShowCopilotUsagePercentageInMenuBar(_ enabled: Bool) {
        AppSettings.showCopilotUsagePercentageInMenuBar = enabled
        showCopilotUsagePercentageInMenuBar = enabled
    }

    func openUsage() {
        _ = WorkspaceActions.openUsage(for: selectedAgent)
    }

    var agentTitle: String { selectedAgent.displayName }

    var accountSubtitle: String? {
        switch selectedAgent {
        case .codex:
            guard let account else { return nil }
            return [account.email, account.planType?.uppercased()].compactMap { $0 }.joined(separator: " · ")
        case .githubCopilot:
            guard let account = copilotSnapshot?.account else { return nil }
            let name = account.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty { return "\(name) · @\(account.login)" }
            return "@\(account.login)"
        }
    }

    var statusText: String {
        switch selectedAgent {
        case .codex:
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
        case .githubCopilot:
            var parts: [String] = []
            if showCopilotCreditsInMenuBar {
                if let used = copilotSnapshot?.entitlement?.premiumQuota?.used {
                    parts.append(L10n.string("status.aiCredits", Self.compactNumber(used)))
                } else if let report = copilotSnapshot?.aiCredits, !report.usageItems.isEmpty {
                    parts.append(L10n.string("status.aiCredits", Self.compactNumber(report.totalQuantity)))
                } else if let report = copilotSnapshot?.premiumRequests, !report.usageItems.isEmpty {
                    parts.append(L10n.string("status.premiumRequests", Self.compactNumber(report.totalQuantity)))
                }
            }
            if showCopilotUsagePercentageInMenuBar,
               let usedPercent = copilotSnapshot?.entitlement?.premiumQuota?.usedPercent {
                parts.append(L10n.string("status.usagePercentage", Int(usedPercent.rounded())))
            }
            return parts.joined(separator: " · ")
        }
    }

    var statusTooltip: String {
        var lines = [agentTitle, state.label]
        if let fetchedAt = selectedFetchedAt {
            lines.append(L10n.string("status.updated", fetchedAt.formatted(date: .abbreviated, time: .shortened)))
        }
        return lines.joined(separator: "\n")
    }

    var isStale: Bool {
        guard let fetchedAt = selectedFetchedAt else { return false }
        return Date().timeIntervalSince(fetchedAt) > 300
    }

    private var selectedFetchedAt: Date? {
        switch selectedAgent {
        case .codex: return snapshot?.fetchedAt
        case .githubCopilot: return copilotSnapshot?.fetchedAt
        }
    }

    private func refreshCodex(updatesVisibleState: Bool = true) async {
        do {
            try await ensureClient(updatesVisibleState: updatesVisibleState)
            guard let client else { throw AppServerError.notRunning }
            if updatesVisibleState { state = .connecting }

            let accountResponse = try await client.readAccount()
            guard let account = accountResponse.account else {
                self.account = nil
                if updatesVisibleState { state = .needsLogin }
                lastError = nil
                return
            }

            async let modelUsageResult = codexSessionScanner.scan()
            let limits = try await client.readRateLimits()
            let tokenUsage = (try? await client.readTokenUsage()) ?? snapshot?.tokenUsage
            let modelUsage = await modelUsageResult
            let newSnapshot = UsageSnapshot(
                account: account,
                windows: limits.normalizedWindows(),
                resets: limits.normalizedResets(),
                availableResetCount: limits.availableResetCount,
                tokenUsage: tokenUsage,
                modelUsage: modelUsage.isEmpty ? nil : modelUsage,
                fetchedAt: Date()
            )
            self.account = account
            snapshot = newSnapshot
            if updatesVisibleState { state = .ready }
            lastError = nil
            persist(newSnapshot, to: AppSettings.snapshotURL)
            await evaluateAlerts(
                for: newSnapshot.windows,
                resets: newSnapshot.resets,
                now: newSnapshot.fetchedAt
            )
        } catch AppServerError.executableNotFound {
            if updatesVisibleState { state = .needsCodex }
            lastError = AppServerError.executableNotFound.localizedDescription
        } catch {
            lastError = error.localizedDescription
            if updatesVisibleState {
                state = snapshot == nil ? .error(error.localizedDescription) : .stale
            }
        }
    }

    private func refreshCopilot(updatesVisibleState: Bool = true) async {
        do {
            guard let credentials = try githubCredentialCache.load() else {
                hasCopilotCredentials = false
                if updatesVisibleState { state = .needsLogin }
                lastError = nil
                return
            }
            hasCopilotCredentials = true
            if updatesVisibleState { state = .connecting }
            let githubClient = try makeGitHubClient()
            let (newSnapshot, activeCredentials) = try await githubClient.fetchSnapshot(credentials: credentials)
            if activeCredentials != credentials {
                githubCredentialCache.store(activeCredentials)
                do {
                    try GitHubTokenStore.save(activeCredentials)
                } catch {
                    NSLog("AI Usage MB could not persist refreshed GitHub credentials: %@", error.localizedDescription)
                }
            }
            copilotSnapshot = newSnapshot
            if updatesVisibleState { state = .ready }
            lastError = nil
            persist(newSnapshot, to: AppSettings.copilotSnapshotURL)
        } catch GitHubCopilotError.unauthorized {
            try? GitHubTokenStore.delete()
            githubCredentialCache.clear()
            hasCopilotCredentials = false
            copilotSnapshot = nil
            try? FileManager.default.removeItem(at: AppSettings.copilotSnapshotURL)
            if updatesVisibleState { state = .needsLogin }
            lastError = GitHubCopilotError.unauthorized.localizedDescription
        } catch {
            lastError = error.localizedDescription
            if updatesVisibleState {
                state = copilotSnapshot == nil ? .error(error.localizedDescription) : .stale
            }
        }
    }

    private func loginCodex() async {
        let updatesVisibleState = selectedAgent == .codex
        do {
            try await ensureClient(updatesVisibleState: updatesVisibleState)
            guard let client else { throw AppServerError.notRunning }
            if updatesVisibleState { state = .connecting }
            try await client.login()
            await refreshCodex(updatesVisibleState: updatesVisibleState)
        } catch {
            lastError = error.localizedDescription
            if updatesVisibleState { state = .error(error.localizedDescription) }
        }
    }

    private func loginCopilot() async {
        guard !isAuthenticatingCopilot else { return }
        let updatesVisibleState = selectedAgent == .githubCopilot
        isAuthenticatingCopilot = true
        if updatesVisibleState { state = .connecting }
        lastError = nil
        defer {
            isAuthenticatingCopilot = false
            copilotDeviceAuthorization = nil
        }

        do {
            let githubClient = try makeGitHubClient()
            let authorization = try await githubClient.requestDeviceAuthorization()
            copilotDeviceAuthorization = authorization
            guard NSWorkspace.shared.open(authorization.verificationURI) else {
                throw GitHubCopilotError.remote(L10n.string("error.browserOpen"))
            }
            let credentials = try await githubClient.pollForCredentials(using: authorization)
            try GitHubTokenStore.save(credentials, allowAuthenticationUI: true)
            githubCredentialCache.store(credentials)
            hasCopilotCredentials = true
            await refreshCopilot(updatesVisibleState: updatesVisibleState)
        } catch {
            lastError = error.localizedDescription
            if updatesVisibleState { state = .error(error.localizedDescription) }
        }
    }

    private func logoutCodex() async {
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
        if selectedAgent == .codex { state = .needsLogin }
    }

    private func logoutCopilot() {
        do {
            try GitHubTokenStore.delete(allowAuthenticationUI: true)
            githubCredentialCache.clear()
            hasCopilotCredentials = false
            copilotSnapshot = nil
            try? FileManager.default.removeItem(at: AppSettings.copilotSnapshotURL)
            if selectedAgent == .githubCopilot { state = .needsLogin }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            if selectedAgent == .githubCopilot { state = .error(error.localizedDescription) }
        }
    }

    private func ensureClient(updatesVisibleState: Bool = true) async throws {
        if let client, client.isRunning { return }
        guard let executable = CodexExecutableResolver.resolve(customPath: AppSettings.codexPath) else {
            throw AppServerError.executableNotFound
        }

        if updatesVisibleState, selectedAgent == .codex { state = .connecting }
        let client = CodexAppServerClient(executableURL: executable)
        client.onRateLimitNotification = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.selectedAgent == .codex {
                    await self.refresh()
                } else {
                    await self.refreshCodexAlerts()
                }
            }
        }
        try await client.start()
        self.client = client
    }

    private func makeGitHubClient() throws -> GitHubCopilotClient {
        guard let clientID = AppSettings.gitHubClientID else { throw GitHubCopilotError.missingClientID }
        return GitHubCopilotClient(clientID: clientID)
    }

    private func scheduleCodexAlertRefresh() {
        guard AppSettings.notificationsEnabled else { return }
        Task { @MainActor [weak self] in
            await self?.refreshCodexAlerts()
        }
    }

    private func refreshCodexAlerts() async {
        guard AppSettings.notificationsEnabled else { return }
        do {
            try await ensureClient(updatesVisibleState: false)
            guard let client else { return }
            let accountResponse = try await client.readAccount()
            guard accountResponse.account != nil else { return }
            let limits = try await client.readRateLimits()
            let now = Date()
            await evaluateAlerts(
                for: limits.normalizedWindows(),
                resets: limits.normalizedResets(relativeTo: now),
                now: now
            )
        } catch {
            // Background alert checks must not replace the visible agent's state.
        }
    }

    func evaluateAlerts(
        for windows: [UsageWindow],
        resets: [ResetCredit],
        now: Date = Date()
    ) async {
        guard AppSettings.notificationsEnabled else { return }

        for window in windows {
            let threshold = notificationThreshold(for: window.kind)
            guard window.exceedsNotificationThreshold(threshold),
                  window.resetsAt.map({ $0 > now }) ?? true else { continue }
            await deliverAlertIfNeeded(key: window.alertKey) { [notificationService] in
                await notificationService.sendUsageAlert(for: window)
            }
        }

        guard AppSettings.resetExpirationNotificationsEnabled else { return }
        let leadDays = AppSettings.resetExpirationLeadDays
        for reset in resets where reset.expires(withinDays: leadDays, relativeTo: now) {
            await deliverAlertIfNeeded(key: reset.expirationAlertKey) { [notificationService] in
                await notificationService.sendResetExpirationAlert(for: reset, now: now)
            }
        }
    }

    private func notificationThreshold(for kind: UsageWindow.Kind) -> Int {
        switch kind {
        case .fiveHours: return AppSettings.fiveHourNotificationThreshold
        case .weekly: return AppSettings.weeklyNotificationThreshold
        case .other: return 90
        }
    }

    private func deliverAlertIfNeeded(
        key: String,
        delivery: () async -> Bool
    ) async {
        guard !AppSettings.alertedKeys.contains(key),
              pendingAlertKeys.insert(key).inserted else { return }
        defer { pendingAlertKeys.remove(key) }
        let delivered = await delivery()
        guard delivered, AppSettings.notificationsEnabled else { return }
        var alertedKeys = AppSettings.alertedKeys
        alertedKeys.insert(key)
        AppSettings.alertedKeys = alertedKeys
    }

    private func persist<T: Encodable>(_ snapshot: T, to url: URL) {
        if let data = try? JSONEncoder.github.encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadCachedSnapshots() {
        snapshot = load(UsageSnapshot.self, from: AppSettings.snapshotURL)
        account = snapshot?.account
        copilotSnapshot = load(CopilotUsageSnapshot.self, from: AppSettings.copilotSnapshotURL)
        if cachedSnapshotExists(for: selectedAgent) { state = .stale }
    }

    private func loadGitHubCredentialStatus() {
        do {
            hasCopilotCredentials = try githubCredentialCache.load() != nil
        } catch {
            hasCopilotCredentials = false
        }
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.github.decode(type, from: data)
    }

    private func cachedSnapshotExists(for agent: AgentKind) -> Bool {
        switch agent {
        case .codex: return snapshot != nil
        case .githubCopilot: return copilotSnapshot != nil
        }
    }

    private static func compactNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value.rounded() == value ? 0 : 1)))
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
