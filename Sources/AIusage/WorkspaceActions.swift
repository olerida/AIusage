import AppKit
import Foundation

enum WorkspaceActions {
    private static let webURL = URL(string: "https://chatgpt.com")!

    @discardableResult
    static func openCodexOrWeb() -> Bool {
        if openInstalledApp() { return true }
        return NSWorkspace.shared.open(webURL)
    }

    @discardableResult
    static func openUsage() -> Bool {
        // No public, stable deep link to Usage is documented. Opening the installed app
        // keeps the action local; the web fallback is always available.
        return openCodexOrWeb()
    }

    private static func openInstalledApp() -> Bool {
        let candidates = [
            "/Applications/ChatGPT.app",
            "\(NSHomeDirectory())/Applications/ChatGPT.app",
            "/Applications/Codex.app",
            "\(NSHomeDirectory())/Applications/Codex.app"
        ]

        for path in candidates where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if NSWorkspace.shared.open(url) {
                return true
            }
        }
        return false
    }
}
