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
    static func openUsage(for agent: AgentKind) -> Bool {
        switch agent {
        case .codex:
            // No public, stable Codex Usage deep link is documented.
            return openCodexOrWeb()
        case .githubCopilot:
            return NSWorkspace.shared.open(URL(string: "https://github.com/settings/billing")!)
        }
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
