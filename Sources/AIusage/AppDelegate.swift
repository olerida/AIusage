import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private let popoverWidth: CGFloat = 580
    private var measuredPopoverContentHeight: CGFloat = 700

    // This is a menu-bar app. Persisting SwiftUI's empty Settings scene causes
    // macOS to restore a blank window the next time the app launches.
    func applicationShouldSaveApplicationState(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreApplicationState(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.imagePosition = .imageLeading

        let rootView = UsagePopoverView(
            store: store,
            onSettings: { [weak self] in self?.showSettings() },
            onAbout: { [weak self] in self?.showAbout() },
            onClose: { [weak self] in self?.terminateApplication() },
            onContentHeightChange: { [weak self] height in
                self?.updatePopoverHeight(for: height)
            }
        )
        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(
            width: popoverWidth,
            height: min(measuredPopoverContentHeight, maximumPopoverHeight)
        )
        popover.contentViewController = NSHostingController(rootView: rootView)

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        updateStatusItem()
        store.start()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.close()
        } else {
            updatePopoverHeight(for: measuredPopoverContentHeight)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
            startOutsideClickMonitoring()
        }
    }

    private var maximumPopoverHeight: CGFloat {
        let visibleHeight = statusItem?.button?.window?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 1_050
        return floor(visibleHeight * 2 / 3)
    }

    private func updatePopoverHeight(for contentHeight: CGFloat) {
        guard contentHeight.isFinite, contentHeight > 0 else { return }
        measuredPopoverContentHeight = contentHeight
        guard let popover else { return }

        let targetHeight = min(max(ceil(contentHeight), 180), maximumPopoverHeight)
        guard abs(popover.contentSize.height - targetHeight) > 1 else { return }
        popover.contentSize = NSSize(width: popoverWidth, height: targetHeight)
    }

    private func closePopover() {
        guard popover.isShown else { return }
        popover.close()
    }

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.window === self.popover.contentViewController?.view.window
                || event.window === self.statusItem.button?.window {
                return event
            }
            self.closePopover()
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    private func stopOutsideClickMonitoring() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func terminateApplication() {
        NSApp.terminate(nil)
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        button.image = makeUsageIcon()
        // Let the status bar choose the foreground color so the image and title
        // remain legible in every menu bar appearance and highlighted state.
        button.contentTintColor = nil
        button.title = store.statusText
        button.toolTip = store.statusTooltip
        button.imagePosition = .imageLeading
    }

    private func makeUsageIcon() -> NSImage {
        let iconSize = NSSize(width: 18, height: 18)
        let image = NSImage(size: iconSize, flipped: false) { _ in
            let ink = NSColor.black
            ink.setStroke()

            let meter = NSBezierPath()
            meter.appendArc(
                withCenter: NSPoint(x: 8.7, y: 8.9),
                radius: 6.2,
                startAngle: 112,
                endAngle: 405
            )
            meter.lineWidth = 2.2
            meter.lineCapStyle = .round
            meter.stroke()

            ink.setFill()
            let cells = [
                NSRect(x: 5.0, y: 4.1, width: 2.8, height: 2.8),
                NSRect(x: 8.1, y: 6.9, width: 2.8, height: 2.8),
                NSRect(x: 11.2, y: 9.7, width: 2.8, height: 2.8)
            ]
            for cell in cells {
                NSBezierPath(roundedRect: cell, xRadius: 0.8, yRadius: 0.8).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = L10n.string("icon.usage")
        return image
    }

    private func showSettings() {
        closePopover()
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(store: store, onClose: { [weak self] in
            self?.settingsWindow?.close()
        })
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.title = L10n.string("settings.windowTitle")
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 560, height: 480))
        window.minSize = NSSize(width: 560, height: 480)
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showAbout() {
        closePopover()
        if let aboutWindow {
            aboutWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = AboutView(onClose: { [weak self] in
            self?.aboutWindow?.close()
        })
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.title = L10n.string("about.windowTitle")
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 380, height: 360))
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        aboutWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension AppDelegate: NSWindowDelegate, NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitoring()
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            settingsWindow = nil
        }
        if (notification.object as? NSWindow) === aboutWindow {
            aboutWindow = nil
        }
    }
}
