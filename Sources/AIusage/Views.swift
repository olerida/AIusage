import AppKit
import SwiftUI

private struct PopoverContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ToolbarIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore
    let onSettings: () -> Void
    let onAbout: () -> Void
    let onClose: () -> Void
    let onContentHeightChange: (CGFloat) -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()

                if store.state == .needsCodex {
                    EmptyStateView(
                        title: L10n.string("popover.codexNotFound.title"),
                        message: L10n.string("popover.codexNotFound.message"),
                        buttonTitle: L10n.string("action.settings"),
                        action: onSettings
                    )
                } else if store.state == .needsLogin {
                    EmptyStateView(
                        title: L10n.string("popover.login.title"),
                        message: L10n.string("popover.login.message"),
                        buttonTitle: L10n.string("action.login"),
                        action: { Task { await store.login() } }
                    )
                } else if let snapshot = store.snapshot {
                    if store.isStale {
                        Label(L10n.string("popover.stale", snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened)), systemImage: "clock.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    ForEach(snapshot.windows) { window in
                        UsageWindowCard(window: window)
                    }
                    ResetCreditsSection(snapshot: snapshot)
                    if let tokenUsage = snapshot.tokenUsage {
                        TokenUsageSection(usage: tokenUsage)
                    }
                } else {
                    ProgressView(L10n.string("popover.connecting"))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                }

                footer
            }
            .padding(16)
            .frame(width: 580)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PopoverContentHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
        }
        .frame(width: 580)
        .onPreferenceChange(PopoverContentHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            onContentHeightChange(height)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("app.name"))
                    .font(.headline)
                if let account = store.account {
                    Text([account.email, account.planType?.uppercased()].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(store.state.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            ToolbarIconButton(
                systemImage: "info.circle",
                label: L10n.string("action.about"),
                action: onAbout
            )
            ToolbarIconButton(
                systemImage: "gearshape",
                label: L10n.string("action.settings"),
                action: onSettings
            )
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: store.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.string("action.refresh"))
        }
    }

    private var footer: some View {
        HStack {
            Button(L10n.string("action.openUsage")) { store.openUsage() }
            Spacer()
            Button(L10n.string("action.close")) { onClose() }
        }
        .font(.caption)
    }
}

struct UsageWindowCard: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(window.localizedLabel)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let used = window.usedPercent {
                    Text(L10n.string("window.used", Int(used.rounded())))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(window.isCritical ? .red : .primary)
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: (window.usedPercent ?? 0) / 100)
                .tint(window.isCritical ? .red : .accentColor)

            HStack {
                if let remaining = window.remainingPercent {
                    Text(L10n.string("window.remaining", Int(remaining.rounded())))
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(window.resetSummary(now: context.date))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let resetsAt = window.resetsAt {
                Text(L10n.string("window.reset", resetsAt.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ResetCreditsSection: View {
    let snapshot: UsageSnapshot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let resets = snapshot.resets.filter { reset in
                reset.expiresAt.map { $0 > context.date } ?? true
            }
            let visibleCount = snapshot.resets.isEmpty ? snapshot.availableResetCount : resets.count

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(L10n.string("reset.available"))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(visibleCount)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.65), in: Capsule())
                }

                if resets.isEmpty {
                    Text(snapshot.resets.isEmpty && snapshot.availableResetCount > 0
                         ? L10n.string("reset.detailsMissing")
                         : L10n.string("reset.none"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(resets.enumerated()), id: \.element.id) { index, reset in
                            ResetCreditRow(reset: reset, now: context.date)
                            if index < resets.count - 1 {
                                Divider()
                                    .padding(.leading, 13)
                            }
                        }
                    }
                    .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    }
                }
            }
        }
    }
}

private struct ResetCreditRow: View {
    let reset: ResetCredit
    let now: Date

