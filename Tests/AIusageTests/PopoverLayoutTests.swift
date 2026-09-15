import AppKit
import SwiftUI
import XCTest
@testable import AIusage

@MainActor
final class PopoverLayoutTests: XCTestCase {
    func testCodexModelUsageRendersWithinPopoverWidth() throws {
        let view = CodexModelUsageSection(models: [
            CodexModelUsage(
                model: "gpt-5.6-sol",
                inputTokens: 12_400_000,
                outputTokens: 820_000,
                cachedInputTokens: 31_000_000,
                cacheWriteInputTokens: 0
            ),
            CodexModelUsage(
                model: "gpt-5.4",
                inputTokens: 3_100_000,
                outputTokens: 240_000,
                cachedInputTokens: 9_800_000,
                cacheWriteInputTokens: 420_000
            ),
            CodexModelUsage(
                model: "codex-auto-review",
                inputTokens: 920_000,
                outputTokens: 110_000,
                cachedInputTokens: 1_700_000,
                cacheWriteInputTokens: 0
            )
        ])
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)

        let image = try render(view, size: NSSize(width: 580, height: 230))

        XCTAssertEqual(image.size.width, 580)
        XCTAssertEqual(image.size.height, 230)
        try saveIfRequested(image, name: "codex-model-usage.png")
    }

    func testCopilotPopoverRendersWithinCompactHeight() throws {
        let store = UsageStore(
            previewAgent: .githubCopilot,
            state: .ready,
            copilotSnapshot: sampleSnapshot
        )
        let view = UsagePopoverView(
            store: store,
            onSettings: {},
            onAbout: {},
            onClose: {},
            onContentHeightChange: { _ in }
        )
        let image = try render(view, size: NSSize(width: 580, height: 390))

        XCTAssertEqual(image.size.width, 580)
        XCTAssertEqual(image.size.height, 390)
        try saveIfRequested(image, name: "copilot-popover.png")
    }

    func testSettingsTabsRenderAtWindowSize() throws {
        let store = UsageStore(
            previewAgent: .githubCopilot,
            state: .ready,
            copilotSnapshot: sampleSnapshot
        )
        let image = try render(SettingsView(store: store, onClose: {}), size: NSSize(width: 560, height: 480))

        XCTAssertEqual(image.size.width, 560)
        XCTAssertEqual(image.size.height, 480)
        try saveIfRequested(image, name: "copilot-settings.png")
    }

    private var sampleSnapshot: CopilotUsageSnapshot {
        let premium = GitHubBillingUsageReport(
            timePeriod: .init(year: 2026, month: 9, day: nil),
            user: "olerida",
            usageItems: [
                item(model: "GPT-5", quantity: 82, amount: 3.28),
                item(model: "Claude Sonnet 4", quantity: 31, amount: 1.24),
                item(model: "Gemini 2.5 Pro", quantity: 12, amount: 0.48)
            ]
        )
        let credits = GitHubBillingUsageReport(
            timePeriod: .init(year: 2026, month: 9, day: nil),
            user: "olerida",
            usageItems: [item(model: "GPT-5", quantity: 18, amount: 0.18)]
        )
        return CopilotUsageSnapshot(
            account: GitHubAccount(login: "olerida", name: "Òscar Lérida", avatarURL: nil, htmlURL: nil),
            premiumRequests: premium,
            aiCredits: credits,
            fetchedAt: Date()
        )
    }

    private func item(model: String, quantity: Double, amount: Double) -> GitHubBillingUsageReport.Item {
        .init(
            product: "Copilot",
            sku: "Copilot Premium Request",
            model: model,
            unitType: "requests",
            grossQuantity: quantity,
            grossAmount: amount,
            discountQuantity: 0,
            discountAmount: 0,
            netQuantity: quantity,
            netAmount: amount
        )
    }

    private func render<V: View>(_ rootView: V, size: NSSize) throws -> NSImage {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        hostingView.layoutSubtreeIfNeeded()
        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw RenderingError.failed
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }

    private func saveIfRequested(_ image: NSImage, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["AIUSAGE_SNAPSHOT_DIR"] else { return }
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderingError.failed
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name), options: .atomic)
    }

    private enum RenderingError: Error {
        case failed
    }
}
