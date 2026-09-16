import AppKit
import XCTest
@testable import AIusage

@MainActor
final class AppDelegateTests: XCTestCase {
    func testApplicationWindowStateIsNeverSavedOrRestored() {
        let delegate = AppDelegate()
        let application = NSApplication.shared

        XCTAssertFalse(delegate.applicationShouldSaveApplicationState(application))
        XCTAssertFalse(delegate.applicationShouldRestoreApplicationState(application))
    }
}
