import AppKit

@main
enum AIusageApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        application.delegate = appDelegate
        application.run()
    }
}
