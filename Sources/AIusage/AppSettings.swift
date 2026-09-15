import Foundation

enum AppSettings {
    private static var legacyDefaults: UserDefaults? {
        UserDefaults(suiteName: "com.codexusagebar.app")
    }
    private static let codexPathKey = "codexPath"
    private static let notificationsKey = "notificationsEnabled"
    private static let launchAtLoginKey = "launchAtLogin"
    private static let showPercentagesInMenuBarKey = "showPercentagesInMenuBar"
    private static let showFiveHourPercentageInMenuBarKey = "showFiveHourPercentageInMenuBar"
    private static let showWeeklyPercentageInMenuBarKey = "showWeeklyPercentageInMenuBar"
    private static let alertedKeysKey = "alertedKeys"
    private static let selectedAgentKey = "selectedAgent"

    static var selectedAgent: AgentKind {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: selectedAgentKey),
                  let agent = AgentKind(rawValue: rawValue) else { return .codex }
            return agent
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: selectedAgentKey) }
    }

    static var codexPath: String? {
        get {
            if let value = UserDefaults.standard.string(forKey: codexPathKey) { return value }
            guard let value = legacyDefaults?.string(forKey: codexPathKey) else { return nil }
            UserDefaults.standard.set(value, forKey: codexPathKey)
            return value
        }
        set { UserDefaults.standard.set(newValue, forKey: codexPathKey) }
    }

    static var notificationsEnabled: Bool {
        get {
            migratedBool(forKey: notificationsKey, default: true)
        }
        set { UserDefaults.standard.set(newValue, forKey: notificationsKey) }
    }

    static var launchAtLogin: Bool {
        get { migratedBool(forKey: launchAtLoginKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: launchAtLoginKey) }
    }

    static var showPercentagesInMenuBar: Bool {
        get {
            migratedBool(forKey: showPercentagesInMenuBarKey, default: true)
        }
        set { UserDefaults.standard.set(newValue, forKey: showPercentagesInMenuBarKey) }
    }

    static var showFiveHourPercentageInMenuBar: Bool {
        get {
            migratedBool(forKey: showFiveHourPercentageInMenuBarKey, default: showPercentagesInMenuBar)
        }
        set { UserDefaults.standard.set(newValue, forKey: showFiveHourPercentageInMenuBarKey) }
    }

    static var showWeeklyPercentageInMenuBar: Bool {
        get {
            migratedBool(forKey: showWeeklyPercentageInMenuBarKey, default: showPercentagesInMenuBar)
        }
        set { UserDefaults.standard.set(newValue, forKey: showWeeklyPercentageInMenuBarKey) }
    }

    static var alertedKeys: Set<String> {
        get {
            if let value = UserDefaults.standard.stringArray(forKey: alertedKeysKey) {
                return Set(value)
            }
            let value = legacyDefaults?.stringArray(forKey: alertedKeysKey) ?? []
            if !value.isEmpty { UserDefaults.standard.set(value, forKey: alertedKeysKey) }
            return Set(value)
        }
        set { UserDefaults.standard.set(Array(newValue), forKey: alertedKeysKey) }
    }

    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("AI Usage MB", isDirectory: true)
        let legacyDirectories = ["AI usage", "AIusage", "Codex Usage Bar"]
            .map { base.appendingPathComponent($0, isDirectory: true) }
        if !FileManager.default.fileExists(atPath: directory.path),
           let legacyDirectory = legacyDirectories.first(where: {
               FileManager.default.fileExists(atPath: $0.path)
           }) {
            try? FileManager.default.moveItem(at: legacyDirectory, to: directory)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var codexHomeDirectory: URL {
        let directory = applicationSupportDirectory.appendingPathComponent("CodexHome", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var localCodexHomeDirectory: URL {
        let configuredPath = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let configuredPath, !configuredPath.isEmpty {
            return URL(fileURLWithPath: (configuredPath as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
    }

    static var snapshotURL: URL {
        applicationSupportDirectory.appendingPathComponent("last-snapshot.json")
    }

    static var copilotSnapshotURL: URL {
        applicationSupportDirectory.appendingPathComponent("copilot-snapshot.json")
    }

    static var gitHubClientID: String? {
        let environmentValue = ProcessInfo.processInfo.environment["AIUSAGE_GITHUB_CLIENT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let environmentValue, !environmentValue.isEmpty { return environmentValue }

        let bundledValue = Bundle.main.object(forInfoDictionaryKey: "AIUsageGitHubClientID") as? String
        let cleanedValue = bundledValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanedValue?.isEmpty == false ? cleanedValue : nil
    }

    private static func migratedBool(forKey key: String, default defaultValue: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        guard legacyDefaults?.object(forKey: key) != nil else { return defaultValue }
        let value = legacyDefaults?.bool(forKey: key) ?? defaultValue
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
}