    private var expiringSoon: Bool {
        reset.isExpiringSoon(relativeTo: now)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(expiringSoon ? Color.orange : Color.accentColor.opacity(0.55))
                .frame(width: 3, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(reset.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                if let description = reset.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !description.isEmpty {
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let expiresAt = reset.expiresAt {
                    Label(
                        L10n.string("reset.expires", expiresAt.formatted(date: .abbreviated, time: .shortened)),
                        systemImage: "calendar"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else {
                    Text(L10n.string("reset.noExpiry"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            if let expiresAt = reset.expiresAt {
                VStack(alignment: .trailing, spacing: 3) {
                    if expiringSoon {
                        Label(L10n.string("reset.expiringSoon"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text(expirySummary(for: expiresAt))
                        .foregroundStyle(expiringSoon ? .orange : .secondary)
                        .monospacedDigit()
                }
                .font(.caption2.weight(expiringSoon ? .semibold : .regular))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(expiringSoon ? Color.orange.opacity(0.10) : .clear)
        .accessibilityElement(children: .combine)
    }

    private func expirySummary(for expiresAt: Date) -> String {
        let totalMinutes = max(0, Int(expiresAt.timeIntervalSince(now) / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 { return L10n.string("reset.summary.days", days, hours) }
        if hours > 0 { return L10n.string("reset.summary.hours", hours, minutes) }
        return L10n.string("reset.summary.minutes", minutes)
    }
}

enum TokenUsageMapMode: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case cumulative

    var id: Self { self }

    var title: String {
        switch self {
        case .daily: return L10n.string("usage.daily")
        case .weekly: return L10n.string("usage.weekly")
        case .cumulative: return L10n.string("usage.cumulative")
        }
    }
}

struct TokenUsageSection: View {
    let usage: AccountTokenUsage
    @State private var mode: TokenUsageMapMode = .daily

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.string("usage.tokens"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                HStack(spacing: 3) {
                    ForEach(TokenUsageMapMode.allCases) { option in
                        Button {
                            mode = option
                        } label: {
                            Text(option.title)
                                .font(.caption.weight(mode == option ? .semibold : .regular))
                                .foregroundStyle(mode == option ? .primary : .secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                    }
                }
            }

            if let buckets = usage.dailyUsageBuckets, !buckets.isEmpty {
                TokenUsageHeatmap(buckets: buckets, mode: mode)
            } else {
                Text(L10n.string("usage.noData"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }
}

private struct TokenUsageMonthMarker: Identifiable {
    let column: Int
    let label: String

    var id: Int { column }
}

struct TokenUsageHeatmap: View {
    let mode: TokenUsageMapMode

    private struct CellData {
        let date: Date
        let amount: Int64
        let isFuture: Bool
        let isStacked: Bool
    }

    private static let rowCount = 7
    private static let columnCount = 53
    private static let cellSize: CGFloat = 8.5
    private static let cellGap: CGFloat = 1.75

    private let cells: [CellData]
    private let maxTokens: Int64
    private let monthMarkers: [TokenUsageMonthMarker]

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let monthKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    init(buckets: [AccountTokenUsageDailyBucket], mode: TokenUsageMapMode) {
        self.mode = mode

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let weekIndex = (weekday - calendar.firstWeekday + 7) % 7
        let gridEnd = calendar.date(byAdding: .day, value: 6 - weekIndex, to: today) ?? today
        let gridStart = calendar.date(byAdding: .day, value: -(Self.columnCount * Self.rowCount - 1), to: gridEnd) ?? gridEnd
        let dates = (0..<(Self.columnCount * Self.rowCount)).map { index in
            calendar.date(byAdding: .day, value: index, to: gridStart) ?? gridStart
        }

        var tokenMap: [String: Int64] = [:]
        for bucket in buckets {
            guard let date = bucket.date else { continue }
            tokenMap[Self.dayKey(date), default: 0] += max(0, bucket.tokens)
        }

        let weeklyValues = (0..<Self.columnCount).map { column in
            (0..<Self.rowCount).reduce(into: Int64(0)) { result, row in
                result += tokenMap[Self.dayKey(dates[column * Self.rowCount + row])] ?? 0
            }
        }
        var cumulativeWeeklyValues: [Int64] = []
        var cumulativeTotal: Int64 = 0
        for value in weeklyValues {
            cumulativeTotal += value
            cumulativeWeeklyValues.append(cumulativeTotal)
        }

        let values = dates.indices.map { index in
            switch mode {
            case .daily:
                return tokenMap[Self.dayKey(dates[index])] ?? 0
            case .weekly:
                return weeklyValues[index / Self.rowCount]
            case .cumulative:
                return cumulativeWeeklyValues[index / Self.rowCount]
            }
        }
        self.maxTokens = max(1, values.max() ?? 0)
        self.cells = zip(dates, values).map { date, amount in
            CellData(date: date, amount: amount, isFuture: date > today, isStacked: mode != .daily)
        }

        var seen = Set<String>()
        self.monthMarkers = (0..<Self.columnCount).compactMap { column in
            let date = dates[column * Self.rowCount]
            let key = Self.monthKey(date)
            guard seen.insert(key).inserted else { return nil }
            return TokenUsageMonthMarker(
                column: column,
                label: date.formatted(.dateTime.month(.abbreviated)).localizedLowercase
            )
        }
    }

    private var contentWidth: CGFloat {
        CGFloat(Self.columnCount) * Self.cellSize + CGFloat(Self.columnCount - 1) * Self.cellGap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ZStack(alignment: .leading) {
                        Color.clear.frame(width: contentWidth, height: 16)
                        ForEach(monthMarkers) { marker in
                            Text(marker.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .leading)
                                .offset(x: CGFloat(marker.column) * (Self.cellSize + Self.cellGap))
                        }
                    }
                    .frame(width: contentWidth, height: 16, alignment: .leading)

                    HStack(alignment: .top, spacing: Self.cellGap) {
                        ForEach(0..<Self.columnCount, id: \.self) { column in
                            VStack(spacing: Self.cellGap) {
                                ForEach(0..<Self.rowCount, id: \.self) { row in
                                    cell(at: column * Self.rowCount + row, row: row)
                                }
                            }
                        }
                    }
                    .frame(width: contentWidth, height: CGFloat(Self.rowCount) * Self.cellSize + CGFloat(Self.rowCount - 1) * Self.cellGap)
                }
            }

            HStack(spacing: 5) {
                Text(L10n.string("usage.less"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(legendColor(level: level))
                        .frame(width: Self.cellSize, height: Self.cellSize)
                }
                Text(L10n.string("usage.more"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cell(at index: Int, row: Int) -> some View {
        let cell = cells[index]
        let date = cell.date
        let amount = cell.amount
        let fillRows = filledRows(for: amount)
        let isFilled = cell.isStacked && row >= Self.rowCount - fillRows

        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color(for: amount, isFuture: cell.isFuture, isFilled: isFilled))
            .frame(width: Self.cellSize, height: Self.cellSize)
            .accessibilityLabel(accessibilityLabel(for: date, amount: amount, isFuture: cell.isFuture))
    }

    private func filledRows(for amount: Int64) -> Int {
        guard amount > 0 else { return 0 }
        return min(Self.rowCount, max(1, Int(ceil(Double(amount) / Double(maxTokens) * Double(Self.rowCount)))))
    }

    private func color(for amount: Int64, isFuture: Bool, isFilled: Bool) -> Color {
        let neutral = Color.primary.opacity(0.08)
        guard !isFuture else { return neutral }

        if mode == .weekly || mode == .cumulative {
            return isFilled ? Color.accentColor.opacity(0.82) : neutral
        }

        guard amount > 0 else { return neutral }
        let ratio = Double(amount) / Double(maxTokens)
        if ratio < 0.25 { return Color.accentColor.opacity(0.28) }
        if ratio < 0.5 { return Color.accentColor.opacity(0.45) }
        if ratio < 0.75 { return Color.accentColor.opacity(0.64) }
        return Color.accentColor.opacity(0.86)
    }

    private func legendColor(level: Int) -> Color {
        switch level {
        case 0: return Color.primary.opacity(0.08)
        case 1: return Color.accentColor.opacity(0.28)
        case 2: return Color.accentColor.opacity(0.45)
        case 3: return Color.accentColor.opacity(0.64)
        default: return Color.accentColor.opacity(0.86)
        }
    }

    private static func dayKey(_ date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    private static func dateFromKey(_ key: String) -> Date? {
        dayKeyFormatter.date(from: key)
    }

    private static func monthKey(_ date: Date) -> String {
        monthKeyFormatter.string(from: date)
    }

    private func accessibilityLabel(for date: Date, amount: Int64, isFuture: Bool) -> String {
        if isFuture { return date.formatted(date: .abbreviated, time: .omitted) }
        return "\(date.formatted(date: .abbreviated, time: .omitted)): \(amount)"
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    let onClose: () -> Void
    @State private var codexPath = AppSettings.codexPath ?? ""
    @State private var launchAtLogin = AppSettings.launchAtLogin
    @State private var notificationsEnabled = AppSettings.notificationsEnabled
    @State private var showFiveHourPercentageInMenuBar = AppSettings.showFiveHourPercentageInMenuBar
    @State private var showWeeklyPercentageInMenuBar = AppSettings.showWeeklyPercentageInMenuBar
    @State private var settingsError: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField(L10n.string("settings.path"), text: $codexPath)
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.string("action.choose")) { chooseCodex() }
                }
                Button(L10n.string("settings.savePath")) {
                    Task { await store.setCodexPath(codexPath) }
                }
                .disabled(codexPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text(L10n.string("settings.section.codex"))
            }

            Section {
                Toggle(L10n.string("settings.launchAtLogin"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        do {
                            try LaunchAtLoginManager.setEnabled(value)
                        } catch {
                            settingsError = error.localizedDescription
                            launchAtLogin = LaunchAtLoginManager.isEnabled
                        }
                    }
                Toggle(L10n.string("settings.notify"), isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _, value in
                        store.setNotificationsEnabled(value)
                    }
                Toggle(L10n.string("settings.showFiveHourPercentage"), isOn: $showFiveHourPercentageInMenuBar)
                    .onChange(of: showFiveHourPercentageInMenuBar) { _, value in
                        store.setShowFiveHourPercentageInMenuBar(value)
                    }
                Toggle(L10n.string("settings.showWeeklyPercentage"), isOn: $showWeeklyPercentageInMenuBar)
                    .onChange(of: showWeeklyPercentageInMenuBar) { _, value in
                        store.setShowWeeklyPercentageInMenuBar(value)
                    }
                LabeledContent(L10n.string("settings.update"), value: L10n.string("settings.updateValue"))
            } header: {
                Text(L10n.string("settings.section.behavior"))
            }

            Section {
                if let account = store.account {
                    Text(account.email ?? L10n.string("settings.chatgptAccount"))
                    Button(L10n.string("action.logout")) { Task { await store.logout() } }
                } else {
                    Button(L10n.string("action.login")) { Task { await store.login() } }
                }
            } header: {
                Text(L10n.string("settings.section.account"))
            }

            if let settingsError {
                Text(settingsError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(L10n.string("action.close"), action: onClose)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520)
    }

    private func chooseCodex() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.string("action.select")
        if panel.runModal() == .OK, let url = panel.url {
            codexPath = url.path
        }
    }
}

struct AboutView: View {
    let onClose: () -> Void

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Group {
                    if let image = NSImage(named: NSImage.applicationIconName) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                    } else {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .frame(width: 58, height: 58)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.string("app.name"))
                        .font(.title3.weight(.semibold))
                    Text(L10n.string("about.description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
                .padding(.vertical, 18)

            VStack(alignment: .leading, spacing: 10) {
                LabeledContent(L10n.string("about.versionLabel"), value: version)
                LabeledContent(L10n.string("about.platform"), value: "macOS")
                LabeledContent(L10n.string("settings.update"), value: L10n.string("settings.updateValue"))
            }
            .font(.caption)

            Spacer(minLength: 20)

            HStack {
                Spacer()
                Button(L10n.string("action.close"), action: onClose)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380, height: 360)
    }
}
