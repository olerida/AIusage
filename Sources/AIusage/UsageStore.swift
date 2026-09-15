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
    @Published private(set) var showFiveHourPercentageInMenuBar = AppSettings.showFiveHourPercentageInMenuBar
    @Published private(set) var showWeeklyPercentageInMenuBar = AppSettings.showWeeklyPercentageInMenuBar

    private var client: CodexAppServerClient?
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private let notificationService = NotificationService()
    private let codexSessionScanner = CodexSessionUsageScanner(
        homeDirectory: AppSettings.localCodexHomeDirectory
    )

    init() {
        loadCachedSnapshots()
    }

    init(
        previewAgent: AgentKind,
        state: ConnectionState,
        account: AccountInfo? = nil,
        snapshot: UsageSnapshot? = nil,
        copilotSnapshot: CopilotUsageSnapshot? = nil
    ) {
        selectedAgent = previewAgent
        self.state = state
        self.account = account
        self.snapshot = snapshot
        self.copilotSnapshot = copilotSnapshot
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
            case .githubCopilot: await refreshCopilot()
            }
            if refreshingAgent != selectedAgent { refreshRequested = true }
        } while refreshRequested
    }

    func login() async {
        switch selectedAgent {
        case .codex: await loginCodex()
        case .githubCopilot: await loginCopilot()
        }
    }

    func logout() async {
        switch selectedAgent {
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
            if let report = copilotSnapshot?.premiumRequests, !report.usageItems.isEmpty {
                return L10n.string("status.premiumRequests", Self.compactNumber(report.totalQuantity))
            }
            if let report = copilotSnapshot?.aiCredits, !report.usageItems.isEmpty {
                return L10n.string("status.aiCredits", Self.compactNumber(report.totalQuantity))
            }
            return ""
        }
    }

    var hasCriticalWindow: Bool {
        selectedAgent == .codex && snapshot?.windows.contains(where: { $0.isCritical }) == true
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

    private func refreshCodex() async {
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
            state = .ready
            lastError = nil
            persist(newSnapshot, to: AppSettings.snapshotURL)
            evaluateAlerts(for: newSnapshot.windows)
        } catch AppServerError.executableNotFound {
            state = .needsCodex
            lastError = AppServerError.executableNotFound.localizedDescription
        } catch {
            lastError = error.localizedDescription
            state = snapshot == nil ? .error(error.localizedDescription) : .stale
        }
    }

    private func refreshCopilot() async {
        do {
            guard let credentials = try GitHubTokenStore.load() else {
                state = .needsLogin
                lastError = nil
                return
            }
            state = .connecting
            let githubClient = try makeGitHubClient()
            let (newSnapshot, activeCredentials) = try await githubClient.fetchSnapshot(credentials: credentials)
            if activeCredentials != credentials { try GitHubTokenStore.save(activeCredentials) }
            copilotSnapshot = newSnapshot
            state = .ready
            lastError = nil
            persist(newSnapshot, to: AppSettings.copilotSnapshotURL)
        } catch GitHubCopilotError.unauthorized {
            try? GitHubTokenStore.delete()
            state = .needsLogin
            lastError = GitHubCopilotError.unauthorized.localizedDescription
        } catch {
            lastError = error.localizedDescription
            state = copilotSnapshot == nil ? .error(error.localizedDescription) : .stale
        }
    }

    private func loginCodex() async {
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

    private func loginCopilot() async {
        guard !isAuthenticatingCopilot else { return }
        isAuthenticatingCopilot = true
        state = .connecting
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
            try GitHubTokenStore.save(credentials)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            state = .error(error.localizedDescription)
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
        state = .needsLogin
    }

    private func logoutCopilot() {
        do {
            try GitHubTokenStore.delete()
            copilotSnapshot = nil
            try? FileManager.default.removeItem(at: AppSettings.copilotSnapshotURL)
            state = .needsLogin
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            state = .error(error.localizedDescription)
        }
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
                guard self?.selectedAgent == .codex else { return }
                await self?.refresh()
            }
        }
        try await client.start()
        self.client = client
    }

    private func makeGitHubClient() throws -> GitHubCopilotClient {
        guard let clientID = AppSettings.gitHubClientID else { throw GitHubCopilotError.missingClientID }
        return GitHubCopilotClient(clientID: clientID)
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
