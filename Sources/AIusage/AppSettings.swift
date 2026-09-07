import Foundation

enum AppSettings {
    private static let legacyDefaults = UserDefaults(suiteName: "com.codexusagebar.app")
    private static let codexPathKey = "codexPath"
    private static let notificationsKey = "notificationsEnabled"
    private static let launchAtLoginKey = "launchAtLogin"
    private static let showPercentagesInMenuBarKey = "showPercentagesInMenuBar"
    private static let showFiveHourPercentageInMenuBarKey = "showFiveHourPercentageInMenuBar"
    private static let showWeeklyPercentageInMenuBarKey = "showWeeklyPercentageInMenuBar"
    private static let alertedKeysKey = "alertedKeys"

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
        let directory = base.appendingPathComponent("AIusage", isDirectory: true)
        let legacyDirectory = base.appendingPathComponent("Codex Usage Bar", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path),
           FileManager.default.fileExists(atPath: legacyDirectory.path) {
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

    static var snapshotURL: URL {
        applicationSupportDirectory.appendingPathComponent("last-snapshot.json")
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
